from __future__ import annotations

from datetime import datetime
from typing import Dict, List, Optional
from pydantic import BaseModel, Field


class ElevationSummary(BaseModel):
    base_ft: int
    mid_ft: int
    summit_ft: int


class MountainSummary(BaseModel):
    id: str
    name: str
    state: str
    region: str
    latitude: float
    longitude: float
    elevations: ElevationSummary
    nws_wfo: str
    station_id: str
    aspect: str
    snow_24h_in: float
    snow_72h_in: float
    snow_5d_in: float
    summit_temp_f: float
    summit_wind_mph: float
    confidence: str  # "High", "Moderate", "Low"
    lift_hold_risk: str = "Low"  # "Low", "Moderate", "High"
    surface_quality: str = "Packed Powder"
    warm_nose_risk: bool = False
    active_alert_count: int = 0
    headline: str
    updated_at: datetime


class ModelWeightRatio(BaseModel):
    source: str
    display_name: str
    weight: float = Field(ge=0.0, le=1.0)
    snow_24h_in: Optional[float] = None
    snow_72h_in: Optional[float] = None
    snow_5d_in: Optional[float] = None
    avg_temp_f: Optional[float] = None


class DailyForecastPoint(BaseModel):
    date: str  # YYYY-MM-DD
    snow_in: float
    snow_p10_in: float
    snow_p90_in: float
    liquid_precip_in: float
    slr_ratio: float
    temp_high_f: float
    temp_low_f: float
    wind_max_mph: float
    wind_gust_mph: float
    precip_prob_pct: int
    condition: str
    source_snow_in: Dict[str, float]


class HourlyForecastPoint(BaseModel):
    time: datetime
    lead_hours: int
    lead_bucket: str
    snow_in: float
    snow_p10_in: float
    snow_p90_in: float
    liquid_precip_in: float
    temp_f: float
    wind_mph: float
    wind_gust_mph: float
    freezing_level_ft: Optional[int] = None
    temp_850hpa_f: Optional[float] = None
    wet_bulb_f: Optional[float] = None
    warm_nose_risk: bool = False
    slr_ratio: float
    precip_type: str  # "Snow", "Mix", "Rain", "Dry"
    source_snow_in: Dict[str, float]
    source_temp_f: Dict[str, float]


class NWSAlert(BaseModel):
    id: str
    event: str
    severity: str
    headline: str
    description: str
    expires: Optional[datetime] = None


class MeteorologistHighlight(BaseModel):
    category: str  # "Snow & Upslope", "Temp & Freezing Level", "Wind & Hold Risk", "Timing", "Confidence"
    summary: str


class MeteorologistDiscussion(BaseModel):
    wfo_id: str
    wfo_name: str
    issued_at: datetime
    forecaster: Optional[str] = None
    product_id: str
    mountain_relevance_summary: str
    highlights: List[MeteorologistHighlight]
    synopsis: Optional[str] = None
    short_term: Optional[str] = None
    long_term: Optional[str] = None
    raw_text: str
    covered_mountain_ids: List[str]
    is_live: bool = True


class MountainForecastResponse(BaseModel):
    mountain: MountainSummary
    elevation_band: str
    elevation_ft: int
    lead_bucket_weights: Dict[str, List[ModelWeightRatio]]
    daily: List[DailyForecastPoint]
    hourly: List[HourlyForecastPoint]
    discussion: Optional[MeteorologistDiscussion] = None
    alerts: List[NWSAlert] = Field(default_factory=list)
    data_sources_used: List[str]
    is_live_weather: bool
    ml_model_version: str


class ModelPerformanceMetric(BaseModel):
    scope: str  # e.g. "global", or mountain_id
    elevation_band: str
    lead_bucket: str
    sample_count: int
    blended_snow_mae_in: float
    blended_temp_mae_f: float
    best_single_model: str
    best_single_snow_mae_in: float
    weights: List[ModelWeightRatio]


class TrainingStatusResponse(BaseModel):
    trained_at: Optional[datetime]
    model_version: str
    total_training_samples: int
    metrics: List[ModelPerformanceMetric]
