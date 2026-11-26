# Northeast Snow Forecast (iPhone + ML Weather Backend)

An OpenSnow-inspired iPhone app and machine-learning weather ensemble backend tailored to **Northeast ski mountains** (VT, NH, ME, NY, MA) and **local NWS meteorologist discussions**.

## Architecture

### 1. Python FastAPI & ML Backend (`backend/`)
- **Multi-Source Weather Ingestion**:
  - **Open-Meteo Multi-Model**: Pulls hourly forecasts from `ncep_hrrr_conus` (HRRR 3km), `ncep_nam_conus` (NAM), `ecmwf_ifs025` (ECMWF IFS), `gfs_seamless` (GFS), and `gem_seamless` (CMC GEM).
  - **NOAA / NWS (`api.weather.gov`)**: Pulls NWS hourly point forecasts, ASOS/observatory station observations (`KMVL`, `KEFK`, `KMWN`, `KBML`, etc.), and **Area Forecast Discussions (AFD)** from `BTV`, `GYX`, `ALY`, `BOX`, and `CAR`.
- **Trainable ML Ensemble (`backend/app/ml/`)**:
  - **Per-mountain, elevation-band (`base`/`mid`/`summit`), and lead-time bucket (`0–24h`, `24–72h`, `3–7d`)** models.
  - **Stage 1 — Non-negative Ridge (`positive=True`)**: Learns normalized percentage weights across `[HRRR, NAM, ECMWF, GFS, GEM, NWS]` so the iPhone app displays exact ML-learned model ratios.
  - **Stage 2 — `HistGradientBoostingRegressor` Residual Corrector**: Learns nonlinear Northeast orographic lift, elevation, and ensemble-spread adjustments plus `P10`–`P90` snowfall uncertainty intervals.
- **Local Meteorologist Parser (`backend/app/services/afd_parser.py`)**:
  - Reflows NWS Area Forecast Discussions for mobile reading and extracts categorized mountain highlights (`Snow & Upslope`, `Temp & Freezing Level`, `Wind & Hold Risk`, `Confidence & Models`).

### 2. iPhone SwiftUI App (`ios/`)
- **`ios/Packages/SnowForecastKit`**: Pure Swift package with strongly typed Codable models, ISO8601 API client, unit formatters, and offline preview fixtures.
- **`ios/SnowForecastApp`**: iPhone-only (`TARGETED_DEVICE_FAMILY = 1`, iOS 17+) SwiftUI app with 4 tabs:
  - **Mountains**: State filters (`VT`, `NH`, `ME`, `NY`, `MA`), favorites, Top 5-Day Powder Watch, and mountain cards.
  - **Mountain Detail**: Base / Mid / Summit elevation selector, 7-day snow bars with `P10–P90` ranges, hourly timeline with freezing level, interactive **ML Forecast Ratios** card, and embedded local meteorologist take.
  - **Local Meteorologists**: Live NWS Area Forecast Discussions by forecast office (`BTV`, `GYX`, `ALY`, `BOX`, `CAR`).
  - **ML Lab**: Inspection of learned model ratios, MAE verification metrics, and one-tap observation ingestion & retraining.

## Running Locally

### Start the Backend
```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### Run Backend Tests
```bash
cd backend
.venv/bin/pytest
```

### Run Swift Package Tests
```bash
swift test --package-path ios/Packages/SnowForecastKit
```

### Open the iPhone App in Xcode
1. Install Xcode from the Mac App Store (only Xcode Command Line Tools are currently installed on this machine).
2. Open `ios/SnowForecast.xcodeproj` in Xcode.
3. Select an iPhone simulator (or your physical iPhone) and press **Run**.
   - On Simulator, the default backend URL `http://127.0.0.1:8000` connects directly to your local FastAPI server.
   - If the backend isn't running, the app automatically falls back to built-in Northeast demo forecasts so you can still preview the UI.
