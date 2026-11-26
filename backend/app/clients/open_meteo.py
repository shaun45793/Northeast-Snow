from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

import httpx

from app.config import MountainConfig, OPEN_METEO_MODEL_MAP

logger = logging.getLogger(__name__)

OPEN_METEO_FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
OPEN_METEO_ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
FT_TO_METERS = 0.3048
METERS_TO_FT = 3.28084
CM_TO_INCHES = 0.393701


@dataclass
class RawModelHour:
    temp_f: Optional[float] = None
    precip_in: Optional[float] = None
    snowfall_in: Optional[float] = None
    wind_mph: Optional[float] = None
    wind_gust_mph: Optional[float] = None
    freezing_level_ft: Optional[float] = None
    precip_prob_pct: Optional[float] = None


@dataclass
class OpenMeteoBundle:
    times: List[datetime]
    # model_key -> list aligned with `times`
    models: Dict[str, List[RawModelHour]]
    grid_elevation_ft: Optional[int]
    is_live: bool = True


def _to_inches(value: Optional[float], unit: str) -> Optional[float]:
    if value is None:
        return None
    if unit.lower().startswith("cm"):
        return value * CM_TO_INCHES
    return value


def _to_feet(value: Optional[float], unit: str) -> Optional[float]:
    if value is None:
        return None
    if unit.lower() in {"m", "meter", "meters"}:
        return value * METERS_TO_FT
    return value


def parse_open_meteo_payload(payload: dict) -> OpenMeteoBundle:
    hourly = payload.get("hourly", {})
    units = payload.get("hourly_units", {})
    raw_times = hourly.get("time", [])
    times: List[datetime] = []
    for raw in raw_times:
        dt = datetime.fromisoformat(raw)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        times.append(dt)

    n = len(times)
    models_out: Dict[str, List[RawModelHour]] = {}

    for source_key, om_model in OPEN_METEO_MODEL_MAP.items():
        # Open-Meteo appends _{model_name} when multiple models are requested.
        temp_key = (
            f"temperature_2m_{om_model}"
            if f"temperature_2m_{om_model}" in hourly
            else "temperature_2m"
        )
        precip_key = (
            f"precipitation_{om_model}"
            if f"precipitation_{om_model}" in hourly
            else "precipitation"
        )
        snow_key = (
            f"snowfall_{om_model}"
            if f"snowfall_{om_model}" in hourly
            else "snowfall"
        )
        wind_key = (
            f"wind_speed_10m_{om_model}"
            if f"wind_speed_10m_{om_model}" in hourly
            else "wind_speed_10m"
        )
        gust_key = (
            f"wind_gusts_10m_{om_model}"
            if f"wind_gusts_10m_{om_model}" in hourly
            else "wind_gusts_10m"
        )
        fl_key = (
            f"freezing_level_height_{om_model}"
            if f"freezing_level_height_{om_model}" in hourly
            else "freezing_level_height"
        )
        pop_key = (
            f"precipitation_probability_{om_model}"
            if f"precipitation_probability_{om_model}" in hourly
            else "precipitation_probability"
        )

        # If this model has no temperature series at all, skip it.
        if temp_key not in hourly and precip_key not in hourly:
            continue

        temps = hourly.get(temp_key, [None] * n)
        precips = hourly.get(precip_key, [None] * n)
        snows = hourly.get(snow_key, [None] * n)
        winds = hourly.get(wind_key, [None] * n)
        gusts = hourly.get(gust_key, [None] * n)
        fls = hourly.get(fl_key, [None] * n)
        pops = hourly.get(pop_key, [None] * n)

        snow_unit = units.get(snow_key, units.get("snowfall", "cm"))
        precip_unit = units.get(precip_key, units.get("precipitation", "inch"))
        fl_unit = units.get(fl_key, units.get("freezing_level_height", "m"))

        series: List[RawModelHour] = []
        for i in range(n):
            raw_precip = precips[i] if i < len(precips) else None
            if raw_precip is not None and precip_unit.lower().startswith("mm"):
                raw_precip = raw_precip / 25.4
            series.append(
                RawModelHour(
                    temp_f=temps[i] if i < len(temps) else None,
                    precip_in=raw_precip,
                    snowfall_in=_to_inches(
                        snows[i] if i < len(snows) else None, snow_unit
                    ),
                    wind_mph=winds[i] if i < len(winds) else None,
                    wind_gust_mph=gusts[i] if i < len(gusts) else None,
                    freezing_level_ft=_to_feet(
                        fls[i] if i < len(fls) else None, fl_unit
                    ),
                    precip_prob_pct=pops[i] if i < len(pops) else None,
                )
            )
        models_out[source_key] = series

    elev_m = payload.get("elevation")
    grid_elev_ft = int(round(elev_m * METERS_TO_FT)) if elev_m is not None else None

    return OpenMeteoBundle(
        times=times,
        models=models_out,
        grid_elevation_ft=grid_elev_ft,
        is_live=True,
    )


class OpenMeteoClient:
    """Fetches multi-model NWP forecasts from Open-Meteo."""

    def __init__(self, timeout_seconds: float = 12.0) -> None:
        self.timeout_seconds = timeout_seconds

    async def fetch_multi_model_forecast(
        self,
        mountain: MountainConfig,
        elevation_ft: int,
        forecast_days: int = 7,
    ) -> Optional[OpenMeteoBundle]:
        elevation_m = round(elevation_ft * FT_TO_METERS)
        params = {
            "latitude": mountain.latitude,
            "longitude": mountain.longitude,
            "elevation": elevation_m,
            "models": ",".join(OPEN_METEO_MODEL_MAP.values()),
            "hourly": ",".join(
                [
                    "temperature_2m",
                    "precipitation",
                    "snowfall",
                    "wind_speed_10m",
                    "wind_gusts_10m",
                    "freezing_level_height",
                    "precipitation_probability",
                ]
            ),
            "temperature_unit": "fahrenheit",
            "wind_speed_unit": "mph",
            "precipitation_unit": "inch",
            "timezone": "UTC",
            "forecast_days": forecast_days,
        }

        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                resp = await client.get(OPEN_METEO_FORECAST_URL, params=params)
                resp.raise_for_status()
                payload = resp.json()
                bundle = parse_open_meteo_payload(payload)
                if bundle.times and bundle.models:
                    return bundle
        except Exception as exc:
            logger.warning(
                "Open-Meteo fetch failed for %s (%s ft): %s",
                mountain.id,
                elevation_ft,
                exc,
            )
        return None

    async def fetch_historical_weather(
        self,
        mountain: MountainConfig,
        elevation_ft: int,
        days_back: int = 30,
    ) -> Optional[dict]:
        """Fetch ERA5/historical archive weather for verification/backfill."""
        end_date = datetime.now(timezone.utc).date() - timedelta(days=2)
        start_date = end_date - timedelta(days=days_back)
        params = {
            "latitude": mountain.latitude,
            "longitude": mountain.longitude,
            "elevation": round(elevation_ft * FT_TO_METERS),
            "start_date": start_date.isoformat(),
            "end_date": end_date.isoformat(),
            "hourly": "temperature_2m,precipitation,snowfall,wind_speed_10m",
            "temperature_unit": "fahrenheit",
            "wind_speed_unit": "mph",
            "precipitation_unit": "inch",
            "timezone": "UTC",
        }
        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                resp = await client.get(OPEN_METEO_ARCHIVE_URL, params=params)
                resp.raise_for_status()
                return resp.json()
        except Exception as exc:
            logger.warning("Open-Meteo archive fetch failed for %s: %s", mountain.id, exc)
            return None
