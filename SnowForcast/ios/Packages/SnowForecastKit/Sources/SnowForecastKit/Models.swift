import Foundation

public enum ElevationBand: String, CaseIterable, Codable, Identifiable, Sendable {
    case base
    case mid
    case summit

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .base: return "Base"
        case .mid: return "Mid"
        case .summit: return "Summit"
        }
    }
}

public enum LeadBucket: String, CaseIterable, Codable, Identifiable, Sendable {
    case short = "short_0_24h"
    case medium = "medium_24_72h"
    case extended = "extended_72_168h"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .short: return "0–24h Short Range"
        case .medium: return "24–72h Medium Range"
        case .extended: return "3–7d Extended"
        }
    }

    public var shortLabel: String {
        switch self {
        case .short: return "0–24h"
        case .medium: return "24–72h"
        case .extended: return "3–7d"
        }
    }
}

public struct ElevationSummary: Codable, Hashable, Sendable {
    public let baseFt: Int
    public let midFt: Int
    public let summitFt: Int

    enum CodingKeys: String, CodingKey {
        case baseFt = "base_ft"
        case midFt = "mid_ft"
        case summitFt = "summit_ft"
    }

    public init(baseFt: Int, midFt: Int, summitFt: Int) {
        self.baseFt = baseFt
        self.midFt = midFt
        self.summitFt = summitFt
    }

    public func feet(for band: ElevationBand) -> Int {
        switch band {
        case .base: return baseFt
        case .mid: return midFt
        case .summit: return summitFt
        }
    }
}

public struct NWSAlert: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let event: String
    public let severity: String
    public let headline: String
    public let description: String
    public let expires: Date?

    public init(
        id: String,
        event: String,
        severity: String,
        headline: String,
        description: String,
        expires: Date? = nil
    ) {
        self.id = id
        self.event = event
        self.severity = severity
        self.headline = headline
        self.description = description
        self.expires = expires
    }
}

public struct RegionalForecastPost: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceName: String
    public let author: String?
    public let title: String
    public let summary: String
    public let publishedAt: Date
    public let urlString: String
    public let isLive: Bool

    enum CodingKeys: String, CodingKey {
        case id, author, title, summary
        case sourceName = "source_name"
        case publishedAt = "published_at"
        case urlString = "url_string"
        case isLive = "is_live"
    }

    public init(
        id: String,
        sourceName: String,
        author: String?,
        title: String,
        summary: String,
        publishedAt: Date,
        urlString: String,
        isLive: Bool = true
    ) {
        self.id = id
        self.sourceName = sourceName
        self.author = author
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.urlString = urlString
        self.isLive = isLive
    }
}

