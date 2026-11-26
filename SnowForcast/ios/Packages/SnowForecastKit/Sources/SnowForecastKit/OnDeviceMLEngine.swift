import Foundation

public struct ExportedTreeNode: Codable, Sendable {
    public let isLeaf: Bool
    public let featureIdx: Int
    public let threshold: Double
    public let left: Int
    public let right: Int
    public let value: Double
    public let missingGoToLeft: Bool

    enum CodingKeys: String, CodingKey {
        case isLeaf = "is_leaf"
        case featureIdx = "feature_idx"
        case threshold, left, right, value
        case missingGoToLeft = "missing_go_to_left"
    }
}

public struct ExportedTreeEnsemble: Codable, Sendable {
    public let baseline: Double
    public let trees: [[ExportedTreeNode]]

    public func predict(_ features: [Double]) -> Double {
        var total = baseline
        for tree in trees where !tree.isEmpty {
            var idx = 0
            while idx >= 0 && idx < tree.count {
                let node = tree[idx]
                if node.isLeaf {
                    total += node.value
                    break
                }
                let fIdx = node.featureIdx
                let fVal = (fIdx >= 0 && fIdx < features.count) ? features[fIdx] : 0.0
                if fVal.isNaN {
                    idx = node.missingGoToLeft ? node.left : node.right
                } else {
                    idx = (fVal <= node.threshold) ? node.left : node.right
                }
            }
        }
        return total
    }
}

public struct ExportedBucket: Codable, Sendable {
    public let scope: String
    public let elevationBand: String
    public let leadBucket: String
    public let snowWeights: [String: Double]
    public let tempWeights: [String: Double]
    public let snowResidualStd: Double
    public let tempResidualStd: Double
    public let sampleCount: Int
    public let blendedSnowMaeIn: Double
    public let blendedTempMaeF: Double
    public let bestSingleModel: String
    public let bestSingleSnowMaeIn: Double
    public let snowResidualTrees: ExportedTreeEnsemble?
    public let tempResidualTrees: ExportedTreeEnsemble?

    enum CodingKeys: String, CodingKey {
        case scope
        case elevationBand = "elevation_band"
        case leadBucket = "lead_bucket"
        case snowWeights = "snow_weights"
        case tempWeights = "temp_weights"
        case snowResidualStd = "snow_residual_std"
        case tempResidualStd = "temp_residual_std"
        case sampleCount = "sample_count"
        case blendedSnowMaeIn = "blended_snow_mae_in"
        case blendedTempMaeF = "blended_temp_mae_f"
        case bestSingleModel = "best_single_model"
        case bestSingleSnowMaeIn = "best_single_snow_mae_in"
        case snowResidualTrees = "snow_residual_trees"
        case tempResidualTrees = "temp_residual_trees"
    }
}

public struct ExportedMountain: Codable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public let region: String
    public let latitude: Double
    public let longitude: Double
    public let elevations: ElevationSummary
    public let nwsWfo: String
    public let stationId: String
    public let aspect: String
    public let orographicFactor: Double

    enum CodingKeys: String, CodingKey {
        case id, name, state, region, latitude, longitude, elevations, aspect
        case nwsWfo = "nws_wfo"
        case stationId = "station_id"
        case orographicFactor = "orographic_factor"
    }
}

public struct ExportedWFO: Codable, Sendable {
    public let id: String
    public let name: String
    public let cityState: String
    public let coverageSummary: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case cityState = "city_state"
        case coverageSummary = "coverage_summary"
    }
}

public struct ExportedMLBundle: Codable, Sendable {
    public let version: String
    public let trainedAt: Date
    public let totalSamples: Int
    public let modelSources: [String]
    public let modelDisplayNames: [String: String]
    public let openMeteoModelMap: [String: String]
    public let mountains: [ExportedMountain]
    public let wfoOffices: [String: ExportedWFO]
    public let buckets: [ExportedBucket]

    enum CodingKeys: String, CodingKey {
        case version, mountains, buckets
        case trainedAt = "trained_at"
        case totalSamples = "total_samples"
        case modelSources = "model_sources"
        case modelDisplayNames = "model_display_names"
        case openMeteoModelMap = "open_meteo_model_map"
        case wfoOffices = "wfo_offices"
    }
}

public struct OnDeviceBlendedPrediction: Sendable {
    public let snowIn: Double
    public let snowP10In: Double
    public let snowP90In: Double
    public let tempF: Double
    public let activeSnowWeights: [String: Double]
}

public enum OnDevicePhysics {
    public static let lapseRateFPer1000Ft: Double = 3.5

