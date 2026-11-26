from __future__ import annotations

import logging
import math
import pickle
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.linear_model import Ridge

from app.config import (
    ELEVATION_BANDS,
    LEAD_BUCKETS,
    MODEL_DIR,
    MODEL_DISPLAY_NAMES,
    MODEL_SOURCES,
)
from app.ml.features import build_residual_features
from app.models import ModelPerformanceMetric, ModelWeightRatio

logger = logging.getLogger(__name__)

# Meteorology-informed priors used only before/when a bucket lacks training rows.
PRIOR_WEIGHTS: Dict[str, Dict[str, float]] = {
    "short_0_24h": {
        "hrrr": 0.34,
        "nam": 0.24,
        "ecmwf": 0.16,
        "nws": 0.14,
        "gem": 0.07,
        "gfs": 0.05,
    },
    "medium_24_72h": {
        "hrrr": 0.08,
        "nam": 0.23,
        "ecmwf": 0.31,
        "nws": 0.17,
        "gem": 0.12,
        "gfs": 0.09,
    },
    "extended_72_168h": {
        "hrrr": 0.00,
        "nam": 0.04,
        "ecmwf": 0.42,
        "nws": 0.14,
        "gem": 0.22,
        "gfs": 0.18,
    },
}


@dataclass
class TrainingExample:
    mountain_id: str
    elevation_band: str
    elevation_ft: int
    orographic_factor: float
    lead_hours: int
    lead_bucket: str
    valid_time: datetime
    wind_mph: float
    source_snow: Dict[str, Optional[float]]
    source_temp: Dict[str, Optional[float]]
    observed_snow_in: float
    observed_temp_f: float
    is_bootstrap: bool = False


@dataclass
class BucketModel:
    scope: str
    elevation_band: str
    lead_bucket: str
    snow_weights: Dict[str, float]
    temp_weights: Dict[str, float]
    snow_residual_std: float
    temp_residual_std: float
    sample_count: int
    blended_snow_mae_in: float
    blended_temp_mae_f: float
    best_single_model: str
    best_single_snow_mae_in: float
    snow_residual_model: Optional[HistGradientBoostingRegressor] = None
    temp_residual_model: Optional[HistGradientBoostingRegressor] = None


@dataclass
class BlendedHourPrediction:
    snow_in: float
    snow_p10_in: float
    snow_p90_in: float
    temp_f: float
    active_snow_weights: Dict[str, float]


@dataclass
class EnsembleArtifact:
    version: str = "ml-stacker-v1"
    trained_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    total_samples: int = 0
    buckets: Dict[Tuple[str, str, str], BucketModel] = field(default_factory=dict)


def _normalize_weights(
    raw: Dict[str, float], active_sources: Optional[List[str]] = None
) -> Dict[str, float]:
    keys = active_sources if active_sources is not None else MODEL_SOURCES
    filtered = {k: max(0.0, float(raw.get(k, 0.0))) for k in keys}
    total = sum(filtered.values())
    if total <= 1e-9:
        uniform = 1.0 / max(1, len(keys))
        return {k: uniform for k in keys}
    return {k: v / total for k, v in filtered.items()}


def _impute_source_matrix(
    examples: List[TrainingExample], attr: str, fallback_value: float
) -> np.ndarray:
    rows = []
    for ex in examples:
        mapping: Dict[str, Optional[float]] = getattr(ex, attr)
        present = [v for v in mapping.values() if v is not None]
        mean_val = sum(present) / len(present) if present else fallback_value
        rows.append(
            [
                float(mapping[s]) if mapping.get(s) is not None else mean_val
                for s in MODEL_SOURCES
            ]
        )
    return np.asarray(rows, dtype=np.float64)


def _fit_positive_ridge_weights(
    X: np.ndarray, y: np.ndarray, prior: Dict[str, float]
) -> Dict[str, float]:
    if len(y) < 12 or np.allclose(X, 0.0):
        return _normalize_weights(prior)

    # Blend slight L2 shrinkage toward uniform/prior stability via positive Ridge.
    reg = Ridge(alpha=2.5, positive=True, fit_intercept=False)
    reg.fit(X, y)
    coefs = np.maximum(0.0, reg.coef_)
    if float(coefs.sum()) <= 1e-8:
        return _normalize_weights(prior)

    learned = {s: float(coefs[idx]) for idx, s in enumerate(MODEL_SOURCES)}
    # Stabilize with 10% prior regularizer when sample size is modest (< 120 rows)
    prior_blend = max(0.05, min(0.35, 25.0 / max(1, len(y))))
    norm_learned = _normalize_weights(learned)
    norm_prior = _normalize_weights(prior)
    combined = {
        s: (1.0 - prior_blend) * norm_learned[s] + prior_blend * norm_prior[s]
        for s in MODEL_SOURCES
    }
    return _normalize_weights(combined)


