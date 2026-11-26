#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/SnowForecast.xcodeproj"
DERIVED_DATA="/tmp/SnowForecastIPABuild"
STAGE_DIR="/tmp/SnowForecastIPAStage"
OUT_DIR="$SCRIPT_DIR/build"
OUT_IPA="$OUT_DIR/SnowForecast-v4.ipa"

rm -rf "$DERIVED_DATA" "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Payload" "$OUT_DIR"

echo "Building SnowForecast (Release, arm64 iOS)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme SnowForecast \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/SnowForecast.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: SnowForecast.app not found at $APP_PATH" >&2
  exit 1
fi

cp -R "$APP_PATH" "$STAGE_DIR/Payload/SnowForecast.app"
# Strip any leftover _CodeSignature if present so AltStore resigns cleanly
rm -rf "$STAGE_DIR/Payload/SnowForecast.app/_CodeSignature" \
       "$STAGE_DIR/Payload/SnowForecast.app/PlugIns/SnowForecastWidget.appex/_CodeSignature"

(
  cd "$STAGE_DIR"
  /usr/bin/zip -qry "$OUT_IPA" Payload
)

echo "Created IPA: $OUT_IPA"
ls -lh "$OUT_IPA"