    public static func leadBucket(forHours leadHours: Int) -> String {
        if leadHours <= 24 { return LeadBucket.short.rawValue }
        if leadHours <= 72 { return LeadBucket.medium.rawValue }
        return LeadBucket.extended.rawValue
    }

    public static func adjustTempForElevation(
        tempF: Double?,
        fromElevFt: Int?,
        toElevFt: Int
    ) -> Double? {
        guard let tempF, let fromElevFt else { return tempF }
        let deltaFt = toElevFt - fromElevFt
        if abs(deltaFt) < 100 { return tempF }
        return tempF - (Double(deltaFt) / 1000.0) * lapseRateFPer1000Ft
    }

    /// Stull (2011) wet-bulb temperature approximation in Fahrenheit.
    public static func computeWetBulbF(tempF: Double, rhPct: Double?) -> Double {
        guard let rhPct else { return tempF }
        let rh = max(5.0, min(100.0, rhPct))
        let tc = (tempF - 32.0) * 5.0 / 9.0
        let twC =
            tc * atan(0.151977 * sqrt(rh + 8.313659))
            + atan(tc + rh)
            - atan(rh - 1.676331)
            + 0.00391838 * pow(rh, 1.5) * atan(0.023101 * rh)
            - 4.686035
        return (((twC * 9.0 / 5.0) + 32.0) * 10.0).rounded() / 10.0
    }

    public static func isWarmNose(surfaceTempF: Double, temp850F: Double?) -> Bool {
        guard let temp850F else { return false }
        return surfaceTempF <= 32.5 && temp850F > 33.5
    }

    public static func estimateSLR(
        tempF: Double,
        windMph: Double = 10.0,
        temp850F: Double? = nil,
        temp700F: Double? = nil
    ) -> Double {
        if tempF > 35.0 { return 0.0 }
        if isWarmNose(surfaceTempF: tempF, temp850F: temp850F) { return 2.5 }

        var baseSLR: Double
        if tempF > 32.0 {
            baseSLR = 6.0 * (35.0 - tempF) / 3.0
        } else if tempF >= 27.0 {
            baseSLR = 8.0 + (32.0 - tempF) * 0.6
        } else if tempF >= 18.0 {
            baseSLR = 11.0 + (27.0 - tempF) * (5.0 / 9.0)
        } else if tempF >= 10.0 {
            baseSLR = 16.0 + (18.0 - tempF) * (2.5 / 8.0)
        } else {
            baseSLR = max(13.0, 18.5 - (10.0 - tempF) * 0.35)
        }

        // Dendritic growth zone boost aloft (0F..14F / -18C..-10C)
        let aloft = [temp850F, temp700F].compactMap { $0 }
        if !aloft.isEmpty && tempF <= 29.0 && aloft.contains(where: { $0 >= 0.0 && $0 <= 14.0 }) {
            baseSLR *= 1.12
        }

        if windMph > 22.0 {
            let penalty = min(0.22, (windMph - 22.0) * 0.008)
            baseSLR *= (1.0 - penalty)
        }
        return (max(0.0, baseSLR) * 10.0).rounded() / 10.0
    }

    public static func classifyPrecipType(
        liquidIn: Double,
        snowIn: Double,
        tempF: Double,
        temp850F: Double? = nil,
        wetBulbF: Double? = nil
    ) -> String {
        if liquidIn < 0.004 && snowIn < 0.04 { return "Dry" }
        if isWarmNose(surfaceTempF: tempF, temp850F: temp850F) { return "Mix" }
        let effectiveT = wetBulbF ?? tempF
        if effectiveT >= 35.5 || (snowIn < 0.02 && effectiveT >= 33.0) { return "Rain" }
        if effectiveT >= 31.5 && effectiveT < 35.5 { return "Mix" }
        return "Snow"
    }

    public static func computeLiftHoldRisk(
        windMph: Double,
        windGustMph: Double,
        elevationFt: Int,
        windDirDeg: Double? = nil,
        aspect: String = "NW"
    ) -> String {
        var score = max(windMph * 1.15, windGustMph)
        if elevationFt >= 3800 { score += 4.0 }
        if let dir = windDirDeg, ["NW", "WNW", "NNW"].contains(aspect), dir >= 270.0 && dir <= 345.0 {
            score += 3.0
        }
        if score >= 48.0 || windMph >= 34.0 { return "High" }
        if score >= 34.0 || windMph >= 24.0 { return "Moderate" }
        return "Low"
    }