public struct MountainSummary: Codable, Identifiable, Hashable, Sendable {
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
    public let snow24hIn: Double
    public let snow72hIn: Double
    public let snow5dIn: Double
    public let summitTempF: Double
    public let summitWindMph: Double
    public let confidence: String
    public let liftHoldRisk: String
    public let surfaceQuality: String
    public let warmNoseRisk: Bool
    public let activeAlertCount: Int
    public let headline: String
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, state, region, latitude, longitude, elevations, aspect, confidence, headline
        case nwsWfo = "nws_wfo"
        case stationId = "station_id"
        case snow24hIn = "snow_24h_in"
        case snow72hIn = "snow_72h_in"
        case snow5dIn = "snow_5d_in"
        case summitTempF = "summit_temp_f"
        case summitWindMph = "summit_wind_mph"
        case liftHoldRisk = "lift_hold_risk"
        case surfaceQuality = "surface_quality"
        case warmNoseRisk = "warm_nose_risk"
        case activeAlertCount = "active_alert_count"
        case updatedAt = "updated_at"
    }

    public init(
        id: String,
        name: String,
        state: String,
        region: String,
        latitude: Double,
        longitude: Double,
        elevations: ElevationSummary,
        nwsWfo: String,
        stationId: String,
        aspect: String,
        snow24hIn: Double,
        snow72hIn: Double,
        snow5dIn: Double,
        summitTempF: Double,
        summitWindMph: Double,
        confidence: String,
        liftHoldRisk: String = "Low",
        surfaceQuality: String = "Packed Powder",
        warmNoseRisk: Bool = false,
        activeAlertCount: Int = 0,
        headline: String,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.region = region
        self.latitude = latitude
        self.longitude = longitude
        self.elevations = elevations
        self.nwsWfo = nwsWfo
        self.stationId = stationId
        self.aspect = aspect
        self.snow24hIn = snow24hIn
        self.snow72hIn = snow72hIn
        self.snow5dIn = snow5dIn
        self.summitTempF = summitTempF
        self.summitWindMph = summitWindMph
        self.confidence = confidence
        self.liftHoldRisk = liftHoldRisk
        self.surfaceQuality = surfaceQuality
        self.warmNoseRisk = warmNoseRisk
        self.activeAlertCount = activeAlertCount
        self.headline = headline
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        state = try c.decode(String.self, forKey: .state)
        region = try c.decode(String.self, forKey: .region)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        elevations = try c.decode(ElevationSummary.self, forKey: .elevations)
        nwsWfo = try c.decode(String.self, forKey: .nwsWfo)
        stationId = try c.decode(String.self, forKey: .stationId)
        aspect = try c.decode(String.self, forKey: .aspect)
        snow24hIn = try c.decode(Double.self, forKey: .snow24hIn)
        snow72hIn = try c.decode(Double.self, forKey: .snow72hIn)
        snow5dIn = try c.decode(Double.self, forKey: .snow5dIn)
        summitTempF = try c.decode(Double.self, forKey: .summitTempF)
        summitWindMph = try c.decode(Double.self, forKey: .summitWindMph)
        confidence = try c.decode(String.self, forKey: .confidence)
        liftHoldRisk = try c.decodeIfPresent(String.self, forKey: .liftHoldRisk) ?? "Low"
        surfaceQuality = try c.decodeIfPresent(String.self, forKey: .surfaceQuality) ?? "Packed Powder"
        warmNoseRisk = try c.decodeIfPresent(Bool.self, forKey: .warmNoseRisk) ?? false
        activeAlertCount = try c.decodeIfPresent(Int.self, forKey: .activeAlertCount) ?? 0
        headline = try c.decode(String.self, forKey: .headline)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public struct ModelWeightRatio: Codable, Identifiable, Hashable, Sendable {
    public var id: String { source }
    public let source: String
    public let displayName: String
    public let weight: Double
    public let snow24hIn: Double?
    public let snow72hIn: Double?
    public let snow5dIn: Double?
    public let avgTempF: Double?

    enum CodingKeys: String, CodingKey {
        case source, weight
        case displayName = "display_name"
        case snow24hIn = "snow_24h_in"
        case snow72hIn = "snow_72h_in"
        case snow5dIn = "snow_5d_in"
        case avgTempF = "avg_temp_f"
    }

    public init(
        source: String,
        displayName: String,
        weight: Double,
        snow24hIn: Double? = nil,
        snow72hIn: Double? = nil,
        snow5dIn: Double? = nil,
        avgTempF: Double? = nil
    ) {
        self.source = source
        self.displayName = displayName
        self.weight = weight
        self.snow24hIn = snow24hIn
        self.snow72hIn = snow72hIn
        self.snow5dIn = snow5dIn
        self.avgTempF = avgTempF
    }
}

public struct DailyForecastPoint: Codable, Identifiable, Hashable, Sendable {
    public var id: String { date }
    public let date: String
    public let snowIn: Double
    public let snowP10In: Double
    public let snowP90In: Double
    public let liquidPrecipIn: Double
    public let slrRatio: Double
    public let tempHighF: Double
    public let tempLowF: Double
    public let windMaxMph: Double
    public let windGustMph: Double
    public let precipProbPct: Int
    public let condition: String
    public let sourceSnowIn: [String: Double]

    enum CodingKeys: String, CodingKey {
        case date, condition
        case snowIn = "snow_in"
        case snowP10In = "snow_p10_in"
        case snowP90In = "snow_p90_in"
        case liquidPrecipIn = "liquid_precip_in"
        case slrRatio = "slr_ratio"
        case tempHighF = "temp_high_f"
        case tempLowF = "temp_low_f"
        case windMaxMph = "wind_max_mph"
        case windGustMph = "wind_gust_mph"
        case precipProbPct = "precip_prob_pct"
        case sourceSnowIn = "source_snow_in"
    }

    public init(
        date: String,
        snowIn: Double,
        snowP10In: Double,
        snowP90In: Double,
        liquidPrecipIn: Double,
        slrRatio: Double,
        tempHighF: Double,
        tempLowF: Double,
        windMaxMph: Double,
        windGustMph: Double,
        precipProbPct: Int,
        condition: String,
        sourceSnowIn: [String: Double]
    ) {
        self.date = date
        self.snowIn = snowIn
        self.snowP10In = snowP10In
        self.snowP90In = snowP90In
        self.liquidPrecipIn = liquidPrecipIn
        self.slrRatio = slrRatio
        self.tempHighF = tempHighF
        self.tempLowF = tempLowF
        self.windMaxMph = windMaxMph
        self.windGustMph = windGustMph
        self.precipProbPct = precipProbPct
        self.condition = condition
        self.sourceSnowIn = sourceSnowIn
    }
}

public struct HourlyForecastPoint: Codable, Identifiable, Hashable, Sendable {
    public var id: Date { time }
    public let time: Date
    public let leadHours: Int
    public let leadBucket: String
    public let snowIn: Double
    public let snowP10In: Double
    public let snowP90In: Double
    public let liquidPrecipIn: Double
    public let tempF: Double
    public let windMph: Double
    public let windGustMph: Double
    public let freezingLevelFt: Int?
    public let temp850hpaF: Double?
    public let wetBulbF: Double?
    public let warmNoseRisk: Bool
    public let slrRatio: Double
    public let precipType: String
    public let sourceSnowIn: [String: Double]
    public let sourceTempF: [String: Double]

    enum CodingKeys: String, CodingKey {
        case time
        case leadHours = "lead_hours"
        case leadBucket = "lead_bucket"
        case snowIn = "snow_in"
        case snowP10In = "snow_p10_in"
        case snowP90In = "snow_p90_in"
        case liquidPrecipIn = "liquid_precip_in"
        case tempF = "temp_f"
        case windMph = "wind_mph"
        case windGustMph = "wind_gust_mph"
        case freezingLevelFt = "freezing_level_ft"
        case temp850hpaF = "temp_850hpa_f"
        case wetBulbF = "wet_bulb_f"
        case warmNoseRisk = "warm_nose_risk"
        case slrRatio = "slr_ratio"
        case precipType = "precip_type"
        case sourceSnowIn = "source_snow_in"
        case sourceTempF = "source_temp_f"
    }

    public init(
        time: Date,
        leadHours: Int,
        leadBucket: String,
        snowIn: Double,
        snowP10In: Double,
        snowP90In: Double,
        liquidPrecipIn: Double,
        tempF: Double,
        windMph: Double,
        windGustMph: Double,
        freezingLevelFt: Int?,
        temp850hpaF: Double? = nil,
        wetBulbF: Double? = nil,
        warmNoseRisk: Bool = false,
        slrRatio: Double,
        precipType: String,
        sourceSnowIn: [String: Double],
        sourceTempF: [String: Double]
    ) {
        self.time = time
        self.leadHours = leadHours
        self.leadBucket = leadBucket
        self.snowIn = snowIn
        self.snowP10In = snowP10In
        self.snowP90In = snowP90In
        self.liquidPrecipIn = liquidPrecipIn
        self.tempF = tempF
        self.windMph = windMph
        self.windGustMph = windGustMph
        self.freezingLevelFt = freezingLevelFt
        self.temp850hpaF = temp850hpaF
        self.wetBulbF = wetBulbF
        self.warmNoseRisk = warmNoseRisk
        self.slrRatio = slrRatio
        self.precipType = precipType
        self.sourceSnowIn = sourceSnowIn
        self.sourceTempF = sourceTempF
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Date.self, forKey: .time)
        leadHours = try c.decode(Int.self, forKey: .leadHours)
        leadBucket = try c.decode(String.self, forKey: .leadBucket)
        snowIn = try c.decode(Double.self, forKey: .snowIn)
        snowP10In = try c.decode(Double.self, forKey: .snowP10In)
        snowP90In = try c.decode(Double.self, forKey: .snowP90In)
        liquidPrecipIn = try c.decode(Double.self, forKey: .liquidPrecipIn)
        tempF = try c.decode(Double.self, forKey: .tempF)
        windMph = try c.decode(Double.self, forKey: .windMph)
        windGustMph = try c.decode(Double.self, forKey: .windGustMph)
        freezingLevelFt = try c.decodeIfPresent(Int.self, forKey: .freezingLevelFt)
        temp850hpaF = try c.decodeIfPresent(Double.self, forKey: .temp850hpaF)
        wetBulbF = try c.decodeIfPresent(Double.self, forKey: .wetBulbF)
        warmNoseRisk = try c.decodeIfPresent(Bool.self, forKey: .warmNoseRisk) ?? false
        slrRatio = try c.decode(Double.self, forKey: .slrRatio)
        precipType = try c.decode(String.self, forKey: .precipType)
        sourceSnowIn = try c.decode([String: Double].self, forKey: .sourceSnowIn)
        sourceTempF = try c.decode([String: Double].self, forKey: .sourceTempF)
    }
}

