from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from app.clients.nws import NWSClient
from app.clients.open_meteo import OpenMeteoClient
from app.config import MOUNTAINS_BY_ID, NORTHEAST_MOUNTAINS, WFO_OFFICES
from app.ml.ensemble import SnowEnsembleModel
from app.ml.exporter import build_export_payload, export_ensemble_to_json
from app.ml.trainer import train_or_refresh_ensemble
from app.models import (
    MeteorologistDiscussion,
    MountainForecastResponse,
    MountainSummary,
    TrainingStatusResponse,
)
from app.services.forecaster import ForecastService
from app.storage import ForecastStorage

storage = ForecastStorage()
ensemble = SnowEnsembleModel()
open_meteo_client = OpenMeteoClient()
nws_client = NWSClient()
forecast_service = ForecastService(
    open_meteo=open_meteo_client,
    nws=nws_client,
    ensemble=ensemble,
    storage=storage,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    train_or_refresh_ensemble(storage, ensemble, force_retrain=False)
    yield


app = FastAPI(
    title="Northeast Snow Forecast API",
    description=(
        "Multi-source ML weather ensemble & local NWS meteorologist discussions "
        "for Northeast ski mountains."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict:
    return {
        "status": "ok",
        "mountains": len(NORTHEAST_MOUNTAINS),
        "ml_model_version": ensemble.artifact.version,
        "ml_buckets_loaded": len(ensemble.artifact.buckets),
    }


@app.get("/api/v1/mountains", response_model=List[MountainSummary])
async def list_mountains(
    state: Optional[str] = Query(default=None, description="Two-letter state filter, e.g. VT, NH, ME, NY, MA")
) -> List[MountainSummary]:
    return await forecast_service.get_all_mountain_summaries(state=state)


@app.get("/api/v1/mountains/{mountain_id}/forecast", response_model=MountainForecastResponse)
async def get_mountain_forecast(
    mountain_id: str,
    elevation: str = Query(default="summit", pattern="^(base|mid|summit)$"),
) -> MountainForecastResponse:
    if mountain_id not in MOUNTAINS_BY_ID:
        raise HTTPException(status_code=404, detail=f"Mountain '{mountain_id}' not found")
    return await forecast_service.get_mountain_forecast(mountain_id, elevation_band=elevation)


@app.get("/api/v1/discussions", response_model=List[MeteorologistDiscussion])
async def list_discussions() -> List[MeteorologistDiscussion]:
    return await forecast_service.get_all_discussions()


@app.get("/api/v1/discussions/{wfo_id}", response_model=MeteorologistDiscussion)
async def get_discussion(wfo_id: str) -> MeteorologistDiscussion:
    wfo_upper = wfo_id.upper()
    if wfo_upper not in WFO_OFFICES:
        raise HTTPException(status_code=404, detail=f"WFO '{wfo_upper}' not configured")
    return await forecast_service.get_discussion(wfo_upper)


@app.get("/api/v1/ml/status", response_model=TrainingStatusResponse)
async def ml_status(
    scope: Optional[str] = Query(default="global", description="Filter metrics by 'global' or mountain_id")
) -> TrainingStatusResponse:
    metrics = ensemble.performance_metrics(scope=scope)
    if not metrics and scope is not None:
        # Fall back to global if a mountain doesn't have its own bucket yet
        metrics = ensemble.performance_metrics(scope="global")
    return TrainingStatusResponse(
        trained_at=ensemble.artifact.trained_at,
        model_version=ensemble.artifact.version,
        total_training_samples=ensemble.artifact.total_samples,
        metrics=metrics,
    )


@app.post("/api/v1/ml/ingest-observations")
async def ingest_observations() -> dict:
    stations = sorted({m.station_id for m in NORTHEAST_MOUNTAINS})
    obs_list = await asyncio.gather(*(nws_client.fetch_latest_observation(st) for st in stations))
    saved = 0
    for obs in obs_list:
        if obs is not None:
            storage.save_observation(
                station_id=obs.station_id,
                observed_at=obs.observed_at,
                temp_f=obs.temp_f,
                wind_mph=obs.wind_mph,
                precip_1h_in=obs.precip_1h_in,
            )
            saved += 1
    return {"stations_checked": len(stations), "observations_saved": saved}


@app.get("/api/v1/ml/export")
async def export_ml_bundle() -> dict:
    return build_export_payload(ensemble.artifact)


@app.post("/api/v1/ml/retrain", response_model=TrainingStatusResponse)
async def retrain_model() -> TrainingStatusResponse:
    await ingest_observations()
    artifact = train_or_refresh_ensemble(storage, ensemble, force_retrain=True)
    export_ensemble_to_json(ensemble)
    forecast_service._forecast_cache.clear()
    return TrainingStatusResponse(
        trained_at=artifact.trained_at,
        model_version=artifact.version,
        total_training_samples=artifact.total_samples,
        metrics=ensemble.performance_metrics(scope="global"),
    )