def _fit_bucket(
    scope: str,
    elevation_band: str,
    lead_bucket: str,
    examples: List[TrainingExample],
) -> BucketModel:
    prior = PRIOR_WEIGHTS.get(lead_bucket, PRIOR_WEIGHTS["medium_24_72h"])

    X_snow = _impute_source_matrix(examples, "source_snow", 0.0)
    y_snow = np.asarray([ex.observed_snow_in for ex in examples], dtype=np.float64)

    X_temp = _impute_source_matrix(examples, "source_temp", 25.0)
    y_temp = np.asarray([ex.observed_temp_f for ex in examples], dtype=np.float64)

    # 80/20 deterministic temporal holdout for honest validation metrics
    n = len(examples)
    split = max(1, int(n * 0.8)) if n >= 20 else n
    train_idx = slice(0, split)
    val_idx = slice(split, n) if split < n else slice(0, n)

    snow_weights = _fit_positive_ridge_weights(X_snow[train_idx], y_snow[train_idx], prior)
    temp_weights = _fit_positive_ridge_weights(X_temp[train_idx], y_temp[train_idx], prior)

    w_snow_vec = np.asarray([snow_weights[s] for s in MODEL_SOURCES], dtype=np.float64)
    w_temp_vec = np.asarray([temp_weights[s] for s in MODEL_SOURCES], dtype=np.float64)

    linear_snow_pred = X_snow @ w_snow_vec
    linear_temp_pred = X_temp @ w_temp_vec

    # Residual Gradient Boosting corrector
    X_res = np.asarray(
        [
            build_residual_features(
                source_snow=ex.source_snow,
                source_temp=ex.source_temp,
                elevation_ft=ex.elevation_ft,
                orographic_factor=ex.orographic_factor,
                lead_hours=ex.lead_hours,
                wind_mph=ex.wind_mph,
                valid_time=ex.valid_time,
            )
            for ex in examples
        ],
        dtype=np.float64,
    )

    snow_res_target = y_snow - linear_snow_pred
    temp_res_target = y_temp - linear_temp_pred

    snow_gb: Optional[HistGradientBoostingRegressor] = None
    temp_gb: Optional[HistGradientBoostingRegressor] = None

    if n >= 30:
        snow_gb = HistGradientBoostingRegressor(
            max_depth=3,
            max_iter=60,
            learning_rate=0.06,
            l2_regularization=1.0,
            min_samples_leaf=10,
            random_state=42,
        )
        snow_gb.fit(X_res[train_idx], snow_res_target[train_idx])

        temp_gb = HistGradientBoostingRegressor(
            max_depth=3,
            max_iter=60,
            learning_rate=0.06,
            l2_regularization=1.0,
            min_samples_leaf=10,
            random_state=42,
        )
        temp_gb.fit(X_res[train_idx], temp_res_target[train_idx])

        val_snow_pred = np.maximum(
            0.0, linear_snow_pred[val_idx] + snow_gb.predict(X_res[val_idx])
        )
        val_temp_pred = linear_temp_pred[val_idx] + temp_gb.predict(X_res[val_idx])
    else:
        val_snow_pred = np.maximum(0.0, linear_snow_pred[val_idx])
        val_temp_pred = linear_temp_pred[val_idx]

    val_y_snow = y_snow[val_idx]
    val_y_temp = y_temp[val_idx]

    blended_snow_mae = float(np.mean(np.abs(val_snow_pred - val_y_snow)))
    blended_temp_mae = float(np.mean(np.abs(val_temp_pred - val_y_temp)))
    snow_res_std = float(np.std(val_snow_pred - val_y_snow))
    temp_res_std = float(np.std(val_temp_pred - val_y_temp))

    # Compare against individual models on the same validation slice
    best_single_model = MODEL_SOURCES[0]
    best_single_mae = float("inf")
    for idx, src in enumerate(MODEL_SOURCES):
        # Skip models that are mostly absent in extended range
        raw_col = [ex.source_snow.get(src) for ex in examples[val_idx]]
        coverage = sum(1 for v in raw_col if v is not None) / max(1, len(raw_col))
        if coverage < 0.3:
            continue
        mae = float(np.mean(np.abs(X_snow[val_idx, idx] - val_y_snow)))
        if mae < best_single_mae:
            best_single_mae = mae
            best_single_model = src

    if math.isinf(best_single_mae):
        best_single_mae = blended_snow_mae

    # Refit final GBR on full bucket dataset after computing holdout metrics
    if n >= 30 and snow_gb is not None and temp_gb is not None:
        snow_gb.fit(X_res, snow_res_target)
        temp_gb.fit(X_res, temp_res_target)

    return BucketModel(
        scope=scope,
        elevation_band=elevation_band,
        lead_bucket=lead_bucket,
        snow_weights=snow_weights,
        temp_weights=temp_weights,
        snow_residual_std=max(0.04, snow_res_std),
        temp_residual_std=max(0.8, temp_res_std),
        sample_count=n,
        blended_snow_mae_in=round(blended_snow_mae, 4),
        blended_temp_mae_f=round(blended_temp_mae, 2),
        best_single_model=best_single_model,
        best_single_snow_mae_in=round(best_single_mae, 4),
        snow_residual_model=snow_gb,
        temp_residual_model=temp_gb,
    )


