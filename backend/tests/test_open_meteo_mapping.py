from __future__ import annotations

from app.clients.open_meteo import parse_open_meteo_payload


def test_parse_multi_model_open_meteo_payload():
    payload = {
        "elevation": 1000.0,
        "hourly_units": {
            "temperature_2m_ncep_hrrr_conus": "°F",
            "precipitation_ncep_hrrr_conus": "inch",
            "snowfall_ncep_hrrr_conus": "cm",
            "freezing_level_height_ncep_hrrr_conus": "m",
            "temperature_2m_ecmwf_ifs025": "°F",
            "precipitation_ecmwf_ifs025": "inch",
            "snowfall_ecmwf_ifs025": "cm",
            "freezing_level_height_ecmwf_ifs025": "m",
        },
        "hourly": {
            "time": ["2026-11-25T00:00", "2026-11-25T01:00"],
            "temperature_2m_ncep_hrrr_conus": [22.0, 21.0],
            "precipitation_ncep_hrrr_conus": [0.10, 0.05],
            "snowfall_ncep_hrrr_conus": [2.54, 1.27],
            "wind_speed_10m_ncep_hrrr_conus": [18.0, 20.0],
            "wind_gusts_10m_ncep_hrrr_conus": [28.0, 31.0],
            "freezing_level_height_ncep_hrrr_conus": [500.0, 450.0],
            "precipitation_probability_ncep_hrrr_conus": [80, 70],
            "temperature_2m_ecmwf_ifs025": [23.5, 22.5],
            "precipitation_ecmwf_ifs025": [0.08, 0.04],
            "snowfall_ecmwf_ifs025": [2.0, 1.0],
            "wind_speed_10m_ecmwf_ifs025": [15.0, 16.0],
            "wind_gusts_10m_ecmwf_ifs025": [24.0, 25.0],
            "freezing_level_height_ecmwf_ifs025": [550.0, 500.0],
            "precipitation_probability_ecmwf_ifs025": [75, 65],
        },
    }

    bundle = parse_open_meteo_payload(payload)
    assert bundle.grid_elevation_ft == 3281
    assert len(bundle.times) == 2
    assert "hrrr" in bundle.models
    assert "ecmwf" in bundle.models
    assert abs((bundle.models["hrrr"][0].snowfall_in or 0.0) - 1.0) < 0.01
    assert abs((bundle.models["hrrr"][0].freezing_level_ft or 0.0) - 1640.4) < 1.0
