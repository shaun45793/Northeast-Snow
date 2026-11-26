import Foundation

public final class DiskCacheStore: @unchecked Sendable {
    public static let appGroupIdentifier = "group.com.snowforecast.northeast.shared"
    public static let widgetSnapshotsKey = "widget_mountain_snapshots_v1"

    private let cacheDirectory: URL
    private let appSupportDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL? = nil) {
        let fm = FileManager.default
        if let baseDirectory {
            self.cacheDirectory = baseDirectory.appendingPathComponent("cache", isDirectory: true)
            self.appSupportDirectory = baseDirectory.appendingPathComponent("support", isDirectory: true)
        } else {
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? caches
            self.cacheDirectory = caches.appendingPathComponent("SnowForecast", isDirectory: true)
            self.appSupportDirectory = support.appendingPathComponent("SnowForecast", isDirectory: true)
        }

        try? fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        self.decoder = SnowForecastAPIClient.makeDecoder()
    }

    // MARK: - Mountains & Forecasts

    public func saveMountainSummaries(_ summaries: [MountainSummary]) {
        save(summaries, to: cacheDirectory.appendingPathComponent("mountains_summaries.json"))
    }

    public func loadMountainSummaries() -> [MountainSummary]? {
        load([MountainSummary].self, from: cacheDirectory.appendingPathComponent("mountains_summaries.json"))
    }

    public func saveForecast(_ forecast: MountainForecastResponse, mountainId: String, band: ElevationBand) {
        let safeKey = "\(mountainId)_\(band.rawValue).json"
        save(forecast, to: cacheDirectory.appendingPathComponent(safeKey))
    }

    public func loadForecast(mountainId: String, band: ElevationBand) -> MountainForecastResponse? {
        let safeKey = "\(mountainId)_\(band.rawValue).json"
        return load(MountainForecastResponse.self, from: cacheDirectory.appendingPathComponent(safeKey))
    }

    // MARK: - Discussions & Regional Forecasters

    public func saveDiscussions(_ discussions: [MeteorologistDiscussion]) {
        save(discussions, to: cacheDirectory.appendingPathComponent("nws_discussions.json"))
    }

    public func loadDiscussions() -> [MeteorologistDiscussion]? {
        load([MeteorologistDiscussion].self, from: cacheDirectory.appendingPathComponent("nws_discussions.json"))
    }

    public func saveRegionalPosts(_ posts: [RegionalForecastPost]) {
        save(posts, to: cacheDirectory.appendingPathComponent("regional_posts.json"))
    }

    public func loadRegionalPosts() -> [RegionalForecastPost]? {
        load([RegionalForecastPost].self, from: cacheDirectory.appendingPathComponent("regional_posts.json"))
    }

    // MARK: - OTA ML Model Bundle

    public var otaModelURL: URL {
        appSupportDirectory.appendingPathComponent("ml_ensemble_latest.json")
    }

    public func saveOTAModelData(_ data: Data) throws {
        try data.write(to: otaModelURL, options: .atomic)
    }

    public func loadOTAModelData() -> Data? {
        try? Data(contentsOf: otaModelURL)
    }

    // MARK: - WidgetKit Shared Snapshots

    public func saveWidgetSnapshots(_ snapshots: [WidgetMountainSnapshot]) {
        if let data = try? encoder.encode(snapshots) {
            if let groupDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) {
                groupDefaults.set(data, forKey: Self.widgetSnapshotsKey)
            }
            UserDefaults.standard.set(data, forKey: Self.widgetSnapshotsKey)
            save(snapshots, to: cacheDirectory.appendingPathComponent("widget_snapshots.json"))
        }
    }

    public static func loadWidgetSnapshots() -> [WidgetMountainSnapshot] {
        let decoder = SnowForecastAPIClient.makeDecoder()
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let data = groupDefaults.data(forKey: widgetSnapshotsKey),
           let decoded = try? decoder.decode([WidgetMountainSnapshot].self, from: data) {
            return decoded
        }
        if let data = UserDefaults.standard.data(forKey: widgetSnapshotsKey),
           let decoded = try? decoder.decode([WidgetMountainSnapshot].self, from: data) {
            return decoded
        }
        return []
    }

    // MARK: - Helpers

    private func save<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