public struct MeteorologistHighlight: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(category)-\(summary.prefix(24))" }
    public let category: String
    public let summary: String

    public init(category: String, summary: String) {
        self.category = category
        self.summary = summary
    }
}

public struct MeteorologistDiscussion: Codable, Identifiable, Hashable, Sendable {
    public var id: String { wfoId }
    public let wfoId: String
    public let wfoName: String
    public let issuedAt: Date
    public let forecaster: String?
    public let productId: String
    public let mountainRelevanceSummary: String
    public let plainEnglishTakeaways: [String]
    public let highlights: [MeteorologistHighlight]
    public let synopsis: String?
    public let shortTerm: String?
    public let longTerm: String?
    public let rawText: String
    public let coveredMountainIds: [String]
    public let isLive: Bool

    enum CodingKeys: String, CodingKey {
        case forecaster, highlights, synopsis
        case wfoId = "wfo_id"
        case wfoName = "wfo_name"
        case issuedAt = "issued_at"
        case productId = "product_id"
        case mountainRelevanceSummary = "mountain_relevance_summary"
        case plainEnglishTakeaways = "plain_english_takeaways"
        case shortTerm = "short_term"
        case longTerm = "long_term"
        case rawText = "raw_text"
        case coveredMountainIds = "covered_mountain_ids"
        case isLive = "is_live"
    }