class SnowEnsembleModel:
    """Loads, trains, persists, and serves the multi-model ML stacker."""

    def __init__(self, artifact_path: Path = MODEL_DIR / "ensemble_v1.pkl") -> None:
        self.artifact_path = artifact_path
        self.artifact = self._load_or_init()

    def _load_or_init(self) -> EnsembleArtifact:
        if self.artifact_path.exists():
            try:
                with open(self.artifact_path, "rb") as f:
                    loaded = pickle.load(f)
                if isinstance(loaded, EnsembleArtifact) and loaded.buckets:
                    return loaded
            except Exception as exc:
                logger.warning("Failed to load ensemble artifact: %s", exc)
        return EnsembleArtifact()

    def save(self) -> None:
        self.artifact_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.artifact_path, "wb") as f:
            pickle.dump(self.artifact, f)

    def fit(self, examples: List[TrainingExample], min_mountain_samples: int = 35) -> EnsembleArtifact:
        buckets: Dict[Tuple[str, str, str], BucketModel] = {}

        # 1. Global (Northeast-wide) models per (elevation_band, lead_bucket)
        for band in ELEVATION_BANDS:
            for lead_bucket in LEAD_BUCKETS:
                subset = [
                    ex
                    for ex in examples
                    if ex.elevation_band == band and ex.lead_bucket == lead_bucket
                ]
                if not subset:
                    subset = [ex for ex in examples if ex.lead_bucket == lead_bucket]
                if subset:
                    buckets[("global", band, lead_bucket)] = _fit_bucket(
                        "global", band, lead_bucket, subset
                    )

        # 2. Per-mountain fine-grained models when enough mountain-specific samples exist
        by_mountain: Dict[str, List[TrainingExample]] = {}
        for ex in examples:
            by_mountain.setdefault(ex.mountain_id, []).append(ex)

        for mountain_id, m_examples in by_mountain.items():
            for band in ELEVATION_BANDS:
                for lead_bucket in LEAD_BUCKETS:
                    subset = [
                        ex
                        for ex in m_examples
                        if ex.elevation_band == band and ex.lead_bucket == lead_bucket
                    ]
                    if len(subset) >= min_mountain_samples:
                        buckets[(mountain_id, band, lead_bucket)] = _fit_bucket(
                            mountain_id, band, lead_bucket, subset
                        )

        self.artifact = EnsembleArtifact(
            version="ml-stacker-v1",
            trained_at=datetime.now(timezone.utc),
            total_samples=len(examples),
            buckets=buckets,
        )
        self.save()
        return self.artifact

    def _resolve_bucket(
        self, mountain_id: str, elevation_band: str, lead_bucket: str
    ) -> Optional[BucketModel]:
        for key in (
            (mountain_id, elevation_band, lead_bucket),
            ("global", elevation_band, lead_bucket),
            ("global", "mid", lead_bucket),
        ):
            if key in self.artifact.buckets:
                return self.artifact.buckets[key]
        return None

    def get_weights_for_bucket(
        self, mountain_id: str, elevation_band: str, lead_bucket: str
    ) -> Dict[str, float]:
        bucket = self._resolve_bucket(mountain_id, elevation_band, lead_bucket)
        if bucket is not None:
            return dict(bucket.snow_weights)
        return _normalize_weights(PRIOR_WEIGHTS.get(lead_bucket, PRIOR_WEIGHTS["medium_24_72h"]))

    def predict_hour(
        self,
        mountain_id: str,
        elevation_band: str,
        elevation_ft: int,
        orographic_factor: float,
        lead_hours: int,
        lead_bucket: str,
        valid_time: datetime,
        wind_mph: float,
        source_snow: Dict[str, Optional[float]],
        source_temp: Dict[str, Optional[float]],
    ) -> BlendedHourPrediction:
        bucket = self._resolve_bucket(mountain_id, elevation_band, lead_bucket)

        active_snow_sources = [k for k, v in source_snow.items() if v is not None]
        active_temp_sources = [k for k, v in source_temp.items() if v is not None]

        raw_snow_weights = (
            bucket.snow_weights
            if bucket is not None
            else PRIOR_WEIGHTS.get(lead_bucket, PRIOR_WEIGHTS["medium_24_72h"])
        )
        raw_temp_weights = (
            bucket.temp_weights
            if bucket is not None
            else PRIOR_WEIGHTS.get(lead_bucket, PRIOR_WEIGHTS["medium_24_72h"])
        )

        norm_snow_w = _normalize_weights(raw_snow_weights, active_snow_sources or MODEL_SOURCES)
        norm_temp_w = _normalize_weights(raw_temp_weights, active_temp_sources or MODEL_SOURCES)

        if active_snow_sources:
            base_snow = sum(
                norm_snow_w[s] * float(source_snow[s]) for s in active_snow_sources  # type: ignore[arg-type]
            )
        else:
            base_snow = 0.0

        if active_temp_sources:
            base_temp = sum(
                norm_temp_w[s] * float(source_temp[s]) for s in active_temp_sources  # type: ignore[arg-type]
            )
        else:
            base_temp = 26.0

        snow_pred = base_snow
        temp_pred = base_temp
        res_std = bucket.snow_residual_std if bucket is not None else 0.08

        if bucket is not None and (
            bucket.snow_residual_model is not None or bucket.temp_residual_model is not None
        ):
            feat = np.asarray(
                [
                    build_residual_features(
                        source_snow=source_snow,
                        source_temp=source_temp,
                        elevation_ft=elevation_ft,
                        orographic_factor=orographic_factor,
                        lead_hours=lead_hours,
                        wind_mph=wind_mph,
                        valid_time=valid_time,
                    )
                ],
                dtype=np.float64,
            )
            if bucket.snow_residual_model is not None and base_snow > 0.005:
                # Dampen residual adjustment on dry hours so we don't hallucinate snow out of zero precip
                snow_adj = float(bucket.snow_residual_model.predict(feat)[0])
                snow_pred = max(0.0, base_snow + max(-0.5 * base_snow, min(0.6 * base_snow, snow_adj)))
            if bucket.temp_residual_model is not None:
                temp_adj = float(bucket.temp_residual_model.predict(feat)[0])
                temp_pred = base_temp + max(-4.0, min(4.0, temp_adj))

        snow_vals = [float(v) for v in source_snow.values() if v is not None]
        spread = float(np.std(snow_vals)) if len(snow_vals) > 1 else 0.0
        half_band = max(0.0, 1.28 * math.hypot(spread, res_std if snow_pred > 0.01 else 0.0))

        p10 = max(0.0, snow_pred - half_band)
        p90 = snow_pred + half_band if snow_pred > 0.005 else 0.0

        return BlendedHourPrediction(
            snow_in=round(max(0.0, snow_pred), 3),
            snow_p10_in=round(p10, 3),
            snow_p90_in=round(p90, 3),
            temp_f=round(temp_pred, 1),
            active_snow_weights={s: round(norm_snow_w.get(s, 0.0), 4) for s in MODEL_SOURCES},
        )

    def performance_metrics(self, scope: Optional[str] = None) -> List[ModelPerformanceMetric]:
        metrics: List[ModelPerformanceMetric] = []
        for (b_scope, band, lead_bucket), bm in sorted(self.artifact.buckets.items()):
            if scope is not None and b_scope != scope:
                continue
            weights_list = [
                ModelWeightRatio(
                    source=src,
                    display_name=MODEL_DISPLAY_NAMES.get(src, src.upper()),
                    weight=round(bm.snow_weights.get(src, 0.0), 4),
                )
                for src in MODEL_SOURCES
            ]
            weights_list.sort(key=lambda w: w.weight, reverse=True)
            metrics.append(
                ModelPerformanceMetric(
                    scope=b_scope,
                    elevation_band=band,
                    lead_bucket=lead_bucket,
                    sample_count=bm.sample_count,
                    blended_snow_mae_in=bm.blended_snow_mae_in,
                    blended_temp_mae_f=bm.blended_temp_mae_f,
                    best_single_model=MODEL_DISPLAY_NAMES.get(
                        bm.best_single_model, bm.best_single_model
                    ),
                    best_single_snow_mae_in=bm.best_single_snow_mae_in,
                    weights=weights_list,
                )
            )
        return metrics
