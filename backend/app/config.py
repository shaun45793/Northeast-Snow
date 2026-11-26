from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List


BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
DB_PATH = DATA_DIR / "snowforecast.db"
MODEL_DIR = DATA_DIR / "models"


@dataclass(frozen=True)
class ElevationBands:
    base_ft: int
    mid_ft: int
    summit_ft: int

    def for_band(self, band: str) -> int:
        mapping = {
            "base": self.base_ft,
            "mid": self.mid_ft,
            "summit": self.summit_ft,
        }
        if band not in mapping:
            raise ValueError(f"Unknown elevation band: {band}")
        return mapping[band]


@dataclass(frozen=True)
class MountainConfig:
    id: str
    name: str
    state: str
    region: str
    latitude: float
    longitude: float
    elevations: ElevationBands
    nws_wfo: str
    station_id: str
    aspect: str  # Primary windward snow aspect, e.g. NW, WNW, NE
    orographic_factor: float  # Typical upslope enhancement multiplier (1.0 = neutral)


@dataclass(frozen=True)
class WFOConfig:
    id: str
    name: str
    city_state: str
    coverage_summary: str


WFO_OFFICES: Dict[str, WFOConfig] = {
    "BTV": WFOConfig(
        id="BTV",
        name="NWS Burlington, VT",
        city_state="Burlington, VT",
        coverage_summary="Northern & Central Vermont, Adirondacks / Champlain Valley",
    ),
    "GYX": WFOConfig(
        id="GYX",
        name="NWS Gray / Portland, ME",
        city_state="Gray, ME",
        coverage_summary="White Mountains (NH) & Western Maine Mountains",
    ),
    "ALY": WFOConfig(
        id="ALY",
        name="NWS Albany, NY",
        city_state="Albany, NY",
        coverage_summary="Southern Green Mountains (VT), Catskills, Southern Adirondacks & Berkshires",
    ),
    "BOX": WFOConfig(
        id="BOX",
        name="NWS Boston / Norton, MA",
        city_state="Norton, MA",
        coverage_summary="Central & Western Massachusetts",
    ),
    "CAR": WFOConfig(
        id="CAR",
        name="NWS Caribou, ME",
        city_state="Caribou, ME",
        coverage_summary="Northern Maine & Aroostook County",
    ),
}