    public init(
        wfoId: String,
        wfoName: String,
        issuedAt: Date,
        forecaster: String?,
        productId: String,
        mountainRelevanceSummary: String,
        plainEnglishTakeaways: [String] = [],
        highlights: [MeteorologistHighlight],
        synopsis: String?,
        shortTerm: String?,
        longTerm: String?,
        rawText: String,
        coveredMountainIds: [String],
        isLive: Bool
    ) {
        self.wfoId = wfoId
        self.wfoName = wfoName
        self.issuedAt = issuedAt
        self.forecaster = forecaster
        self.productId = productId
        self.mountainRelevanceSummary = mountainRelevanceSummary
        self.plainEnglishTakeaways = plainEnglishTakeaways
        self.highlights = highlights
        self.synopsis = synopsis
        self.shortTerm = shortTerm
        self.longTerm = longTerm
        self.rawText = rawText
        self.coveredMountainIds = coveredMountainIds
        self.isLive = isLive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wfoId = try c.decode(String.self, forKey: .wfoId)
        wfoName = try c.decode(String.self, forKey: .wfoName)
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        forecaster = try c.decodeIfPresent(String.self, forKey: .forecaster)
        productId = try c.decode(String.self, forKey: .productId)
        mountainRelevanceSummary = try c.decode(String.self, forKey: .mountainRelevanceSummary)
        plainEnglishTakeaways = try c.decodeIfPresent([String].self, forKey: .plainEnglishTakeaways) ?? []
        highlights = try c.decode([MeteorologistHighlight].self, forKey: .highlights)
        synopsis = try c.decodeIfPresent(String.self, forKey: .synopsis)
        shortTerm = try c.decodeIfPresent(String.self, forKey: .shortTerm)
        longTerm = try c.decodeIfPresent(String.self, forKey: .longTerm)
        rawText = try c.decode(String.self, forKey: .rawText)
        coveredMountainIds = try c.decode([String].self, forKey: .coveredMountainIds)
        isLive = try c.decode(Bool.self, forKey: .isLive)
    }
}

public struct MountainObservationReading: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceName: String
    public let elevationBand: String  // "base", "mid", "summit", "station"
    public let elevationFt: Int?
    public let tempF: Double
    public let windMph: Double?
    public let observedAt: Date
    public let isOnMountainSensor: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sourceName = "source_name"
        case elevationBand = "elevation_band"
        case elevationFt = "elevation_ft"
        case tempF = "temp_f"
        case windMph = "wind_mph"
        case observedAt = "observed_at"
        case isOnMountainSensor = "is_on_mountain_sensor"
    }

    public init(
        id: String,
        sourceName: String,
        elevationBand: String,
        elevationFt: Int? = nil,
        tempF: Double,
        windMph: Double? = nil,
        observedAt: Date = Date(),
        isOnMountainSensor: Bool
    ) {
        self.id = id
        self.sourceName = sourceName
        self.elevationBand = elevationBand
        self.elevationFt = elevationFt
        self.tempF = tempF
        self.windMph = windMph
        self.observedAt = observedAt
        self.isOnMountainSensor = isOnMountainSensor
    }
}

