from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

import httpx

from app.clients.open_meteo import RawModelHour
from app.config import MountainConfig

logger = logging.getLogger(__name__)

NWS_BASE_URL = "https://api.weather.gov"
NWS_HEADERS = {
    "User-Agent": "NortheastSnowForecast/0.1 (ios-mvp@snowforecast.local)",
    "Accept": "application/geo+json, application/json",
}

KMH_TO_MPH = 0.621371
MM_TO_IN = 0.0393701


@dataclass
class NWSGridForecast:
    times: List[datetime]
    hours: List[RawModelHour]
    grid_elevation_ft: Optional[int]
    wfo_id: str


@dataclass
class NWSAFDProduct:
    wfo_id: str
    product_id: str
    issued_at: datetime
    raw_text: str
    forecaster: Optional[str]


@dataclass
class NWSObservation:
    station_id: str
    observed_at: datetime
    temp_f: Optional[float]
    wind_mph: Optional[float]
    precip_1h_in: Optional[float]


def _parse_wind_speed_mph(wind_str: Optional[str]) -> Optional[float]:
    if not wind_str:
        return None
    nums = [float(x) for x in re.findall(r"\d+(?:\.\d+)?", wind_str)]
    if not nums:
        return None
    return sum(nums) / len(nums)


def _c_to_f(c: Optional[float]) -> Optional[float]:
    if c is None:
        return None
    return (c * 9.0 / 5.0) + 32.0


def _extract_forecaster(raw_text: str) -> Optional[str]:
    # NWS AFDs typically end with `$$` followed by forecaster initials/name or `...NAME...`
    lines = [line.strip() for line in raw_text.splitlines() if line.strip()]
    for line in reversed(lines[-10:]):
        if line in {"$$", "&&"}:
            continue
        if len(line) <= 32 and not line.startswith("."):
            if any(ch.isalpha() for ch in line):
                return line
    return None