NORTHEAST_MOUNTAINS: List[MountainConfig] = [
    MountainConfig(
        id="stowe",
        name="Stowe Mountain Resort",
        state="VT",
        region="Northern Green Mountains",
        latitude=44.5303,
        longitude=-72.7814,
        elevations=ElevationBands(base_ft=1559, mid_ft=2600, summit_ft=3625),
        nws_wfo="BTV",
        station_id="KMVL",
        aspect="NW",
        orographic_factor=1.18,
    ),
    MountainConfig(
        id="jay-peak",
        name="Jay Peak",
        state="VT",
        region="Northern Green Mountains",
        latitude=44.9379,
        longitude=-72.5045,
        elevations=ElevationBands(base_ft=1815, mid_ft=2800, summit_ft=3968),
        nws_wfo="BTV",
        station_id="KEFK",
        aspect="NW",
        orographic_factor=1.28,
    ),
    MountainConfig(
        id="sugarbush",
        name="Sugarbush",
        state="VT",
        region="Central Green Mountains",
        latitude=44.1359,
        longitude=-72.8944,
        elevations=ElevationBands(base_ft=1483, mid_ft=2700, summit_ft=4083),
        nws_wfo="BTV",
        station_id="KMPV",
        aspect="WNW",
        orographic_factor=1.15,
    ),
    MountainConfig(
        id="mad-river-glen",
        name="Mad River Glen",
        state="VT",
        region="Central Green Mountains",
        latitude=44.2025,
        longitude=-72.9175,
        elevations=ElevationBands(base_ft=1600, mid_ft=2600, summit_ft=3637),
        nws_wfo="BTV",
        station_id="KMPV",
        aspect="NE",
        orographic_factor=1.16,
    ),
    MountainConfig(
        id="killington",
        name="Killington",
        state="VT",
        region="Central Green Mountains",
        latitude=43.6045,
        longitude=-72.8201,
        elevations=ElevationBands(base_ft=1165, mid_ft=2700, summit_ft=4241),
        nws_wfo="BTV",
        station_id="KRUT",
        aspect="NNE",
        orographic_factor=1.14,
    ),
    MountainConfig(
        id="stratton",
        name="Stratton Mountain",
        state="VT",
        region="Southern Green Mountains",
        latitude=43.1134,
        longitude=-72.9081,
        elevations=ElevationBands(base_ft=1872, mid_ft=2850, summit_ft=3875),
        nws_wfo="ALY",
        station_id="KDDH",
        aspect="NNE",
        orographic_factor=1.08,
    ),
    MountainConfig(
        id="mount-snow",
        name="Mount Snow",
        state="VT",
        region="Southern Green Mountains",
        latitude=42.9602,
        longitude=-72.9204,
        elevations=ElevationBands(base_ft=1900, mid_ft=2750, summit_ft=3600),
        nws_wfo="ALY",
        station_id="KDDH",
        aspect="NE",
        orographic_factor=1.07,
    ),
    MountainConfig(
        id="wildcat",
        name="Wildcat Mountain",
        state="NH",
        region="White Mountains",
        latitude=44.2636,
        longitude=-71.2392,
        elevations=ElevationBands(base_ft=1950, mid_ft=3000, summit_ft=4062),
        nws_wfo="GYX",
        station_id="KMWN",
        aspect="NW",
        orographic_factor=1.22,
    ),
    MountainConfig(
        id="cannon",
        name="Cannon Mountain",
        state="NH",
        region="White Mountains",
        latitude=44.1566,
        longitude=-71.6987,
        elevations=ElevationBands(base_ft=2000, mid_ft=3050, summit_ft=4080),
        nws_wfo="GYX",
        station_id="KHIE",
        aspect="NNW",
        orographic_factor=1.18,
    ),
    MountainConfig(
        id="loon",
        name="Loon Mountain",
        state="NH",
        region="White Mountains",
        latitude=44.0369,
        longitude=-71.6214,
        elevations=ElevationBands(base_ft=950, mid_ft=2000, summit_ft=3050),
        nws_wfo="GYX",
        station_id="KHIE",
        aspect="N",
        orographic_factor=1.08,
    ),
    MountainConfig(
        id="bretton-woods",
        name="Bretton Woods",
        state="NH",
        region="White Mountains",
        latitude=44.2597,
        longitude=-71.4622,
        elevations=ElevationBands(base_ft=1600, mid_ft=2350, summit_ft=3100),
        nws_wfo="GYX",
        station_id="KMWN",
        aspect="NW",
        orographic_factor=1.15,
    ),
    MountainConfig(
        id="sugarloaf",
        name="Sugarloaf",
        state="ME",
        region="Western Maine Mountains",
        latitude=45.0314,
        longitude=-70.3131,
        elevations=ElevationBands(base_ft=1417, mid_ft=2800, summit_ft=4237),
        nws_wfo="GYX",
        station_id="KBML",
        aspect="NNE",
        orographic_factor=1.18,
    ),
    MountainConfig(
        id="sunday-river",
        name="Sunday River",
        state="ME",
        region="Western Maine Mountains",
        latitude=44.4734,
        longitude=-70.8569,
        elevations=ElevationBands(base_ft=800, mid_ft=1950, summit_ft=3140),
        nws_wfo="GYX",
        station_id="KBML",
        aspect="NNE",
        orographic_factor=1.08,
    ),
    MountainConfig(
        id="saddleback",
        name="Saddleback",
        state="ME",
        region="Western Maine Mountains",
        latitude=44.9367,
        longitude=-70.5031,
        elevations=ElevationBands(base_ft=2120, mid_ft=3100, summit_ft=4120),
        nws_wfo="GYX",
        station_id="KBML",
        aspect="NW",
        orographic_factor=1.20,
    ),
    MountainConfig(
        id="whiteface",
        name="Whiteface Mountain",
        state="NY",
        region="Adirondacks",
        latitude=44.3659,
        longitude=-73.9026,
        elevations=ElevationBands(base_ft=1220, mid_ft=2800, summit_ft=4650),
        nws_wfo="BTV",
        station_id="KSLK",
        aspect="ENE",
        orographic_factor=1.14,
    ),
    MountainConfig(
        id="gore",
        name="Gore Mountain",
        state="NY",
        region="Adirondacks",
        latitude=43.6725,
        longitude=-74.0067,
        elevations=ElevationBands(base_ft=1500, mid_ft=2550, summit_ft=3600),
        nws_wfo="ALY",
        station_id="KGFL",
        aspect="N",
        orographic_factor=1.06,
    ),
    MountainConfig(
        id="hunter",
        name="Hunter Mountain",
        state="NY",
        region="Catskills",
        latitude=42.2028,
        longitude=-74.2248,
        elevations=ElevationBands(base_ft=1600, mid_ft=2400, summit_ft=3200),
        nws_wfo="ALY",
        station_id="KALB",
        aspect="N",
        orographic_factor=1.05,
    ),
    MountainConfig(
        id="wachusett",
        name="Wachusett Mountain",
        state="MA",
        region="Central Massachusetts",
        latitude=42.4997,
        longitude=-71.8867,
        elevations=ElevationBands(base_ft=1006, mid_ft=1500, summit_ft=2006),
        nws_wfo="BOX",
        station_id="KORH",
        aspect="N",
        orographic_factor=1.02,
    ),
]

MOUNTAINS_BY_ID: Dict[str, MountainConfig] = {m.id: m for m in NORTHEAST_MOUNTAINS}

# Weather source keys used consistently across ingestion, ML training, and API responses.
MODEL_SOURCES: List[str] = [
    "hrrr",
    "nam",
    "ecmwf",
    "gfs",
    "gem",
    "nws",
]

MODEL_DISPLAY_NAMES: Dict[str, str] = {
    "hrrr": "HRRR 3km",
    "nam": "NAM 3km/12km",
    "ecmwf": "ECMWF IFS",
    "gfs": "NOAA GFS",
    "gem": "CMC GEM",
    "nws": "NWS Blend",
}

# Open-Meteo model identifiers requested from https://api.open-meteo.com/v1/forecast
OPEN_METEO_MODEL_MAP: Dict[str, str] = {
    "hrrr": "ncep_hrrr_conus",
    "nam": "ncep_nam_conus",
    "ecmwf": "ecmwf_ifs025",
    "gfs": "gfs_seamless",
    "gem": "gem_seamless",
}

ELEVATION_BANDS: List[str] = ["base", "mid", "summit"]
LEAD_BUCKETS: List[str] = ["short_0_24h", "medium_24_72h", "extended_72_168h"]