public struct VerificationLogEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let mountainId: String
    public let mountainName: String
    public let elevationBand: String
    public let validTime: Date
    public let predictedTempF: Double
    public let observedTempF: Double
    public let predictedSnowIn: Double
    public let observedSnowIn: Double
    public let bestSource: String

    public init(
        id: String,
        mountainId: String,
        mountainName: String,
        elevationBand: String,
        validTime: Date,
        predictedTempF: Double,
        observedTempF: Double,
        predictedSnowIn: Double,
        observedSnowIn: Double,
        bestSource: String
    ) {
        self.id = id
        self.mountainId = mountainId
        self.mountainName = mountainName
        self.elevationBand = elevationBand
        self.validTime = validTime
        self.predictedTempF = predictedTempF
        self.observedTempF = observedTempF
        self.predictedSnowIn = predictedSnowIn
        self.observedSnowIn = observedSnowIn
        self.bestSource = bestSource
    }
}

public struct OnDeviceLearningSummary: Codable, Sendable {
    public let verifiedCount: Int
    public let blendedTempMaeF: Double?
    public let blendedSnowMaeIn: Double?
    public let lastVerifiedAt: Date?
    public let recentLogs: [VerificationLogEntry]

    public init(
        verifiedCount: Int = 0,
        blendedTempMaeF: Double? = nil,
        blendedSnowMaeIn: Double? = nil,
        lastVerifiedAt: Date? = nil,
        recentLogs: [VerificationLogEntry] = []
    ) {
        self.verifiedCount = verifiedCount
        self.blendedTempMaeF = blendedTempMaeF
        self.blendedSnowMaeIn = blendedSnowMaeIn
        self.lastVerifiedAt = lastVerifiedAt
        self.recentLogs = recentLogs
    }
}

public struct ResortSnowReport: Codable, Hashable, Sendable {
    public let sourceName: String
    public let snow24hIn: Double?
    public let snow48hIn: Double?
    public let snow7dIn: Double?
    public let seasonTotalIn: Double?
    public let reportedAt: Date

    enum CodingKeys: String, CodingKey {
        case sourceName = "source_name"
        case snow24hIn = "snow_24h_in"
        case snow48hIn = "snow_48h_in"
        case snow7dIn = "snow_7d_in"
        case seasonTotalIn = "season_total_in"
        case reportedAt = "reported_at"
    }

    public init(
        sourceName: String,
        snow24hIn: Double? = nil,
        snow48hIn: Double? = nil,
        snow7dIn: Double? = nil,
        seasonTotalIn: Double? = nil,
        reportedAt: Date = Date()
    ) {
        self.sourceName = sourceName
        self.snow24hIn = snow24hIn
        self.snow48hIn = snow48hIn
        self.snow7dIn = snow7dIn
        self.seasonTotalIn = seasonTotalIn
        self.reportedAt = reportedAt
    }
}

public struct MountainForecastResponse: Codable, Sendable {
    public let mountain: MountainSummary
    public let elevationBand: String
    public let elevationFt: Int
    public let leadBucketWeights: [String: [ModelWeightRatio]]
    public let daily: [DailyForecastPoint]
    public let hourly: [HourlyForecastPoint]
    public let discussion: MeteorologistDiscussion?
    public let alerts: [NWSAlert]
    public let liveObservations: [MountainObservationReading]
    public let resortSnowReport: ResortSnowReport?
    public let dataSourcesUsed: [String]
    public let isLiveWeather: Bool
    public let mlModelVersion: String

    enum CodingKeys: String, CodingKey {
        case mountain, daily, hourly, discussion, alerts
        case elevationBand = "elevation_band"
        case elevationFt = "elevation_ft"
        case leadBucketWeights = "lead_bucket_weights"
        case liveObservations = "live_observations"
        case resortSnowReport = "resort_snow_report"
        case dataSourcesUsed = "data_sources_used"
        case isLiveWeather = "is_live_weather"
        case mlModelVersion = "ml_model_version"
    }

