from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

from app.config import DB_PATH, MOUNTAINS_BY_ID
from app.ml.ensemble import TrainingExample
from app.ml.features import lead_bucket_for_hours


class ForecastStorage:
    """SQLite storage for forecast snapshots, station observations, and AFD cache."""

    def __init__(self, db_path: Path = DB_PATH) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS forecast_snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    mountain_id TEXT NOT NULL,
                    elevation_band TEXT NOT NULL,
                    elevation_ft INTEGER NOT NULL,
                    issued_at TEXT NOT NULL,
                    valid_time TEXT NOT NULL,
                    lead_hours INTEGER NOT NULL,
                    source_snow_json TEXT NOT NULL,
                    source_temp_json TEXT NOT NULL,
                    wind_mph REAL NOT NULL,
                    UNIQUE(mountain_id, elevation_band, issued_at, valid_time)
                );

                CREATE INDEX IF NOT EXISTS idx_snapshots_lookup
                ON forecast_snapshots(mountain_id, valid_time);

                CREATE TABLE IF NOT EXISTS observations (
                    station_id TEXT NOT NULL,
                    observed_at TEXT NOT NULL,
                    temp_f REAL,
                    wind_mph REAL,
                    precip_1h_in REAL,
                    snow_1h_in REAL,
                    PRIMARY KEY(station_id, observed_at)
                );

                CREATE TABLE IF NOT EXISTS afd_cache (
                    wfo_id TEXT PRIMARY KEY,
                    product_id TEXT NOT NULL,
                    issued_at TEXT NOT NULL,
                    forecaster TEXT,
                    raw_text TEXT NOT NULL,
                    fetched_at TEXT NOT NULL
                );
                """
            )

    def save_forecast_snapshots(
        self,
        mountain_id: str,
        elevation_band: str,
        elevation_ft: int,
        issued_at: datetime,
        rows: List[dict],
    ) -> None:
        issued_hour = issued_at.replace(minute=0, second=0, microsecond=0).isoformat()
        with self._connect() as conn:
            for row in rows:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO forecast_snapshots (
                        mountain_id, elevation_band, elevation_ft, issued_at,
                        valid_time, lead_hours, source_snow_json, source_temp_json, wind_mph
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        mountain_id,
                        elevation_band,
                        elevation_ft,
                        issued_hour,
                        row["valid_time"].isoformat(),
                        int(row["lead_hours"]),
                        json.dumps(row["source_snow"]),
                        json.dumps(row["source_temp"]),
                        float(row.get("wind_mph", 10.0)),
                    ),
                )

    def save_observation(
        self,
        station_id: str,
        observed_at: datetime,
        temp_f: Optional[float],
        wind_mph: Optional[float],
        precip_1h_in: Optional[float],
        snow_1h_in: Optional[float] = None,
    ) -> None:
        obs_hour = observed_at.replace(minute=0, second=0, microsecond=0).isoformat()
        with self._connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO observations (
                    station_id, observed_at, temp_f, wind_mph, precip_1h_in, snow_1h_in
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (station_id.upper(), obs_hour, temp_f, wind_mph, precip_1h_in, snow_1h_in),
            )

    def fetch_verified_training_examples(self) -> List[TrainingExample]:
        examples: List[TrainingExample] = []
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT
                    fs.mountain_id,
                    fs.elevation_band,
                    fs.elevation_ft,
                    fs.valid_time,
                    fs.lead_hours,
                    fs.source_snow_json,
                    fs.source_temp_json,
                    fs.wind_mph,
                    o.station_id AS obs_station_id,
                    o.temp_f AS obs_temp_f,
                    o.precip_1h_in AS obs_precip_in,
                    o.snow_1h_in AS obs_snow_in
                FROM forecast_snapshots fs
                JOIN observations o
                    ON fs.valid_time = o.observed_at
                WHERE o.temp_f IS NOT NULL
                """
            ).fetchall()

        for row in rows:
            m_cfg = MOUNTAINS_BY_ID.get(row["mountain_id"])
            if not m_cfg or row["obs_station_id"] != m_cfg.station_id:
                continue
            obs_snow = row["obs_snow_in"]
            if obs_snow is None:
                precip = float(row["obs_precip_in"] or 0.0)
                obs_snow = precip * 11.0 if float(row["obs_temp_f"]) <= 32.0 else 0.0
            valid_dt = datetime.fromisoformat(row["valid_time"])
            if valid_dt.tzinfo is None:
                valid_dt = valid_dt.replace(tzinfo=timezone.utc)
            examples.append(
                TrainingExample(
                    mountain_id=row["mountain_id"],
                    elevation_band=row["elevation_band"],
                    elevation_ft=int(row["elevation_ft"]),
                    orographic_factor=m_cfg.orographic_factor,
                    lead_hours=int(row["lead_hours"]),
                    lead_bucket=lead_bucket_for_hours(int(row["lead_hours"])),
                    valid_time=valid_dt,
                    wind_mph=float(row["wind_mph"]),
                    source_snow=json.loads(row["source_snow_json"]),
                    source_temp=json.loads(row["source_temp_json"]),
                    observed_snow_in=float(obs_snow),
                    observed_temp_f=float(row["obs_temp_f"]),
                    is_bootstrap=False,
                )
            )
        return examples

    def save_afd(
        self,
        wfo_id: str,
        product_id: str,
        issued_at: datetime,
        forecaster: Optional[str],
        raw_text: str,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO afd_cache (
                    wfo_id, product_id, issued_at, forecaster, raw_text, fetched_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    wfo_id.upper(),
                    product_id,
                    issued_at.isoformat(),
                    forecaster,
                    raw_text,
                    datetime.now(timezone.utc).isoformat(),
                ),
            )

    def get_cached_afd(self, wfo_id: str) -> Optional[dict]:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM afd_cache WHERE wfo_id = ?",
                (wfo_id.upper(),),
            ).fetchone()
        return dict(row) if row else None
