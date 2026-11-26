from __future__ import annotations

import asyncio
import math
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple

from app.clients.nws import NWSClient, NWSGridForecast
from app.clients.open_meteo import OpenMeteoBundle, OpenMeteoClient, RawModelHour
from app.config import (
    LEAD_BUCKETS,
    MODEL_DISPLAY_NAMES,
    MODEL_SOURCES,
    MOUNTAINS_BY_ID,
    MountainConfig,
    NORTHEAST_MOUNTAINS,
    WFO_OFFICES,
)
from app.ml.ensemble import SnowEnsembleModel
from app.ml.features import (
    adjust_temp_for_elevation,
    classify_precip_type,
    estimate_slr,
    lead_bucket_for_hours,
)
from app.models import (
    DailyForecastPoint,
    ElevationSummary,
    HourlyForecastPoint,
    MeteorologistDiscussion,
    ModelWeightRatio,
    MountainForecastResponse,
    MountainSummary,
)
from app.services.afd_parser import build_discussion_model, build_offline_fallback_afd
from app.storage import ForecastStorage


def _build_offline_bundle(mountain: MountainConfig, elevation_ft: int) -> OpenMeteoBundle:
    """Deterministic fallback forecast bundle when upstream APIs are unreachable."""
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    times = [now + timedelta(hours=h) for h in range(168)]
    elev_factor = (elevation_ft - 1200) / 3000.0
    lat_offset = (mountain.latitude - 43.0) * 1.4

    # Deterministic storm wave around hours 12..34 and 78..108
    models: Dict[str, List[RawModelHour]] = {s: [] for s in ("hrrr", "nam", "ecmwf", "gfs", "gem")}
    source_offsets = {
        "hrrr": (0.0, 1.08),
        "nam": (-0.6, 1.02),
        "ecmwf": (0.4, 0.96),
        "gfs": (1.2, 0.92),
        "gem": (-0.9, 1.05),
    }

    for h, dt in enumerate(times):
        diurnal = 4.5 * math.sin(2.0 * math.pi * ((dt.hour - 13) / 24.0))
        wave1 = math.exp(-((h - 22) ** 2) / (2.0 * 7.5**2))
        wave2 = 0.85 * math.exp(-((h - 92) ** 2) / (2.0 * 11.0**2))
        base_temp = 25.0 - 6.8 * elev_factor - lat_offset + diurnal - 3.0 * wave1
        base_precip = (0.085 * wave1 + 0.065 * wave2) * mountain.orographic_factor
        if base_precip < 0.008:
            base_precip = 0.0
        wind = 12.0 + 10.0 * elev_factor + 14.0 * max(wave1, wave2)

        for src, (t_bias, s_mult) in source_offsets.items():
            if src == "hrrr" and h > 48:
                models[src].append(RawModelHour())
                continue
            if src == "nam" and h > 84:
                models[src].append(RawModelHour())
                continue
            temp_f = round(base_temp + t_bias + 0.4 * math.sin(h * 0.25), 1)
            slr = estimate_slr(temp_f, wind)
            snow_in = round(base_precip * slr * s_mult, 3) if temp_f <= 34.5 else 0.0
            fl_ft = max(0.0, elevation_ft + ((temp_f - 32.0) / 3.5) * 1000.0)
            models[src].append(
                RawModelHour(
                    temp_f=temp_f,
                    precip_in=round(base_precip, 3),
                    snowfall_in=snow_in,
                    wind_mph=round(wind, 1),
                    wind_gust_mph=round(wind * 1.45, 1),
                    freezing_level_ft=round(fl_ft),
                    precip_prob_pct=min(95.0, round(base_precip * 950.0)) if base_precip > 0 else 10.0,
                )
            )

    return OpenMeteoBundle(
        times=times,
        models=models,
        grid_elevation_ft=elevation_ft,
        is_live=False,
    )


def _confidence_label(hourly: List[HourlyForecastPoint]) -> str:
    if not hourly:
        return "Moderate"
    snow_hours = [h for h in hourly[:72] if h.snow_in >= 0.05]
    if not snow_hours:
        return "High"
    spreads = []
    for h in snow_hours:
        vals = list(h.source_snow_in.values())
        if len(vals) >= 2:
            mean = sum(vals) / len(vals)
            std = math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals))
            spreads.append(std / max(0.1, mean))
    if not spreads:
        return "Moderate"
    avg_cv = sum(spreads) / len(spreads)
    if avg_cv < 0.35:
        return "High"
    if avg_cv < 0.65:
        return "Moderate"
    return "Low"


