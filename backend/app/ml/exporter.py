from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, List, Optional

from sklearn.ensemble import HistGradientBoostingRegressor

from app.config import (
    MODEL_DISPLAY_NAMES,
    MODEL_SOURCES,
    NORTHEAST_MOUNTAINS,
    OPEN_METEO_MODEL_MAP,
    WFO_OFFICES,
)
from app.ml.ensemble import EnsembleArtifact, SnowEnsembleModel
from app.ml.trainer import train_or_refresh_ensemble
from app.storage import ForecastStorage

DEFAULT_IOS_EXPORT_PATH = (
    Path(__file__).resolve().parents[3]
    / "ios"
    / "Packages"
    / "SnowForecastKit"
    / "Sources"
    / "SnowForecastKit"
    / "Resources"
    / "ml_ensemble_v1.json"
)


def _export_tree_ensemble(model: Optional[HistGradientBoostingRegressor]) -> Optional[Dict[str, Any]]:
    if model is None:
        return None
    baseline = float(model._baseline_prediction[0, 0])
    trees: List[List[Dict[str, Any]]] = []
    for predictor_row in model._predictors:
        nodes = predictor_row[0].nodes
        exported_nodes: List[Dict[str, Any]] = []
        for node in nodes:
            is_leaf = bool(node["is_leaf"])
            val = float(node["value"])
            thresh = float(node["num_threshold"])
            if not math.isfinite(thresh):
                thresh = 0.0
            exported_nodes.append(
                {
                    "is_leaf": is_leaf,
                    "feature_idx": int(node["feature_idx"]),
                    "threshold": round(thresh, 6),
                    "left": int(node["left"]),
                    "right": int(node["right"]),
                    "value": round(val, 6),
                    "missing_go_to_left": bool(node["missing_go_to_left"]),
                }
            )
        trees.append(exported_nodes)
    return {
        "baseline": round(baseline, 6),
        "trees": trees,
    }


def build_export_payload(artifact: EnsembleArtifact) -> Dict[str, Any]:
    buckets_out: List[Dict[str, Any]] = []
    for (scope, band, lead_bucket), bm in sorted(artifact.buckets.items()):
        buckets_out.append(
            {
                "scope": scope,
                "elevation_band": band,
                "lead_bucket": lead_bucket,
                "snow_weights": {k: round(v, 6) for k, v in bm.snow_weights.items()},
                "temp_weights": {k: round(v, 6) for k, v in bm.temp_weights.items()},
                "snow_residual_std": round(bm.snow_residual_std, 6),
                "temp_residual_std": round(bm.temp_residual_std, 6),
                "sample_count": bm.sample_count,
                "blended_snow_mae_in": bm.blended_snow_mae_in,
                "blended_temp_mae_f": bm.blended_temp_mae_f,
                "best_single_model": bm.best_single_model,
                "best_single_snow_mae_in": bm.best_single_snow_mae_in,
                "snow_residual_trees": _export_tree_ensemble(bm.snow_residual_model),
                "temp_residual_trees": _export_tree_ensemble(bm.temp_residual_model),
            }
        )

    mountains_out = [
        {
            "id": m.id,
            "name": m.name,
            "state": m.state,
            "region": m.region,
            "latitude": m.latitude,
            "longitude": m.longitude,
            "elevations": {
                "base_ft": m.elevations.base_ft,
                "mid_ft": m.elevations.mid_ft,
                "summit_ft": m.elevations.summit_ft,
            },
            "nws_wfo": m.nws_wfo,
            "station_id": m.station_id,
            "aspect": m.aspect,
            "orographic_factor": m.orographic_factor,
        }
        for m in NORTHEAST_MOUNTAINS
    ]

    wfo_out = {
        k: {
            "id": v.id,
            "name": v.name,
            "city_state": v.city_state,
            "coverage_summary": v.coverage_summary,
        }
        for k, v in WFO_OFFICES.items()
    }

    return {
        "version": artifact.version,
        "trained_at": artifact.trained_at.isoformat(),
        "total_samples": artifact.total_samples,
        "model_sources": MODEL_SOURCES,
        "model_display_names": MODEL_DISPLAY_NAMES,
        "open_meteo_model_map": OPEN_METEO_MODEL_MAP,
        "mountains": mountains_out,
        "wfo_offices": wfo_out,
        "buckets": buckets_out,
    }


def export_ensemble_to_json(
    ensemble: SnowEnsembleModel,
    output_path: Path = DEFAULT_IOS_EXPORT_PATH,
) -> Path:
    payload = build_export_payload(ensemble.artifact)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, separators=(",", ":"))
    return output_path


if __name__ == "__main__":
    storage = ForecastStorage()
    model = SnowEnsembleModel()
    train_or_refresh_ensemble(storage, model, force_retrain=False)
    out = export_ensemble_to_json(model)
    size_kb = out.stat().st_size / 1024.0
    print(f"Exported on-device ML model to {out} ({size_kb:.1f} KB, {len(model.artifact.buckets)} buckets)")