    public static func computeSurfaceQuality(
        snow24hIn: Double,
        hourly: [HourlyForecastPoint]
    ) -> String {
        let next24 = hourly.prefix(24)
        let hasMixOrRain = next24.contains { $0.precipType == "Mix" || $0.precipType == "Rain" }
        if hasMixOrRain { return "Wet / Mixed" }
        if snow24hIn >= 4.0 {
            let avgSLR = next24.map(\.slrRatio).filter { $0 > 0 }
            let meanSLR = avgSLR.isEmpty ? 12.0 : avgSLR.reduce(0.0, +) / Double(avgSLR.count)
            return meanSLR >= 14.5 ? "Fresh Powder" : "Dense New Snow"
        }
        let maxTemp = next24.map(\.tempF).max() ?? 26.0
        let minTemp = next24.map(\.tempF).min() ?? 16.0
        if maxTemp > 36.0 && minTemp < 30.0 { return "Spring Corn / Freeze-Thaw" }
        if maxTemp > 36.0 { return "Soft Spring" }
        if snow24hIn >= 1.0 { return "Freshened Groomers" }
        return "Packed Powder"
    }

    /// Subtle upslope multiplier when brisk wind aligns perpendicularly with mountain aspect at higher elevation.
    public static func orographicAspectMultiplier(
        windDirDeg: Double?,
        windMph: Double,
        aspect: String,
        elevationFt: Int
    ) -> Double {
        guard let dir = windDirDeg, windMph >= 14.0, elevationFt >= 2400 else { return 1.0 }
        let aspectAzimuth: Double
        switch aspect.uppercased() {
        case "N": aspectAzimuth = 0.0
        case "NNE": aspectAzimuth = 22.5
        case "NE": aspectAzimuth = 45.0
        case "ENE": aspectAzimuth = 67.5
        case "NNW": aspectAzimuth = 337.5
        case "NW": aspectAzimuth = 315.0
        case "WNW": aspectAzimuth = 292.5
        default: aspectAzimuth = 315.0
        }
        let diff = abs(((dir - aspectAzimuth + 540.0).truncatingRemainder(dividingBy: 360.0)) - 180.0)
        // diff near 0 means wind blows straight onto the aspect
        let alignment = cos(diff * Double.pi / 180.0)
        let windScale = min(1.0, (windMph - 14.0) / 20.0)
        let bonus = 0.08 * alignment * windScale
        return max(0.96, min(1.10, 1.0 + bonus))
    }
}

public final class OnDeviceMLEngine: @unchecked Sendable {
    public let bundle: ExportedMLBundle
    private let bucketLookup: [String: ExportedBucket]
    public let mountainsById: [String: ExportedMountain]

    public static func loadLatest(cacheStore: DiskCacheStore = DiskCacheStore()) throws -> OnDeviceMLEngine {
        if let otaData = cacheStore.loadOTAModelData(),
           let otaEngine = try? OnDeviceMLEngine(jsonData: otaData) {
            return otaEngine
        }
        return try loadBundled()
    }

    public static func loadBundled() throws -> OnDeviceMLEngine {
        guard let url = Bundle.module.url(forResource: "ml_ensemble_v1", withExtension: "json") else {
            throw NSError(
                domain: "SnowForecastKit",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Bundled ml_ensemble_v1.json not found in SnowForecastKit resources."]
            )
        }
        let data = try Data(contentsOf: url)
        return try OnDeviceMLEngine(jsonData: data)
    }

    public init(jsonData: Data) throws {
        let decoder = SnowForecastAPIClient.makeDecoder()
        let decoded = try decoder.decode(ExportedMLBundle.self, from: jsonData)
        self.bundle = decoded

        var lookup: [String: ExportedBucket] = [:]
        for b in decoded.buckets {
            lookup[Self.bucketKey(b.scope, b.elevationBand, b.leadBucket)] = b
        }
        self.bucketLookup = lookup

        var mMap: [String: ExportedMountain] = [:]
        for m in decoded.mountains {
            mMap[m.id] = m
        }
        self.mountainsById = mMap
    }

    private static func bucketKey(_ scope: String, _ band: String, _ lead: String) -> String {
        "\(scope)|\(band)|\(lead)"
    }

    public func resolveBucket(mountainId: String, elevationBand: String, leadBucket: String) -> ExportedBucket? {
        for candidate in [
            Self.bucketKey(mountainId, elevationBand, leadBucket),
            Self.bucketKey("global", elevationBand, leadBucket),
            Self.bucketKey("global", "mid", leadBucket),
        ] {
            if let found = bucketLookup[candidate] {
                return found
            }
        }
        return nil
    }

