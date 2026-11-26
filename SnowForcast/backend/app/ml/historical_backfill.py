from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import Dict, List, Optional

import httpx

from app.config import ELEVATION_BANDS, NORTHEAST_MOUNTAINS, OPEN_METEO_MODEL_MAP, MountainConfig
from app.ml.ensemble import SnowEnsembleModel, TrainingExample
from app.ml.exporter import export_ensemble_to_json
from app.ml.features import adjust_temp_for_elevation, estimate_slr, lead_bucket_for_hours
from app.ml.trainer import generate_northeast_bootstrap_examples

logger = logging.getLogger(__name__)

HISTORICAL_FORECAST_URL = "https://historical-forecast-api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
FT_TO_M = 0.3048
CM_TO_IN = 0.393701


async def _fetch_json(client: httpx.AsyncClient, url: str, params: dict) -> Optional[dict]:
    try:
        resp = await client.get(url, params=params)
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        logger.warning("Historical fetch failed for %s: %s", url, exc)
        return None


async def collect_historical_examples(
    mountains: List[MountainConfig],
    start_date: str = "2026-01-15",
    end_date: str = "2026-03-15",
) -> List[TrainingExample]:
    """
    Pair Open-Meteo historical NWP model runs against ERA5 historical weather
    reanalysis across Northeast mountains and elevation bands.
    """
    examples: List[TrainingExample] = []

    async with httpx.AsyncClient(timeout=20.0) as client:
        for mountain in mountains:
            for band in ("base", "summit"):
                elev_ft = mountain.elevations.for_band(band)
                elev_m = round(elev_ft * FT_TO_M)
                common = {
                    "latitude": mountain.latitude,
                    "longitude": mountain.longitude,
                    "elevation": elev_m,
                    "start_date": start_date,
                    "end_date": end_date,
                    "temperature_unit": "fahrenheit",
                    "wind_speed_unit": "mph",
                    "precipitation_unit": "inch",
                    "timezone": "UTC",
                }
                fc_params = {
                    **common,
                    "models": ",".join(OPEN_METEO_MODEL_MAP.values()),
                    "hourly": "temperature_2m,snowfall,precipitation,wind_speed_10m",
                }
                obs_params = {
                    **common,
                    "hourly": "temperature_2m,snowfall,precipitation,wind_speed_10m",
                }

                fc_json, obs_json = await asyncio.gather(
                    _fetch_json(client, HISTORICAL_FORECAST_URL, fc_params),
                    _fetch_json(client, ARCHIVE_URL, obs_params),
                )
                if not fc_json or not obs_json:
                    continue

                obs_hourly = obs_json.get("hourly", {})
                obs_times = obs_hourly.get("time", [])
                obs_temps = obs_hourly.get("temperature_2m", [])
                obs_snows = obs_hourly.get("snowfall", [])
                obs_precips = obs_hourly.get("precipitation", [])
                obs_winds = obs_hourly.get("wind_speed_10m", [])
                obs_units = obs_json.get("hourly_units", {})
                obs_snow_cm = str(obs_units.get("snowfall", "cm")).lower().startswith("cm")

                obs_by_time: Dict[str, tuple] = {}
                for i, t_str in enumerate(obs_times):
                    t_val = obs_temps[i] if i < len(obs_temps) else None
                    if t_val is None:
                        continue
                    s_val = obs_snows[i] if i < len(obs_snows) else 0.0
                    if s_val is not None and obs_snow_cm:
                        s_val = float(s_val) * CM_TO_IN
                    p_val = obs_precips[i] if i < len(obs_precips) else 0.0
                    w_val = obs_winds[i] if i < len(obs_winds) else 12.0
                    obs_by_time[t_str] = (
                        float(t_val),
                        float(s_val or 0.0),
                        float(p_val or 0.0),
                        float(w_val or 12.0),
                    )

                fc_hourly = fc_json.get("hourly", {})
                fc_times = fc_hourly.get("time", [])
                fc_units = fc_json.get("hourly_units", {})

                for idx, t_str in enumerate(fc_times):
                    if idx % 3 != 0 or t_str not in obs_by_time:
                        continue
                    obs_t, obs_s, _, obs_w = obs_by_time[t_str]
                    dt = datetime.fromisoformat(t_str).replace(tzinfo=timezone.utc)
                    # Simulate realistic lead-hour stratification across archive days
                    lead_h = ((idx % 72) + 1)
                    src_snow: Dict[str, Optional[float]] = {}
                    src_temp: Dict[str, Optional[float]] = {}

                    for src, om_name in OPEN_METEO_MODEL_MAP.items():
                        tk = f"temperature_2m_{om_name}"
                        sk = f"snowfall_{om_name}"
                        pk = f"precipitation_{om_name}"
                        t_arr = fc_hourly.get(tk, [])
                        s_arr = fc_hourly.get(sk, [])
                        p_arr = fc_hourly.get(pk, [])
                        t_v = t_arr[idx] if idx < len(t_arr) else None
                        s_v = s_arr[idx] if idx < len(s_arr) else None
                        p_v = p_arr[idx] if idx < len(p_arr) else None

                        if t_v is not None:
                            src_temp[src] = float(t_v)
                        if s_v is not None:
                            is_cm = str(fc_units.get(sk, "cm")).lower().startswith("cm")
                            src_snow[src] = float(s_v) * (CM_TO_IN if is_cm else 1.0)
                        elif p_v is not None and t_v is not None:
                            src_snow[src] = float(p_v) * estimate_slr(float(t_v), obs_w)

                    if len(src_temp) < 2:
                        continue

                    # Derive NWS proxy from multi-model consensus adjusted for elevation
                    valid_temps = [v for v in src_temp.values() if v is not None]
                    valid_snows = [v for v in src_snow.values() if v is not None]
                    src_temp["nws"] = sum(valid_temps) / len(valid_temps) if valid_temps else obs_t
                    src_snow["nws"] = sum(valid_snows) / len(valid_snows) if valid_snows else obs_s

                    # Apply to target band + mid band via lapse rate
                    for target_band in ELEVATION_BANDS:
                        target_elev = mountain.elevations.for_band(target_band)
                        adj_obs_t = adjust_temp_for_elevation(obs_t, elev_ft, target_elev) or obs_t
                        adj_src_t = {
                            k: adjust_temp_for_elevation(v, elev_ft, target_elev)
                            for k, v in src_temp.items()
                        }
                        examples.append(
                            TrainingExample(
                                mountain_id=mountain.id,
                                elevation_band=target_band,
                                elevation_ft=target_elev,
                                orographic_factor=mountain.orographic_factor,
                                lead_hours=lead_h,
                                lead_bucket=lead_bucket_for_hours(lead_h),
                                valid_time=dt,
                                wind_mph=obs_w,
                                source_snow=src_snow,
                                source_temp=adj_src_t,
                                observed_snow_in=max(0.0, obs_s),
                                observed_temp_f=adj_obs_t,
                                is_bootstrap=False,
                            )
                        )
    return examples


async def run_backfill_and_export() -> None:
    real_examples = await collect_historical_examples(NORTHEAST_MOUNTAINS[:6])
    bootstrap = generate_northeast_bootstrap_examples(samples_per_mountain_bucket=16)
    combined = bootstrap + real_examples
    model = SnowEnsembleModel()
    model.fit(combined, min_mountain_samples=16)
    out = export_ensemble_to_json(model)
    print(
        f"Trained on {len(real_examples)} real historical rows + {len(bootstrap)} calibrated rows -> exported {out}"
    )


if __name__ == "__main__":
    asyncio.run(run_backfill_and_export())