    public init(
        mountain: MountainSummary,
        elevationBand: String,
        elevationFt: Int,
        leadBucketWeights: [String: [ModelWeightRatio]],
        daily: [DailyForecastPoint],
        hourly: [HourlyForecastPoint],
        discussion: MeteorologistDiscussion?,
        alerts: [NWSAlert] = [],
        liveObservations: [MountainObservationReading] = [],
        resortSnowReport: ResortSnowReport? = nil,
        dataSourcesUsed: [String],
        isLiveWeather: Bool,
        mlModelVersion: String
    ) {
        self.mountain = mountain
        self.elevationBand = elevationBand
        self.elevationFt = elevationFt
        self.leadBucketWeights = leadBucketWeights
        self.daily = daily
        self.hourly = hourly
        self.discussion = discussion
        self.alerts = alerts
        self.liveObservations = liveObservations
        self.resortSnowReport = resortSnowReport
        self.dataSourcesUsed = dataSourcesUsed
        self.isLiveWeather = isLiveWeather
        self.mlModelVersion = mlModelVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mountain = try c.decode(MountainSummary.self, forKey: .mountain)
        elevationBand = try c.decode(String.self, forKey: .elevationBand)
        elevationFt = try c.decode(Int.self, forKey: .elevationFt)
        leadBucketWeights = try c.decode([String: [ModelWeightRatio]].self, forKey: .leadBucketWeights)
        daily = try c.decode([DailyForecastPoint].self, forKey: .daily)
        hourly = try c.decode([HourlyForecastPoint].self, forKey: .hourly)
        discussion = try c.decodeIfPresent(MeteorologistDiscussion.self, forKey: .discussion)
        alerts = try c.decodeIfPresent([NWSAlert].self, forKey: .alerts) ?? []
        liveObservations = try c.decodeIfPresent([MountainObservationReading].self, forKey: .liveObservations) ?? []
        resortSnowReport = try c.decodeIfPresent(ResortSnowReport.self, forKey: .resortSnowReport)
        dataSourcesUsed = try c.decode([String].self, forKey: .dataSourcesUsed)
        isLiveWeather = try c.decode(Bool.self, forKey: .isLiveWeather)
        mlModelVersion = try c.decode(String.self, forKey: .mlModelVersion)
    }
}

public struct ModelPerformanceMetric: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(scope)-\(elevationBand)-\(leadBucket)" }
    public let scope: String
    public let elevationBand: String
    public let leadBucket: String
    public let sampleCount: Int
    public let blendedSnowMaeIn: Double
    public let blendedTempMaeF: Double
    public let bestSingleModel: String
    public let bestSingleSnowMaeIn: Double
    public let weights: [ModelWeightRatio]

    enum CodingKeys: String, CodingKey {
        case scope, weights
        case elevationBand = "elevation_band"
        case leadBucket = "lead_bucket"
        case sampleCount = "sample_count"
        case blendedSnowMaeIn = "blended_snow_mae_in"
        case blendedTempMaeF = "blended_temp_mae_f"
        case bestSingleModel = "best_single_model"
        case bestSingleSnowMaeIn = "best_single_snow_mae_in"
    }
}

public struct TrainingStatusResponse: Codable, Sendable {
    public let trainedAt: Date?
    public let modelVersion: String
    public let totalTrainingSamples: Int
    public let metrics: [ModelPerformanceMetric]

    enum CodingKeys: String, CodingKey {
        case metrics
        case trainedAt = "trained_at"
        case modelVersion = "model_version"
        case totalTrainingSamples = "total_training_samples"
    }
}

public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case fahrenheit = "F"
    case celsius = "C"

    public var id: String { rawValue }
    public var symbol: String { "°\(rawValue)" }
}

public enum SnowUnit: String, CaseIterable, Identifiable, Sendable {
    case inches = "in"
    case centimeters = "cm"

    public var id: String { rawValue }
    public var symbol: String { rawValue }
}

public struct WidgetMountainSnapshot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public let snow24hIn: Double
    public let snow72hIn: Double
    public let summitTempF: Double
    public let liftHoldRisk: String
    public let updatedAt: Date

    public init(
        id: String,
        name: String,
        state: String,
        snow24hIn: Double,
        snow72hIn: Double,
        summitTempF: Double,
        liftHoldRisk: String,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.snow24hIn = snow24hIn
        self.snow72hIn = snow72hIn
        self.summitTempF = summitTempF
        self.liftHoldRisk = liftHoldRisk
        self.updatedAt = updatedAt
    }
}