class NWSClient:
    """Fetches NWS point forecasts, Area Forecast Discussions (AFD), and station observations."""

    def __init__(self, timeout_seconds: float = 12.0) -> None:
        self.timeout_seconds = timeout_seconds
        self._points_cache: Dict[Tuple[float, float], dict] = {}

    async def _get_point_metadata(
        self, client: httpx.AsyncClient, lat: float, lon: float
    ) -> Optional[dict]:
        key = (round(lat, 4), round(lon, 4))
        if key in self._points_cache:
            return self._points_cache[key]
        url = f"{NWS_BASE_URL}/points/{key[0]},{key[1]}"
        resp = await client.get(url, headers=NWS_HEADERS)
        resp.raise_for_status()
        props = resp.json().get("properties", {})
        self._points_cache[key] = props
        return props

    async def fetch_hourly_forecast(
        self, mountain: MountainConfig
    ) -> Optional[NWSGridForecast]:
        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                props = await self._get_point_metadata(
                    client, mountain.latitude, mountain.longitude
                )
                if not props:
                    return None
                hourly_url = props.get("forecastHourly")
                wfo_id = props.get("gridId", mountain.nws_wfo)
                if not hourly_url:
                    return None

                resp = await client.get(hourly_url, headers=NWS_HEADERS)
                resp.raise_for_status()
                h_props = resp.json().get("properties", {})
                periods = h_props.get("periods", [])
                elev_val = (h_props.get("elevation") or {}).get("value")
                grid_elev_ft = (
                    int(round(elev_val * 3.28084)) if elev_val is not None else None
                )

                times: List[datetime] = []
                hours: List[RawModelHour] = []
                for p in periods:
                    start = p.get("startTime")
                    if not start:
                        continue
                    dt = datetime.fromisoformat(start).astimezone(timezone.utc)
                    temp = p.get("temperature")
                    if p.get("temperatureUnit") == "C" and temp is not None:
                        temp = _c_to_f(float(temp))
                    pop = (p.get("probabilityOfPrecipitation") or {}).get("value")
                    short_fc = (p.get("shortForecast") or "").lower()
                    wind_mph = _parse_wind_speed_mph(p.get("windSpeed"))

                    # NWS hourly periods don't carry QPF directly; estimate light/moderate/heavy signal
                    # from shortForecast + PoP so NWS participates cleanly in temp/wind/PoP & snow signal.
                    est_precip_in: Optional[float] = None
                    if pop is not None and pop >= 20:
                        if "heavy" in short_fc:
                            est_precip_in = 0.12 * (pop / 100.0)
                        elif any(w in short_fc for w in ("snow", "rain", "showers", "sleet")):
                            est_precip_in = 0.04 * (pop / 100.0)
                        else:
                            est_precip_in = 0.0

                    est_snow_in: Optional[float] = None
                    if est_precip_in is not None:
                        if "snow" in short_fc or "flurr" in short_fc:
                            ratio = 12.0 if (temp is not None and temp <= 28.0) else 8.0
                            est_snow_in = est_precip_in * ratio
                        else:
                            est_snow_in = 0.0

                    times.append(dt)
                    hours.append(
                        RawModelHour(
                            temp_f=float(temp) if temp is not None else None,
                            precip_in=est_precip_in,
                            snowfall_in=est_snow_in,
                            wind_mph=wind_mph,
                            wind_gust_mph=None,
                            freezing_level_ft=None,
                            precip_prob_pct=float(pop) if pop is not None else None,
                        )
                    )

                if times:
                    return NWSGridForecast(
                        times=times,
                        hours=hours,
                        grid_elevation_ft=grid_elev_ft,
                        wfo_id=wfo_id,
                    )
        except Exception as exc:
            logger.warning("NWS hourly fetch failed for %s: %s", mountain.id, exc)
        return None

    async def fetch_latest_afd(self, wfo_id: str) -> Optional[NWSAFDProduct]:
        list_url = f"{NWS_BASE_URL}/products/types/AFD/locations/{wfo_id.upper()}"
        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                resp = await client.get(list_url, headers=NWS_HEADERS)
                resp.raise_for_status()
                items = resp.json().get("@graph", [])
                if not items:
                    return None
                latest_id = items[0].get("id")
                latest_url = items[0].get("@id") or f"{NWS_BASE_URL}/products/{latest_id}"

                prod_resp = await client.get(latest_url, headers=NWS_HEADERS)
                prod_resp.raise_for_status()
                data = prod_resp.json()
                raw_text = data.get("productText", "")
                issued_raw = data.get("issuanceTime")
                issued_at = (
                    datetime.fromisoformat(issued_raw.replace("Z", "+00:00"))
                    if issued_raw
                    else datetime.now(timezone.utc)
                )
                return NWSAFDProduct(
                    wfo_id=wfo_id.upper(),
                    product_id=str(data.get("id", latest_id)),
                    issued_at=issued_at,
                    raw_text=raw_text,
                    forecaster=_extract_forecaster(raw_text),
                )
        except Exception as exc:
            logger.warning("NWS AFD fetch failed for %s: %s", wfo_id, exc)
        return None

    async def fetch_latest_observation(
        self, station_id: str
    ) -> Optional[NWSObservation]:
        url = f"{NWS_BASE_URL}/stations/{station_id.upper()}/observations/latest"
        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                resp = await client.get(url, headers=NWS_HEADERS)
                resp.raise_for_status()
                props = resp.json().get("properties", {})
                ts_raw = props.get("timestamp")
                if not ts_raw:
                    return None
                observed_at = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
                temp_c = (props.get("temperature") or {}).get("value")
                wind_kmh = (props.get("windSpeed") or {}).get("value")
                precip_mm = (props.get("precipitationLastHour") or {}).get("value")
                return NWSObservation(
                    station_id=station_id.upper(),
                    observed_at=observed_at,
                    temp_f=_c_to_f(temp_c) if temp_c is not None else None,
                    wind_mph=wind_kmh * KMH_TO_MPH if wind_kmh is not None else None,
                    precip_1h_in=precip_mm * MM_TO_IN if precip_mm is not None else None,
                )
        except Exception as exc:
            logger.warning("NWS observation fetch failed for %s: %s", station_id, exc)
        return None
