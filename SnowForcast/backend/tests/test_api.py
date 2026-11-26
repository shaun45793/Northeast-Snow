from __future__ import annotations

from fastapi.testclient import TestClient

from app import main as app_main


def test_api_end_to_end_offline_fallback(monkeypatch):
    async def no_om(*args, **kwargs):
        return None

    async def no_nws_hourly(*args, **kwargs):
        return None

    async def no_nws_afd(*args, **kwargs):
        return None

    async def no_nws_obs(*args, **kwargs):
        return None

    monkeypatch.setattr(app_main.open_meteo_client, "fetch_multi_model_forecast", no_om)
    monkeypatch.setattr(app_main.nws_client, "fetch_hourly_forecast", no_nws_hourly)
    monkeypatch.setattr(app_main.nws_client, "fetch_latest_afd", no_nws_afd)
    monkeypatch.setattr(app_main.nws_client, "fetch_latest_observation", no_nws_obs)
    app_main.forecast_service._forecast_cache.clear()
    app_main.forecast_service._afd_cache.clear()

    with TestClient(app_main.app) as client:
        r_health = client.get("/health")
        assert r_health.status_code == 200
        assert r_health.json()["mountains"] == 18

        r_list = client.get("/api/v1/mountains?state=VT")
        assert r_list.status_code == 200
        vt_mountains = r_list.json()
        assert len(vt_mountains) == 7
        assert all(m["state"] == "VT" for m in vt_mountains)

        r_fc = client.get("/api/v1/mountains/stowe/forecast?elevation=summit")
        assert r_fc.status_code == 200
        fc = r_fc.json()
        assert fc["mountain"]["id"] == "stowe"
        assert fc["elevation_band"] == "summit"
        assert fc["elevation_ft"] == 3625
        assert len(fc["daily"]) >= 6
        assert len(fc["hourly"]) >= 120
        assert "short_0_24h" in fc["lead_bucket_weights"]
        assert fc["discussion"]["wfo_id"] == "BTV"

        r_disc = client.get("/api/v1/discussions")
        assert r_disc.status_code == 200
        assert len(r_disc.json()) >= 4

        r_ml = client.get("/api/v1/ml/status?scope=global")
        assert r_ml.status_code == 200
        ml_data = r_ml.json()
        assert ml_data["total_training_samples"] > 0
        assert len(ml_data["metrics"]) == 9  # 3 elevation bands x 3 lead buckets
