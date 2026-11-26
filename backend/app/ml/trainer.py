from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

import numpy as np

from app.config import ELEVATION_BANDS, LEAD_BUCKETS, NORTHEAST_MOUNTAINS
from app.ml.ensemble import EnsembleArtifact, SnowEnsembleModel, TrainingExample
from app.ml.features import lead_bucket_for_hours
from app.storage import ForecastStorage


def generate_northeast_bootstrap_examples(
    samples_per_mountain_bucket: int = 18, seed: int = 42
) -> List[TrainingExample]:
    """
    Generate physically grounded Northeast verification pairs so the ML stacker
    learns elevation-, mountain-, and lead-time-dependent weights immediately,
    and smoothly blends with live verified observations as they accumulate.
    """
    rng = np.random.default_rng(seed)
    examples: List[TrainingExample] = []
    base_time = datetime(2026, 1, 15, 12, 0, tzinfo=timezone.utc)

    # True relative noise std by (lead_bucket, source) reflecting documented NWP characteristics
    snow_noise_std: Dict[str, Dict[str, float]] = {
        "short_0_24h": {
            "hrrr": 0.035,
            "nam": 0.050,
            "ecmwf": 0.065,
            "nws": 0.060,
            "gem": 0.085,
            "gfs": 0.095,
        },
        "medium_24_72h": {
            "hrrr": 0.095,
            "nam": 0.065,
            "ecmwf": 0.050,
            "nws": 0.068,
            "gem": 0.072,
            "gfs": 0.085,
        },
        "extended_72_168h": {
            "hrrr": 0.250,
            "nam": 0.190,
            "ecmwf": 0.070,
            "nws": 0.110,
            "gem": 0.090,
            "gfs": 0.105,
        },
    }

    temp_noise_std: Dict[str, Dict[str, float]] = {
        "short_0_24h": {
            "hrrr": 1.3,
            "nam": 1.6,
            "ecmwf": 1.8,
            "nws": 1.4,
            "gem": 2.2,
            "gfs": 2.4,
        },
        "medium_24_72h": {
            "hrrr": 2.6,
            "nam": 2.1,
            "ecmwf": 1.8,
            "nws": 1.9,
            "gem": 2.3,
            "gfs": 2.5,
        },
        "extended_72_168h": {
            "hrrr": 5.0,
            "nam": 4.2,
            "ecmwf": 2.4,
            "nws": 2.9,
            "gem": 2.8,
            "gfs": 3.1,
        },
    }

    for mountain in NORTHEAST_MOUNTAINS:
        is_northern = mountain.state in {"VT", "NH", "ME"} or mountain.id == "whiteface"
        for band in ELEVATION_BANDS:
            elev_ft = mountain.elevations.for_band(band)
            elev_factor = (elev_ft - 1200) / 3000.0
            for lead_bucket in LEAD_BUCKETS:
                for i in range(samples_per_mountain_bucket):
                    if lead_bucket == "short_0_24h":
                        lead_h = int(rng.integers(1, 25))
                    elif lead_bucket == "medium_24_72h":
                        lead_h = int(rng.integers(25, 73))
                    else:
                        lead_h = int(rng.integers(73, 168))

                    valid_time = base_time + timedelta(hours=i * 6 + lead_h)
                    # Realistic winter Northeast storm vs dry hour distribution
                    is_storm = rng.random() < 0.65
                    wind_mph = float(
                        np.clip(
                            rng.normal(14.0 + 10.0 * elev_factor, 7.0),
                            3.0,
                            55.0,
                        )
                    )
                    true_temp = float(
                        np.clip(
                            rng.normal(24.0 - 7.5 * elev_factor - (2.5 if is_northern else 0.0), 6.5),
                            -5.0,
                            38.0,
                        )
                    )

                    if is_storm and true_temp <= 33.5:
                        base_rate = float(rng.gamma(1.6, 0.14))
                        # Orographic boost on high-elevation northwest-facing ridges
                        oro_boost = 1.0 + (mountain.orographic_factor - 1.0) * max(0.3, elev_factor)
                        true_snow = float(np.clip(base_rate * oro_boost, 0.02, 1.4))
                    else:
                        true_snow = 0.0

                    # Simulate coarse global models under-predicting summit upslope snow
                    upslope_undercatch = (
                        true_snow * 0.18 * max(0.0, mountain.orographic_factor - 1.05)
                        if band == "summit"
                        else 0.0
                    )

                    src_snow: Dict[str, Optional[float]] = {}
                    src_temp: Dict[str, Optional[float]] = {}
                    s_std_map = snow_noise_std[lead_bucket]
                    t_std_map = temp_noise_std[lead_bucket]

                    for src in ("hrrr", "nam", "ecmwf", "gfs", "gem", "nws"):
                        if lead_bucket == "extended_72_168h" and src == "hrrr":
                            src_snow[src] = None
                            src_temp[src] = None
                            continue
                        if lead_bucket == "extended_72_168h" and src == "nam" and lead_h > 84:
                            src_snow[src] = None
                            src_temp[src] = None
                            continue

                        bias = 0.0
                        if src in {"ecmwf", "gfs"}:
                            bias -= upslope_undercatch
                        if src == "gfs" and mountain.state in {"ME", "NH", "MA"}:
                            # Slight coastal warm bias in GFS
                            src_temp[src] = round(
                                true_temp + 1.1 + float(rng.normal(0.0, t_std_map[src])), 1
                            )
                        else:
                            src_temp[src] = round(
                                true_temp + float(rng.normal(0.0, t_std_map[src])), 1
                            )

                        # GEM performs relatively better in far-northern VT/ME
                        eff_std = s_std_map[src]
                        if src == "gem" and is_northern:
                            eff_std *= 0.82

                        noisy_snow = max(
                            0.0,
                            true_snow + bias + float(rng.normal(0.0, eff_std * (1.0 + true_snow))),
                        )
                        src_snow[src] = round(noisy_snow, 3)

                    examples.append(
                        TrainingExample(
                            mountain_id=mountain.id,
                            elevation_band=band,
                            elevation_ft=elev_ft,
                            orographic_factor=mountain.orographic_factor,
                            lead_hours=lead_h,
                            lead_bucket=lead_bucket_for_hours(lead_h),
                            valid_time=valid_time,
                            wind_mph=round(wind_mph, 1),
                            source_snow=src_snow,
                            source_temp=src_temp,
                            observed_snow_in=round(true_snow, 3),
                            observed_temp_f=round(true_temp, 1),
                            is_bootstrap=True,
                        )
                    )
    return examples


def train_or_refresh_ensemble(
    storage: ForecastStorage,
    ensemble: SnowEnsembleModel,
    force_retrain: bool = False,
) -> EnsembleArtifact:
    if ensemble.artifact.buckets and not force_retrain:
        return ensemble.artifact

    verified = storage.fetch_verified_training_examples()
    # Supplement with Northeast calibrated bootstrap data until real verified pairs dominate
    if len(verified) < 600:
        bootstrap = generate_northeast_bootstrap_examples(samples_per_mountain_bucket=16)
        combined = bootstrap + verified
    else:
        combined = verified

    return ensemble.fit(combined, min_mountain_samples=16)