    public func weightsForBucket(mountainId: String, elevationBand: String, leadBucket: String) -> [String: Double] {
        if let b = resolveBucket(mountainId: mountainId, elevationBand: elevationBand, leadBucket: leadBucket) {
            return b.snowWeights
        }
        return normalizeWeights(raw: [:], activeSources: bundle.modelSources)
    }

    public func tempWeightsForBucket(mountainId: String, elevationBand: String, leadBucket: String) -> [String: Double] {
        if let b = resolveBucket(mountainId: mountainId, elevationBand: elevationBand, leadBucket: leadBucket) {
            return b.tempWeights
        }
        return normalizeWeights(raw: [:], activeSources: bundle.modelSources)
    }

    private func normalizeWeights(raw: [String: Double], activeSources: [String]) -> [String: Double] {
        let keys = activeSources.isEmpty ? bundle.modelSources : activeSources
        var filtered: [String: Double] = [:]
        var total = 0.0
        for k in keys {
            let v = max(0.0, raw[k] ?? 0.0)
            filtered[k] = v
            total += v
        }
        if total <= 1e-9 {
            let uniform = 1.0 / Double(max(1, keys.count))
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, uniform) })
        }
        return filtered.mapValues { $0 / total }
    }

    public func buildResidualFeatures(
        sourceSnow: [String: Double],
        sourceTemp: [String: Double],
        elevationFt: Int,
        orographicFactor: Double,
        leadHours: Int,
        windMph: Double,
        validTime: Date
    ) -> [Double] {
        let snowVals = bundle.modelSources.compactMap { sourceSnow[$0] }
        let tempVals = bundle.modelSources.compactMap { sourceTemp[$0] }

        let snowMean = snowVals.isEmpty ? 0.0 : snowVals.reduce(0.0, +) / Double(snowVals.count)
        let snowStd: Double = {
            guard snowVals.count > 1 else { return 0.0 }
            let variance = snowVals.map { pow($0 - snowMean, 2) }.reduce(0.0, +) / Double(snowVals.count)
            return sqrt(variance)
        }()

        let tempMean = tempVals.isEmpty ? 25.0 : tempVals.reduce(0.0, +) / Double(tempVals.count)
        let tempStd: Double = {
            guard tempVals.count > 1 else { return 0.0 }
            let variance = tempVals.map { pow($0 - tempMean, 2) }.reduce(0.0, +) / Double(tempVals.count)
            return sqrt(variance)
        }()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let doy = cal.ordinality(of: .day, in: .year, for: validTime) ?? 1
        let doyRad = 2.0 * Double.pi * (Double(doy) / 365.25)

        let perSourceSnow = bundle.modelSources.map { sourceSnow[$0] ?? snowMean }
        let perSourceTemp = bundle.modelSources.map { sourceTemp[$0] ?? tempMean }

        return [
            snowMean,
            snowStd,
            tempMean,
            tempStd,
            Double(elevationFt),
            orographicFactor,
            Double(leadHours),
            windMph,
            sin(doyRad),
            cos(doyRad),
        ] + perSourceSnow + perSourceTemp
    }

    private func winsorizeSources(_ values: [String: Double], minFloor: Double) -> [String: Double] {
        let rawVals = values.values.sorted()
        guard rawVals.count >= 3 else { return values }
        let median = rawVals[rawVals.count / 2]
        let deviations = rawVals.map { abs($0 - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let limit = max(3.5 * mad, minFloor)
        return values.mapValues { min(median + limit, max(median - limit, $0)) }
    }

    public func predictHour(
        mountainId: String,
        elevationBand: String,
        elevationFt: Int,
        orographicFactor: Double,
        leadHours: Int,
        leadBucket: String,
        validTime: Date,
        windMph: Double,
        sourceSnow: [String: Double],
        sourceTemp: [String: Double],
        snowWeightOverride: [String: Double]? = nil,
        tempWeightOverride: [String: Double]? = nil
    ) -> OnDeviceBlendedPrediction {
        let bucket = resolveBucket(mountainId: mountainId, elevationBand: elevationBand, leadBucket: leadBucket)

        let cleanSnow = winsorizeSources(sourceSnow, minFloor: 0.25)
        let cleanTemp = winsorizeSources(sourceTemp, minFloor: 6.0)

        let activeSnowSources = bundle.modelSources.filter { cleanSnow[$0] != nil }
        let activeTempSources = bundle.modelSources.filter { cleanTemp[$0] != nil }

        let normSnowW = normalizeWeights(
            raw: snowWeightOverride ?? bucket?.snowWeights ?? [:],
            activeSources: activeSnowSources.isEmpty ? bundle.modelSources : activeSnowSources
        )
        let normTempW = normalizeWeights(
            raw: tempWeightOverride ?? bucket?.tempWeights ?? [:],
            activeSources: activeTempSources.isEmpty ? bundle.modelSources : activeTempSources
        )

        let baseSnow: Double = activeSnowSources.reduce(0.0) { acc, src in
            acc + (normSnowW[src] ?? 0.0) * (cleanSnow[src] ?? 0.0)
        }
        let baseTemp: Double = activeTempSources.isEmpty
            ? 26.0
            : activeTempSources.reduce(0.0) { acc, src in
                acc + (normTempW[src] ?? 0.0) * (cleanTemp[src] ?? 26.0)
            }

        var snowPred = baseSnow
        var tempPred = baseTemp
        let resStd = bucket?.snowResidualStd ?? 0.08

        if let bucket {
            let feat = buildResidualFeatures(
                sourceSnow: cleanSnow,
                sourceTemp: cleanTemp,
                elevationFt: elevationFt,
                orographicFactor: orographicFactor,
                leadHours: leadHours,
                windMph: windMph,
                validTime: validTime
            )
            if let snowTrees = bucket.snowResidualTrees, baseSnow > 0.005 {
                let adj = snowTrees.predict(feat)
                let clamped = max(-0.5 * baseSnow, min(0.6 * baseSnow, adj))
                snowPred = max(0.0, baseSnow + clamped)
            }
            if let tempTrees = bucket.tempResidualTrees {
                let adj = tempTrees.predict(feat)
                tempPred = baseTemp + max(-4.0, min(4.0, adj))
            }
        }

        let snowVals = activeSnowSources.compactMap { sourceSnow[$0] }
        let spread: Double = {
            guard snowVals.count > 1 else { return 0.0 }
            let mean = snowVals.reduce(0.0, +) / Double(snowVals.count)
            let v = snowVals.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(snowVals.count)
            return sqrt(v)
        }()
        let effResStd = snowPred > 0.01 ? resStd : 0.0
        let halfBand = max(0.0, 1.28 * hypot(spread, effResStd))

        let p10 = max(0.0, snowPred - halfBand)
        let p90 = snowPred > 0.005 ? (snowPred + halfBand) : 0.0

        let fullActiveWeights = Dictionary(
            uniqueKeysWithValues: bundle.modelSources.map { ($0, ((normSnowW[$0] ?? 0.0) * 10000.0).rounded() / 10000.0) }
        )

        return OnDeviceBlendedPrediction(
            snowIn: (max(0.0, snowPred) * 1000.0).rounded() / 1000.0,
            snowP10In: (p10 * 1000.0).rounded() / 1000.0,
            snowP90In: (p90 * 1000.0).rounded() / 1000.0,
            tempF: (tempPred * 10.0).rounded() / 10.0,
            activeSnowWeights: fullActiveWeights
        )
    }

    public func trainingStatus(scope: String? = "global") -> TrainingStatusResponse {
        let targetScope = scope ?? "global"
        var matching = bundle.buckets.filter { $0.scope == targetScope }
        if matching.isEmpty {
            matching = bundle.buckets.filter { $0.scope == "global" }
        }
        let metrics: [ModelPerformanceMetric] = matching.map { b in
            let weights = bundle.modelSources.map { src in
                ModelWeightRatio(
                    source: src,
                    displayName: bundle.modelDisplayNames[src] ?? src.uppercased(),
                    weight: ((b.snowWeights[src] ?? 0.0) * 10000.0).rounded() / 10000.0
                )
            }
            .sorted { $0.weight > $1.weight }

            return ModelPerformanceMetric(
                scope: b.scope,
                elevationBand: b.elevationBand,
                leadBucket: b.leadBucket,
                sampleCount: b.sampleCount,
                blendedSnowMaeIn: b.blendedSnowMaeIn,
                blendedTempMaeF: b.blendedTempMaeF,
                bestSingleModel: bundle.modelDisplayNames[b.bestSingleModel] ?? b.bestSingleModel,
                bestSingleSnowMaeIn: b.bestSingleSnowMaeIn,
                weights: weights
            )
        }
        return TrainingStatusResponse(
            trainedAt: bundle.trainedAt,
            modelVersion: "\(bundle.version) (On-Device)",
            totalTrainingSamples: bundle.totalSamples,
            metrics: metrics
        )
    }
}