def _summary_headline(snow_24h: float, snow_72h: float, snow_5d: float, temp_f: float, wind_mph: float) -> str:
    if snow_24h >= 6.0:
        return f"Powder Alert: {snow_24h:.1f}\" expected in 24h"
    if snow_72h >= 6.0:
        return f"Storm cycle: {snow_72h:.1f}\" over the next 72h"
    if snow_5d >= 4.0:
        return f"Accumulating snow: {snow_5d:.1f}\" next 5 days"
    if wind_mph >= 38.0:
        return f"Windy summit ({wind_mph:.0f} mph) · Watch upper lifts"
    if temp_f <= 30.0 and snow_72h >= 1.0:
        return f"Light snow showers ({snow_72h:.1f}\" / 72h) & cold"
    if temp_f > 35.0:
        return f"Mild temps ({temp_f:.0f}°F) · Soft spring/mixed conditions"
    return "Cold & dry snow-preservation pattern"


class ForecastService:
    """Coordinates weather ingestion, ML ensemble blending, and NWS meteorologist discussions."""

    def __init__(
        self,
        open_meteo: OpenMeteoClient,
        nws: NWSClient,
        ensemble: SnowEnsembleModel,
        storage: ForecastStorage,
    ) -> None:
        self.open_meteo = open_meteo
        self.nws = nws
        self.ensemble = ensemble
        self.storage = storage
        self._forecast_cache: Dict[Tuple[str, str], Tuple[datetime, MountainForecastResponse]] = {}
        self._afd_cache: Dict[str, Tuple[datetime, MeteorologistDiscussion]] = {}
        self._cache_ttl = timedelta(minutes=15)

    async def get_discussion(self, wfo_id: str) -> MeteorologistDiscussion:
        wfo_upper = wfo_id.upper()
        now = datetime.now(timezone.utc)
        cached = self._afd_cache.get(wfo_upper)
        if cached and (now - cached[0]) < self._cache_ttl:
            return cached[1]

        product = await self.nws.fetch_latest_afd(wfo_upper)
        if product is not None:
            self.storage.save_afd(
                wfo_id=product.wfo_id,
                product_id=product.product_id,
                issued_at=product.issued_at,
                forecaster=product.forecaster,
                raw_text=product.raw_text,
            )
            discussion = build_discussion_model(product, is_live=True)
            self._afd_cache[wfo_upper] = (now, discussion)
            return discussion

        # Check SQLite cache before falling back to sample offline discussion
        db_row = self.storage.get_cached_afd(wfo_upper)
        if db_row:
            from app.clients.nws import NWSAFDProduct

            product = NWSAFDProduct(
                wfo_id=db_row["wfo_id"],
                product_id=db_row["product_id"],
                issued_at=datetime.fromisoformat(db_row["issued_at"]),
                raw_text=db_row["raw_text"],
                forecaster=db_row["forecaster"],
            )
            discussion = build_discussion_model(product, is_live=False)
            self._afd_cache[wfo_upper] = (now, discussion)
            return discussion

        fallback = build_offline_fallback_afd(wfo_upper)
        self._afd_cache[wfo_upper] = (now, fallback)
        return fallback

    async def get_all_discussions(self) -> List[MeteorologistDiscussion]:
        tasks = [self.get_discussion(wfo_id) for wfo_id in WFO_OFFICES.keys()]
        results = await asyncio.gather(*tasks)
        return sorted(results, key=lambda d: d.issued_at, reverse=True)

    async def get_mountain_forecast(
        self,
        mountain_id: str,
        elevation_band: str = "summit",
    ) -> MountainForecastResponse:
        if mountain_id not in MOUNTAINS_BY_ID:
            raise KeyError(f"Unknown mountain: {mountain_id}")
        if elevation_band not in {"base", "mid", "summit"}:
            raise ValueError(f"Invalid elevation_band: {elevation_band}")

        now = datetime.now(timezone.utc)
        cache_key = (mountain_id, elevation_band)
        cached = self._forecast_cache.get(cache_key)
        if cached and (now - cached[0]) < self._cache_ttl:
            return cached[1]

        mountain = MOUNTAINS_BY_ID[mountain_id]
        elevation_ft = mountain.elevations.for_band(elevation_band)

        om_bundle, nws_grid, discussion = await asyncio.gather(
            self.open_meteo.fetch_multi_model_forecast(mountain, elevation_ft, forecast_days=7),
            self.nws.fetch_hourly_forecast(mountain),
            self.get_discussion(mountain.nws_wfo),
        )

        is_live = True
        if om_bundle is None:
            om_bundle = _build_offline_bundle(mountain, elevation_ft)
            is_live = False

        # Align NWS hourly periods onto UTC hour timestamps
        nws_by_hour: Dict[datetime, RawModelHour] = {}
        nws_elev_ft = nws_grid.grid_elevation_ft if nws_grid else None
        if nws_grid:
            for t, h in zip(nws_grid.times, nws_grid.hours):
                hour_key = t.replace(minute=0, second=0, microsecond=0)
                adj_temp = adjust_temp_for_elevation(h.temp_f, nws_elev_ft, elevation_ft)
                nws_by_hour[hour_key] = RawModelHour(
                    temp_f=adj_temp,
                    precip_in=h.precip_in,
                    snowfall_in=h.snowfall_in,
                    wind_mph=h.wind_mph,
                    wind_gust_mph=h.wind_gust_mph,
                    freezing_level_ft=h.freezing_level_ft,
                    precip_prob_pct=h.precip_prob_pct,
                )

        # Build hourly blended predictions starting from the current UTC hour
        start_hour = now.replace(minute=0, second=0, microsecond=0)
        hourly_points: List[HourlyForecastPoint] = []
        snapshot_rows: List[dict] = []
        sources_present = set()

        for idx, valid_time in enumerate(om_bundle.times):
            if valid_time < start_hour - timedelta(hours=1):
                continue
            lead_hours = max(0, int((valid_time - start_hour).total_seconds() // 3600))
            if lead_hours >= 168:
                break
            lead_bucket = lead_bucket_for_hours(lead_hours)

            source_snow: Dict[str, Optional[float]] = {}
            source_temp: Dict[str, Optional[float]] = {}
            winds: List[float] = []
            gusts: List[float] = []
            precips: List[float] = []
            fls: List[float] = []
            pops: List[float] = []

            for src, series in om_bundle.models.items():
                if idx >= len(series):
                    continue
                item = series[idx]
                if item.temp_f is not None:
                    adj_t = adjust_temp_for_elevation(
                        item.temp_f, om_bundle.grid_elevation_ft, elevation_ft
                    )
                    source_temp[src] = round(adj_t, 1) if adj_t is not None else None
                    sources_present.add(src)
                if item.snowfall_in is not None:
                    source_snow[src] = round(max(0.0, item.snowfall_in), 3)
                    sources_present.add(src)
                elif item.precip_in is not None and source_temp.get(src) is not None:
                    slr_est = estimate_slr(source_temp[src] or 26.0, item.wind_mph or 10.0)
                    source_snow[src] = round(item.precip_in * slr_est, 3)

                if item.wind_mph is not None:
                    winds.append(item.wind_mph)
                if item.wind_gust_mph is not None:
                    gusts.append(item.wind_gust_mph)
                if item.precip_in is not None:
                    precips.append(item.precip_in)
                if item.freezing_level_ft is not None:
                    fls.append(item.freezing_level_ft)
                if item.precip_prob_pct is not None:
                    pops.append(item.precip_prob_pct)

            # Merge NWS hour if present
            hour_key = valid_time.replace(minute=0, second=0, microsecond=0)
            nws_item = nws_by_hour.get(hour_key)
            if nws_item:
                if nws_item.temp_f is not None:
                    source_temp["nws"] = round(nws_item.temp_f, 1)
                    sources_present.add("nws")
                if nws_item.snowfall_in is not None:
                    source_snow["nws"] = round(nws_item.snowfall_in, 3)
                if nws_item.wind_mph is not None:
                    winds.append(nws_item.wind_mph)
                if nws_item.precip_prob_pct is not None:
                    pops.append(nws_item.precip_prob_pct)

            wind_mph = round(sum(winds) / len(winds), 1) if winds else 12.0
            wind_gust_mph = (
                round(max(gusts), 1)
                if gusts
                else round(wind_mph * 1.4, 1)
            )

            blended = self.ensemble.predict_hour(
                mountain_id=mountain.id,
                elevation_band=elevation_band,
                elevation_ft=elevation_ft,
                orographic_factor=mountain.orographic_factor,
                lead_hours=lead_hours,
                lead_bucket=lead_bucket,
                valid_time=valid_time,
                wind_mph=wind_mph,
                source_snow=source_snow,
                source_temp=source_temp,
            )

            slr = estimate_slr(blended.temp_f, wind_mph)
            liquid_in = (
                round(sum(precips) / len(precips), 3)
                if precips
                else (round(blended.snow_in / slr, 3) if slr > 0 else 0.0)
            )
            freezing_level_ft = (
                int(round(sum(fls) / len(fls)))
                if fls
                else max(0, int(round(elevation_ft + ((blended.temp_f - 32.0) / 3.5) * 1000.0)))
            )
            precip_type = classify_precip_type(liquid_in, blended.snow_in, blended.temp_f)

            clean_source_snow = {k: round(v, 3) for k, v in source_snow.items() if v is not None}
            clean_source_temp = {k: round(v, 1) for k, v in source_temp.items() if v is not None}

            hourly_points.append(
                HourlyForecastPoint(
                    time=valid_time,
                    lead_hours=lead_hours,
                    lead_bucket=lead_bucket,
                    snow_in=blended.snow_in,
                    snow_p10_in=blended.snow_p10_in,
                    snow_p90_in=blended.snow_p90_in,
                    liquid_precip_in=liquid_in,
                    temp_f=blended.temp_f,
                    wind_mph=wind_mph,
                    wind_gust_mph=wind_gust_mph,
                    freezing_level_ft=freezing_level_ft,
                    slr_ratio=slr,
                    precip_type=precip_type,
                    source_snow_in=clean_source_snow,
                    source_temp_f=clean_source_temp,
                )
            )

            snapshot_rows.append(
                {
                    "valid_time": valid_time,
                    "lead_hours": lead_hours,
                    "source_snow": source_snow,
                    "source_temp": source_temp,
                    "wind_mph": wind_mph,
                }
            )

        if is_live and snapshot_rows:
            self.storage.save_forecast_snapshots(
                mountain_id=mountain.id,
                elevation_band=elevation_band,
                elevation_ft=elevation_ft,
                issued_at=now,
                rows=snapshot_rows[:72],
            )

        snow_24h = round(sum(h.snow_in for h in hourly_points if h.lead_hours < 24), 1)
        snow_72h = round(sum(h.snow_in for h in hourly_points if h.lead_hours < 72), 1)
        snow_5d = round(sum(h.snow_in for h in hourly_points if h.lead_hours < 120), 1)

        # Daily rollups (grouped by local Eastern date approx UTC-5)
        eastern = timezone(timedelta(hours=-5))
        by_date: Dict[str, List[HourlyForecastPoint]] = defaultdict(list)
        for h in hourly_points:
            d_str = h.time.astimezone(eastern).date().isoformat()
            by_date[d_str].append(h)

        daily_points: List[DailyForecastPoint] = []
        for date_str in sorted(by_date.keys())[:7]:
            pts = by_date[date_str]
            d_snow = round(sum(p.snow_in for p in pts), 1)
            d_p10 = round(sum(p.snow_p10_in for p in pts), 1)
            d_p90 = round(sum(p.snow_p90_in for p in pts), 1)
            d_liq = round(sum(p.liquid_precip_in for p in pts), 2)
            temps = [p.temp_f for p in pts]
            winds = [p.wind_mph for p in pts]
            gusts = [p.wind_gust_mph for p in pts]
            slrs = [p.slr_ratio for p in pts if p.slr_ratio > 0]
            avg_slr = round(sum(slrs) / len(slrs), 1) if slrs else 0.0

            src_daily: Dict[str, float] = {}
            for src in MODEL_SOURCES:
                vals = [p.source_snow_in[src] for p in pts if src in p.source_snow_in]
                if vals:
                    src_daily[src] = round(sum(vals), 1)

            has_mix = any(p.precip_type == "Mix" for p in pts)
            has_rain = any(p.precip_type == "Rain" for p in pts)
            if d_snow >= 4.0:
                condition = "Heavy Snow" if d_snow >= 8.0 else "Snow"
            elif d_snow >= 0.5:
                condition = "Snow Showers" if not has_mix else "Wintry Mix"
            elif has_rain and d_liq >= 0.1:
                condition = "Rain"
            elif max(winds) >= 35.0:
                condition = "Windy"
            else:
                condition = "Cold & Dry" if max(temps) <= 32.0 else "Partly Cloudy"

            precip_prob = min(
                95,
                max(
                    10,
                    int(round((sum(1 for p in pts if p.liquid_precip_in >= 0.01 or p.snow_in >= 0.05) / max(1, len(pts))) * 140)),
                ),
            )

            daily_points.append(
                DailyForecastPoint(
                    date=date_str,
                    snow_in=d_snow,
                    snow_p10_in=min(d_snow, d_p10),
                    snow_p90_in=max(d_snow, d_p90),
                    liquid_precip_in=d_liq,
                    slr_ratio=avg_slr,
                    temp_high_f=round(max(temps), 1),
                    temp_low_f=round(min(temps), 1),
                    wind_max_mph=round(max(winds), 1),
                    wind_gust_mph=round(max(gusts), 1),
                    precip_prob_pct=precip_prob,
                    condition=condition,
                    source_snow_in=src_daily,
                )
            )

        # Build per-lead-bucket ML model weight breakdown with each model's snow/temp summary
        lead_bucket_weights: Dict[str, List[ModelWeightRatio]] = {}
        for bucket_name in LEAD_BUCKETS:
            w_map = self.ensemble.get_weights_for_bucket(mountain.id, elevation_band, bucket_name)
            ratios: List[ModelWeightRatio] = []
            for src in MODEL_SOURCES:
                s24 = [h.source_snow_in[src] for h in hourly_points if h.lead_hours < 24 and src in h.source_snow_in]
                s72 = [h.source_snow_in[src] for h in hourly_points if h.lead_hours < 72 and src in h.source_snow_in]
                s5d = [h.source_snow_in[src] for h in hourly_points if h.lead_hours < 120 and src in h.source_snow_in]
                t72 = [h.source_temp_f[src] for h in hourly_points if h.lead_hours < 72 and src in h.source_temp_f]
                ratios.append(
                    ModelWeightRatio(
                        source=src,
                        display_name=MODEL_DISPLAY_NAMES.get(src, src.upper()),
                        weight=round(w_map.get(src, 0.0), 4),
                        snow_24h_in=round(sum(s24), 1) if s24 else None,
                        snow_72h_in=round(sum(s72), 1) if s72 else None,
                        snow_5d_in=round(sum(s5d), 1) if s5d else None,
                        avg_temp_f=round(sum(t72) / len(t72), 1) if t72 else None,
                    )
                )
            ratios.sort(key=lambda r: r.weight, reverse=True)
            lead_bucket_weights[bucket_name] = ratios

        curr_temp = hourly_points[0].temp_f if hourly_points else 24.0
        curr_wind = hourly_points[0].wind_mph if hourly_points else 12.0
        confidence = _confidence_label(hourly_points)

        summary = MountainSummary(
            id=mountain.id,
            name=mountain.name,
            state=mountain.state,
            region=mountain.region,
            latitude=mountain.latitude,
            longitude=mountain.longitude,
            elevations=ElevationSummary(
                base_ft=mountain.elevations.base_ft,
                mid_ft=mountain.elevations.mid_ft,
                summit_ft=mountain.elevations.summit_ft,
            ),
            nws_wfo=mountain.nws_wfo,
            station_id=mountain.station_id,
            aspect=mountain.aspect,
            snow_24h_in=snow_24h,
            snow_72h_in=snow_72h,
            snow_5d_in=snow_5d,
            summit_temp_f=curr_temp,
            summit_wind_mph=curr_wind,
            confidence=confidence,
            headline=_summary_headline(snow_24h, snow_72h, snow_5d, curr_temp, curr_wind),
            updated_at=now,
        )

        response = MountainForecastResponse(
            mountain=summary,
            elevation_band=elevation_band,
            elevation_ft=elevation_ft,
            lead_bucket_weights=lead_bucket_weights,
            daily=daily_points,
            hourly=hourly_points,
            discussion=discussion,
            data_sources_used=sorted(sources_present),
            is_live_weather=is_live,
            ml_model_version=self.ensemble.artifact.version,
        )
        self._forecast_cache[cache_key] = (now, response)
        return response

    async def get_all_mountain_summaries(
        self, state: Optional[str] = None
    ) -> List[MountainSummary]:
        targets = [
            m
            for m in NORTHEAST_MOUNTAINS
            if state is None or m.state.upper() == state.upper()
        ]
        # Fetch in bounded concurrency so we don't overwhelm Open-Meteo/NWS
        sem = asyncio.Semaphore(6)

        async def _load(m: MountainConfig) -> MountainSummary:
            async with sem:
                fc = await self.get_mountain_forecast(m.id, elevation_band="summit")
                return fc.mountain

        summaries = await asyncio.gather(*(_load(m) for m in targets))
        return sorted(summaries, key=lambda s: (s.snow_5d_in, s.snow_72h_in), reverse=True)
