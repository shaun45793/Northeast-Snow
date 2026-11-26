from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from app.ml.ensemble import SnowEnsembleModel
from app.ml.features import adjust_temp_for_elevation, estimate_slr, lead_bucket_for_hours
from app.ml.trainer import generate_northeast_bootstrap_examples


def test_estimate_slr_physics():
    assert estimate_slr(38.0, 10.0) == 0.0
    wet_slr = estimate_slr(31.5, 10.0)
    dendritic_slr = estimate_slr(14.0, 10.0)
    windy_slr = estimate_slr(14.0, 40.0)
    assert 7.0 <= wet_slr <= 10.0
    assert dendritic_slr >= 16.0
    assert windy_slr < dendritic_slr


def test_elevation_lapse_rate():
    base_temp = 30.0
    summit_temp = adjust_temp_for_elevation(base_temp, from_elev_ft=1500, to_elev_ft=3500)
    assert summit_temp is not None
    assert round(summit_temp, 1) == 23.0


def test_ensemble_trains_nonnegative_normalized_weights(tmp_path: Path):
    examples = generate_northeast_bootstrap_examples(samples_per_mountain_bucket=10, seed=7)
    model_path = tmp_path / "ensemble_test.pkl"
    model = SnowEnsembleModel(artifact_path=model_path)
    artifact = model.fit(examples, min_mountain_samples=10)

    assert model_path.exists()
    assert artifact.total_samples == len(examples)
    assert ("global", "summit", "short_0_24h") in artifact.buckets
    assert ("stowe", "summit", "short_0_24h") in artifact.buckets

    short_weights = model.get_weights_for_bucket("stowe", "summit", "short_0_24h")
    assert abs(sum(short_weights.values()) - 1.0) < 1e-6
    assert all(w >= 0.0 for w in short_weights.values())
    # HRRR & NAM should receive meaningfully higher weight at 0-24h than in extended 72-168h
    ext_weights = model.get_weights_for_bucket("stowe", "summit", "extended_72_168h")
    assert short_weights["hrrr"] > ext_weights["hrrr"]
    assert ext_weights["ecmwf"] > short_weights["hrrr"]


def test_predict_hour_handles_missing_short_range_models(tmp_path: Path):
    examples = generate_northeast_bootstrap_examples(samples_per_mountain_bucket=8, seed=11)
    model = SnowEnsembleModel(artifact_path=tmp_path / "ensemble_missing.pkl")
    model.fit(examples, min_mountain_samples=8)

    pred = model.predict_hour(
        mountain_id="jay-peak",
        elevation_band="summit",
        elevation_ft=3968,
        orographic_factor=1.28,
        lead_hours=96,
        lead_bucket=lead_bucket_for_hours(96),
        valid_time=datetime(2026, 2, 10, 12, 0, tzinfo=timezone.utc),
        wind_mph=22.0,
        source_snow={
            "hrrr": None,
            "nam": None,
            "ecmwf": 0.40,
            "gfs": 0.25,
            "gem": 0.35,
            "nws": 0.30,
        },
        source_temp={
            "hrrr": None,
            "nam": None,
            "ecmwf": 18.0,
            "gfs": 20.5,
            "gem": 17.5,
            "nws": 19.0,
        },
    )

    assert pred.snow_in > 0.0
    assert pred.snow_p10_in <= pred.snow_in <= pred.snow_p90_in
    assert 15.0 <= pred.temp_f <= 23.0
    assert pred.active_snow_weights["hrrr"] == 0.0
    assert abs(sum(pred.active_snow_weights.values()) - 1.0) < 1e-3
