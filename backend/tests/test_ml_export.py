from __future__ import annotations

import json
from pathlib import Path

from app.ml.ensemble import SnowEnsembleModel
from app.ml.exporter import export_ensemble_to_json
from app.ml.trainer import generate_northeast_bootstrap_examples


def test_export_ensemble_json_contains_weights_and_trees(tmp_path: Path):
    examples = generate_northeast_bootstrap_examples(samples_per_mountain_bucket=8, seed=42)
    model = SnowEnsembleModel(artifact_path=tmp_path / "model.pkl")
    model.fit(examples, min_mountain_samples=8)

    out_path = tmp_path / "exported.json"
    export_ensemble_to_json(model, output_path=out_path)
    assert out_path.exists()

    payload = json.loads(out_path.read_text(encoding="utf-8"))
    assert payload["version"] == "ml-stacker-v1"
    assert len(payload["mountains"]) == 18
    assert len(payload["buckets"]) > 9

    sample_bucket = next(
        b
        for b in payload["buckets"]
        if b["scope"] == "global"
        and b["elevation_band"] == "summit"
        and b["lead_bucket"] == "short_0_24h"
    )
    assert abs(sum(sample_bucket["snow_weights"].values()) - 1.0) < 1e-4
    assert sample_bucket["snow_residual_trees"] is not None
    assert len(sample_bucket["snow_residual_trees"]["trees"]) > 0
