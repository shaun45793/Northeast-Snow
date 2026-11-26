import XCTest
@testable import SnowForecastKit

final class SnowForecastKitTests: XCTestCase {
    func testDecodesBackendForecastJSON() throws {
        let json = """
        {
          "mountain": {
            "id": "stowe",
            "name": "Stowe Mountain Resort",
            "state": "VT",
            "region": "Northern Green Mountains",
            "latitude": 44.5303,
            "longitude": -72.7814,
            "elevations": { "base_ft": 1559, "mid_ft": 2600, "summit_ft": 3625 },
            "nws_wfo": "BTV",
            "station_id": "KMVL",
            "aspect": "NW",
            "snow_24h_in": 4.2,
            "snow_72h_in": 8.9,
            "snow_5d_in": 12.1,
            "summit_temp_f": 18.5,
            "summit_wind_mph": 22.0,
            "confidence": "High",
            "headline": "Storm cycle: 8.9\\" over the next 72h",
            "updated_at": "2026-11-25T01:53:00.123456+00:00"
          },
          "elevation_band": "summit",
          "elevation_ft": 3625,
          "lead_bucket_weights": {
            "short_0_24h": [
              { "source": "hrrr", "display_name": "HRRR 3km", "weight": 0.35, "snow_24h_in": 4.5, "snow_72h_in": 8.1, "snow_5d_in": null, "avg_temp_f": 18.0 }
            ]
          },
          "daily": [
            {
              "date": "2026-11-25",
              "snow_in": 4.2,
              "snow_p10_in": 3.0,
              "snow_p90_in": 5.6,
              "liquid_precip_in": 0.3,
              "slr_ratio": 14.0,
              "temp_high_f": 22.0,
              "temp_low_f": 14.0,
              "wind_max_mph": 25.0,
              "wind_gust_mph": 35.0,
              "precip_prob_pct": 85,
              "condition": "Snow",
              "source_snow_in": { "hrrr": 4.5, "ecmwf": 3.8 }
            }
          ],
          "hourly": [
            {
              "time": "2026-11-25T02:00:00Z",
              "lead_hours": 1,
              "lead_bucket": "short_0_24h",
              "snow_in": 0.4,
              "snow_p10_in": 0.25,
              "snow_p90_in": 0.55,
              "liquid_precip_in": 0.03,
              "temp_f": 18.5,
              "wind_mph": 22.0,
              "wind_gust_mph": 31.0,
              "freezing_level_ft": 1100,
              "slr_ratio": 14.5,
              "precip_type": "Snow",
              "source_snow_in": { "hrrr": 0.42 },
              "source_temp_f": { "hrrr": 18.5 }
            }
          ],
          "discussion": {
            "wfo_id": "BTV",
            "wfo_name": "NWS Burlington, VT",
            "issued_at": "2026-11-25T00:15:00Z",
            "forecaster": "SMITH",
            "product_id": "btv-001",
            "mountain_relevance_summary": "Upslope snow continues on the Green Mountains.",
            "highlights": [
              { "category": "Snow & Upslope", "summary": "4 to 8 inches at summit elevations." }
            ],
            "synopsis": "Upper trough crossing VT.",
            "short_term": "NW flow snow showers.",
            "long_term": "Dry mid-week.",
            "raw_text": "AFD",
            "covered_mountain_ids": ["stowe", "jay-peak"],
            "is_live": true
          },
          "data_sources_used": ["hrrr", "ecmwf", "nws"],
          "is_live_weather": true,
          "ml_model_version": "ml-stacker-v1"
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = SnowForecastAPIClient.makeDecoder()
        let decoded = try decoder.decode(MountainForecastResponse.self, from: data)

        XCTAssertEqual(decoded.mountain.id, "stowe")
        XCTAssertEqual(decoded.elevationFt, 3625)
        XCTAssertEqual(decoded.daily.first?.snowIn, 4.2)
        XCTAssertEqual(decoded.hourly.first?.precipType, "Snow")
        XCTAssertEqual(decoded.discussion?.wfoId, "BTV")
        XCTAssertEqual(decoded.leadBucketWeights["short_0_24h"]?.first?.weight, 0.35)
    }

    func testFormattingHelpers() {
        XCTAssertEqual(SnowFormatting.formatSnow(4.5, unit: .inches), "4.5\"")
        XCTAssertEqual(SnowFormatting.formatSnow(10.0, unit: .centimeters), "25 cm")
        XCTAssertEqual(SnowFormatting.formatTemp(32.0, unit: .fahrenheit), "32°F")
        XCTAssertEqual(SnowFormatting.formatTemp(32.0, unit: .celsius), "0°C")
        XCTAssertEqual(SnowFormatting.formatPercent(0.36), "36%")
    }

    func testMockDataIntegrity() {
        XCTAssertFalse(MockSnowData.sampleMountains.isEmpty)
        let first = MockSnowData.sampleMountains[0]
        let fc = MockSnowData.sampleForecast(for: first, band: .summit)
        XCTAssertEqual(fc.daily.count, 7)
        XCTAssertEqual(fc.hourly.count, 168)
        XCTAssertEqual(fc.elevationFt, first.elevations.summitFt)
    }

    func testOnDeviceMLEngineParityWithPython() throws {
        let engine = try OnDeviceMLEngine.loadBundled()
        XCTAssertEqual(engine.bundle.mountains.count, 18)
        XCTAssertGreaterThanOrEqual(engine.bundle.buckets.count, 171)

        let iso = ISO8601DateFormatter()
        let d1 = try XCTUnwrap(iso.date(from: "2026-02-10T15:00:00Z"))
        let p1 = engine.predictHour(
            mountainId: "stowe",
            elevationBand: "summit",
            elevationFt: 3625,
            orographicFactor: 1.18,
            leadHours: 12,
            leadBucket: "short_0_24h",
            validTime: d1,
            windMph: 24.0,
            sourceSnow: ["hrrr": 0.55, "nam": 0.48, "ecmwf": 0.40, "gfs": 0.35, "gem": 0.45, "nws": 0.42],
            sourceTemp: ["hrrr": 19.0, "nam": 18.5, "ecmwf": 20.0, "gfs": 21.5, "gem": 18.0, "nws": 19.5]
        )
        XCTAssertEqual(p1.snowIn, 0.449, accuracy: 0.002)
        XCTAssertEqual(p1.snowP10In, 0.354, accuracy: 0.002)
        XCTAssertEqual(p1.snowP90In, 0.545, accuracy: 0.002)
        XCTAssertEqual(p1.tempF, 20.1, accuracy: 0.1)

        let d2 = try XCTUnwrap(iso.date(from: "2026-02-14T15:00:00Z"))
        let p2 = engine.predictHour(
            mountainId: "jay-peak",
            elevationBand: "summit",
            elevationFt: 3968,
            orographicFactor: 1.28,
            leadHours: 96,
            leadBucket: "extended_72_168h",
            validTime: d2,
            windMph: 30.0,
            sourceSnow: ["ecmwf": 0.42, "gfs": 0.30, "gem": 0.38, "nws": 0.34],
            sourceTemp: ["ecmwf": 15.0, "gfs": 17.0, "gem": 14.0, "nws": 15.5]
        )
        XCTAssertEqual(p2.snowIn, 0.366, accuracy: 0.002)
        XCTAssertEqual(p2.snowP10In, 0.289, accuracy: 0.002)
        XCTAssertEqual(p2.snowP90In, 0.443, accuracy: 0.002)
        XCTAssertEqual(p2.tempF, 15.2, accuracy: 0.1)
        XCTAssertEqual(p2.activeSnowWeights["hrrr"], 0.0)

        let status = engine.trainingStatus(scope: "global")
        XCTAssertEqual(status.metrics.count, 9)
    }

    func testSwiftAFDParserExtractsHighlights() {
        let raw = """
        AREA FORECAST DISCUSSION
        NATIONAL WEATHER SERVICE BURLINGTON VT

        .SYNOPSIS...
        A deep upper trough brings arctic air and northwest upslope flow across the Green Mountains.

        .SHORT TERM...
        Expect 4 to 8 inches of upslope snow at Stowe and Jay Peak with 15:1 ratios above 2000 feet.
        Ridgetop wind gusts to 40 mph may cause localized lift holds.

        .LONG TERM...
        ECMWF and GEM ensemble spread remains low with high confidence for cold temps.
        &&
        $$
        SMITH
        """
        let wfo = ExportedWFO(id: "BTV", name: "NWS Burlington, VT", cityState: "Burlington, VT", coverageSummary: "VT")
        let disc = SwiftAFDParser.buildDiscussion(
            wfo: wfo,
            productId: "btv-test",
            issuedAt: Date(),
            rawText: raw,
            coveredMountainIds: ["stowe", "jay-peak"],
            isLive: true
        )
        XCTAssertEqual(disc.forecaster, "SMITH")
        let categories = Set(disc.highlights.map(\.category))
        XCTAssertTrue(categories.contains("Snow & Upslope"))
        XCTAssertTrue(categories.contains("Wind & Hold Risk"))
        XCTAssertTrue(categories.contains("Confidence & Models"))
        XCTAssertFalse(disc.plainEnglishTakeaways.isEmpty)
    }

    func testPhysicsWetBulbWarmNoseAndLiftHold() {
        let wb = OnDevicePhysics.computeWetBulbF(tempF: 33.0, rhPct: 45.0)
        XCTAssertLessThan(wb, 30.0)

        XCTAssertTrue(OnDevicePhysics.isWarmNose(surfaceTempF: 29.0, temp850F: 36.0))
        XCTAssertFalse(OnDevicePhysics.isWarmNose(surfaceTempF: 25.0, temp850F: 22.0))

        let slrWarmNose = OnDevicePhysics.estimateSLR(tempF: 28.0, windMph: 10.0, temp850F: 36.0)
        XCTAssertEqual(slrWarmNose, 2.5)

        let slrDGZ = OnDevicePhysics.estimateSLR(tempF: 18.0, windMph: 10.0, temp850F: 10.0)
        XCTAssertGreaterThan(slrDGZ, 17.0)

        XCTAssertEqual(
            OnDevicePhysics.computeLiftHoldRisk(windMph: 36.0, windGustMph: 52.0, elevationFt: 4062, windDirDeg: 310.0, aspect: "NW"),
            "High"
        )
        XCTAssertEqual(
            OnDevicePhysics.computeLiftHoldRisk(windMph: 12.0, windGustMph: 18.0, elevationFt: 2006),
            "Low"
        )
    }

    func testDiskCacheStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DiskCacheStore(baseDirectory: tempDir)
        let sample = MockSnowData.sampleMountains[0]
        let forecast = MockSnowData.sampleForecast(for: sample, band: .summit)

        store.saveMountainSummaries(MockSnowData.sampleMountains)
        store.saveForecast(forecast, mountainId: sample.id, band: .summit)

        let loadedSummaries = store.loadMountainSummaries()
        let loadedForecast = store.loadForecast(mountainId: sample.id, band: .summit)
        XCTAssertEqual(loadedSummaries?.count, MockSnowData.sampleMountains.count)
        XCTAssertEqual(loadedForecast?.mountain.id, sample.id)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testKillingtonMadRiverAndJayPeakSensorParsing() {
        let killingtonHTML = """
        <div class="dor-sensors-row">
            <div class="dor-sensor-item">
                <div class="dor-sensor-name">Killington Peak</div>
                <div class="dor-sensor-elevation">4,241 ft</div>
                <div class="dor-sensor-temp">15°</div>
            </div>
            <div class="dor-sensor-item is-primary">
                <div class="dor-sensor-name">K-1 Lodge</div>
                <div class="dor-sensor-elevation">2,500 ft</div>
                <div class="dor-sensor-temp">22°</div>
            </div>
            <div class="dor-sensor-item">
                <div class="dor-sensor-name">Bear Mountain</div>
                <div class="dor-sensor-elevation">3,262 ft</div>
                <div class="dor-sensor-temp">21°</div>
            </div>
        </div>
        <div class="dor-snow-grid">
            <a href="mountain-overview/" class="dor-snow-cell">
              <div class="dor-snow-label">24 Hour</div>
              <div class="dor-snow-icon"><i class="fa-duotone fa-light fa-snowflake"></i></div>
              <div class="dor-snow-val">3"</div>
            </a>
            <a href="mountain-overview/" class="dor-snow-cell">
              <div class="dor-snow-label">48 Hour</div>
              <div class="dor-snow-icon"><i class="fa-duotone fa-light fa-snowflake"></i></div>
              <div class="dor-snow-val">6"</div>
            </a>
            <a href="mountain-overview/" class="dor-snow-cell">
              <div class="dor-snow-label">7 Day</div>
              <div class="dor-snow-icon"><i class="fa-duotone fa-light fa-snowflake"></i></div>
              <div class="dor-snow-val">9"</div>
            </a>
            <a href="mountain-overview/" class="dor-snow-cell">
              <div class="dor-snow-label">Season</div>
              <div class="dor-snow-icon"><i class="fa-duotone fa-light fa-snowflake"></i></div>
              <div class="dor-snow-val">15"</div>
            </a>
        </div>
        """
        let kSensors = MountainStationClient.parseKillingtonSensors(html: killingtonHTML)
        XCTAssertEqual(kSensors.count, 3)
        XCTAssertFalse(kSensors.contains(where: { $0.sourceName.lowercased().contains("bear") }))
        XCTAssertEqual(kSensors.first(where: { $0.elevationBand == "summit" })?.tempF, 15.0)
        XCTAssertEqual(kSensors.first(where: { $0.elevationBand == "summit" })?.elevationFt, 4241)
        XCTAssertEqual(kSensors.first(where: { $0.elevationBand == "base" })?.tempF, 22.0)
        // Interpolated mid at 2700 ft between K-1 (2500 ft, 22F) and Peak (4241 ft, 15F) => ~21.2F
        XCTAssertEqual(kSensors.first(where: { $0.elevationBand == "mid" })?.tempF ?? 0, 21.2, accuracy: 0.1)

        let kReport = MountainStationClient.parseKillingtonSnowReport(html: killingtonHTML)
        XCTAssertEqual(kReport?.snow24hIn, 3.0)
        XCTAssertEqual(kReport?.snow48hIn, 6.0)
        XCTAssertEqual(kReport?.snow7dIn, 9.0)
        XCTAssertEqual(kReport?.seasonTotalIn, 15.0)

        let mrgHTML = """
        <td>Current Base Temp: <span> 54° F</span></td>
        <td>Current Summit Temp: <span>47° F</span></td>
        """
        let mrgSensors = MountainStationClient.parseMadRiverGlenSensors(html: mrgHTML)
        XCTAssertEqual(mrgSensors.count, 3)
        XCTAssertEqual(mrgSensors.first(where: { $0.elevationBand == "summit" })?.tempF, 47.0)
        XCTAssertEqual(mrgSensors.first(where: { $0.elevationBand == "base" })?.tempF, 54.0)
        XCTAssertNotNil(mrgSensors.first(where: { $0.elevationBand == "mid" }))

        let jayHTML = """
        <div class="SnowReport-measures SnowReport-measures--columns SnowReport-snowfall">
          <dl class="SnowReport-measure"><dt>Last 24 Hours</dt><dd>0 &quot;</dd></dl>
          <dl class="SnowReport-measure"><dt>Last 48 Hours</dt><dd>8 &quot;</dd></dl>
          <dl class="SnowReport-measure"><dt>Last 7 Days</dt><dd>8 &quot;</dd></dl>
          <dl class="SnowReport-measure"><dt>Season Total</dt><dd>8 &quot;</dd></dl>
        </div>
        """
        let jayReport = MountainStationClient.parseJayPeakSnowReport(html: jayHTML)
        XCTAssertEqual(jayReport?.snow24hIn, 0.0)
        XCTAssertEqual(jayReport?.snow48hIn, 8.0)
    }

    func testOnDeviceSelfLearningAdaptsWeights() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OnDeviceLearningStore(baseDirectory: tempDir)
        let validTime = Date().addingTimeInterval(3600)

        let hr = HourlyForecastPoint(
            time: validTime,
            leadHours: 1,
            leadBucket: "short_0_24h",
            snowIn: 0.5,
            snowP10In: 0.3,
            snowP90In: 0.7,
            liquidPrecipIn: 0.04,
            tempF: 20.0,
            windMph: 20.0,
            windGustMph: 30.0,
            freezingLevelFt: 1200,
            slrRatio: 14.0,
            precipType: "Snow",
            sourceSnowIn: ["hrrr": 0.9, "ecmwf": 0.1],
            sourceTempF: ["hrrr": 18.0, "ecmwf": 25.0]
        )

        await store.recordForecastSnapshots(
            mountainId: "killington",
            elevationBand: "summit",
            elevationFt: 4241,
            hourly: [hr]
        )

        let count = await store.verifyObservation(
            mountainId: "killington",
            mountainName: "Killington",
            elevationBand: "summit",
            validTime: validTime,
            observedTempF: 18.0,
            observedSnowIn: 0.9
        )
        XCTAssertEqual(count, 1)

        let baseWeights = ["hrrr": 0.5, "ecmwf": 0.5]
        let adapted = await store.adaptedWeights(
            mountainId: "killington",
            elevationBand: "summit",
            leadBucket: "short_0_24h",
            baseWeights: baseWeights,
            forSnow: true
        )
        XCTAssertGreaterThan(adapted["hrrr"] ?? 0.0, adapted["ecmwf"] ?? 1.0)

        let summary = await store.summary()
        XCTAssertEqual(summary.verifiedCount, 1)
        XCTAssertEqual(summary.recentLogs.count, 1)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAccuracyImprovementsAspectAndOutlierGuard() throws {
        // NW wind blowing onto a NW ridge at high elevation should boost snowfall slightly
        let nwAligned = OnDevicePhysics.orographicAspectMultiplier(
            windDirDeg: 315.0,
            windMph: 28.0,
            aspect: "NW",
            elevationFt: 3968
        )
        XCTAssertGreaterThan(nwAligned, 1.03)
        XCTAssertLessThanOrEqual(nwAligned, 1.10)

        // Outlier guard should prevent a single corrupt model temp (e.g., 90F) from pulling consensus wildly
        let engine = try OnDeviceMLEngine.loadBundled()
        let pred = engine.predictHour(
            mountainId: "killington",
            elevationBand: "summit",
            elevationFt: 4241,
            orographicFactor: 1.14,
            leadHours: 6,
            leadBucket: "short_0_24h",
            validTime: Date(),
            windMph: 18.0,
            sourceSnow: ["hrrr": 0.2, "nam": 0.2, "ecmwf": 0.2, "gfs": 4.0, "gem": 0.2, "nws": 0.2],
            sourceTemp: ["hrrr": 20.0, "nam": 20.0, "ecmwf": 20.0, "gfs": 85.0, "gem": 20.0, "nws": 20.0]
        )
        XCTAssertLessThan(pred.tempF, 24.0)
        XCTAssertLessThan(pred.snowIn, 0.35)
    }
}
