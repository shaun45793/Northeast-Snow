from __future__ import annotations

import math
from datetime import datetime
from typing import Dict, List, Optional

from app.config import MODEL_SOURCES

LAPSE_RATE_F_PER_1000FT = 3.5


def lead_bucket_for_hours(lead_hours: int) -> str:
    if lead_hours <= 24:
        return "short_0_24h"
    if lead_hours <= 72:
        return "medium_24_72h"
    return "extended_72_168h"


def adjust_temp_for_elevation(
    temp_f: Optional[float],
    from_elev_ft: Optional[int],
    to_elev_ft: int,
) -> Optional[float]:
    if temp_f is None or from_elev_ft is None:
        return temp_f
    delta_ft = to_elev_ft - from_elev_ft
    if abs(delta_ft) < 100:
        return temp_f
    return temp_f - (delta_ft / 1000.0) * LAPSE_RATE_F_PER_1000FT


def compute_wet_bulb_f(temp_f: float, rh_pct: Optional[float]) -> float:
    """Stull (2011) wet-bulb temperature approximation in Fahrenheit."""
    if rh_pct is None:
        return temp_f
    rh = max(5.0, min(100.0, rh_pct))
    t_c = (temp_f - 32.0) * 5.0 / 9.0
    tw_c = (
        t_c * math.atan(0.151977 * math.sqrt(rh + 8.313659))
        + math.atan(t_c + rh)
        - math.atan(rh - 1.676331)
        + 0.00391838 * (rh**1.5) * math.atan(0.023101 * rh)
        - 4.686035
    )
    return round((tw_c * 9.0 / 5.0) + 32.0, 1)


def is_warm_nose(surface_temp_f: float, temp_850_f: Optional[float]) -> bool:
    """Detect Northeast mid-level warm nose (freezing rain / sleet risk)."""
    if temp_850_f is None:
        return False
    return surface_temp_f <= 32.5 and temp_850_f > 33.5


def estimate_slr(
    temp_f: float,
    wind_mph: float = 10.0,
    temp_850_f: Optional[float] = None,
    temp_700_f: Optional[float] = None,
) -> float:
    """
    Estimate Northeast Snow-to-Liquid Ratio (SLR) from 2m temperature, wind speed,
    and optional 850hPa / 700hPa temperatures (warm-nose & dendritic growth zone).
    """
    if temp_f > 35.0:
        return 0.0

    # Strong warm nose aloft turns snow into sleet/freezing rain
    if is_warm_nose(temp_f, temp_850_f):
        return 2.5

    if temp_f > 32.0:
        base_slr = 6.0 * (35.0 - temp_f) / 3.0
    elif temp_f >= 27.0:
        base_slr = 8.0 + (32.0 - temp_f) * 0.6
    elif temp_f >= 18.0:
        base_slr = 11.0 + (27.0 - temp_f) * (5.0 / 9.0)
    elif temp_f >= 10.0:
        base_slr = 16.0 + (18.0 - temp_f) * (2.5 / 8.0)
    else:
        base_slr = max(13.0, 18.5 - (10.0 - temp_f) * 0.35)

    # Dendritic Growth Zone (-18C to -10C => ~0F to 14F) boost aloft
    aloft_temps = [t for t in (temp_850_f, temp_700_f) if t is not None]
    if aloft_temps and temp_f <= 29.0:
        if any(0.0 <= t <= 14.0 for t in aloft_temps):
            base_slr *= 1.12

    if wind_mph > 22.0:
        penalty = min(0.22, (wind_mph - 22.0) * 0.008)
        base_slr *= 1.0 - penalty

    return round(max(0.0, base_slr), 1)


def classify_precip_type(
    liquid_in: float,
    snow_in: float,
    temp_f: float,
    temp_850_f: Optional[float] = None,
    wet_bulb_f: Optional[float] = None,
) -> str:
    if liquid_in < 0.004 and snow_in < 0.04:
        return "Dry"
    if is_warm_nose(temp_f, temp_850_f):
        return "Mix"
    effective_t = wet_bulb_f if wet_bulb_f is not None else temp_f
    if effective_t >= 35.5 or (snow_in < 0.02 and effective_t >= 33.0):
        return "Rain"
    if 31.5 <= effective_t < 35.5:
        return "Mix"
    return "Snow"


def compute_lift_hold_risk(
    wind_mph: float,
    wind_gust_mph: float,
    elevation_ft: int,
    wind_dir_deg: Optional[float] = None,
    aspect: str = "NW",
) -> str:
    score = max(wind_mph * 1.15, wind_gust_mph)
    if elevation_ft >= 3800:
        score += 4.0
    if wind_dir_deg is not None:
        # NW/WNW winds (280-340 deg) hit exposed NE ridges hardest
        if aspect in {"NW", "WNW", "NNW"} and 270.0 <= wind_dir_deg <= 345.0:
            score += 3.0
    if score >= 48.0 or wind_mph >= 34.0:
        return "High"
    if score >= 34.0 or wind_mph >= 24.0:
        return "Moderate"
    return "Low"


def build_residual_features(
    source_snow: Dict[str, Optional[float]],
    source_temp: Dict[str, Optional[float]],
    elevation_ft: int,
    orographic_factor: float,
    lead_hours: int,
    wind_mph: float,
    valid_time: datetime,
) -> List[float]:
    """
    Build numeric feature vector for the HistGradientBoosting residual corrector.
    """
    snow_vals = [v for v in source_snow.values() if v is not None]
    temp_vals = [v for v in source_temp.values() if v is not None]

    snow_mean = sum(snow_vals) / len(snow_vals) if snow_vals else 0.0
    snow_std = (
        math.sqrt(sum((v - snow_mean) ** 2 for v in snow_vals) / len(snow_vals))
        if len(snow_vals) > 1
        else 0.0
    )
    temp_mean = sum(temp_vals) / len(temp_vals) if temp_vals else 25.0
    temp_std = (
        math.sqrt(sum((v - temp_mean) ** 2 for v in temp_vals) / len(temp_vals))
        if len(temp_vals) > 1
        else 0.0
    )

    doy = valid_time.timetuple().tm_yday
    doy_rad = 2.0 * math.pi * (doy / 365.25)

    per_source_snow = [
        float(source_snow[s]) if source_snow.get(s) is not None else snow_mean
        for s in MODEL_SOURCES
    ]
    per_source_temp = [
        float(source_temp[s]) if source_temp.get(s) is not None else temp_mean
        for s in MODEL_SOURCES
    ]

    return [
        snow_mean,
        snow_std,
        temp_mean,
        temp_std,
        float(elevation_ft),
        float(orographic_factor),
        float(lead_hours),
        float(wind_mph),
        math.sin(doy_rad),
        math.cos(doy_rad),
        *per_source_snow,
        *per_source_temp,
    ]
