import Foundation
import SnowForecastKit
import SwiftUI

enum DataSourceMode: String, CaseIterable, Identifiable {
    case onDevice = "on_device"
    case remoteBackend = "remote_backend"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onDevice: return "On-Device ML (Standalone)"
        case .remoteBackend: return "Remote FastAPI Server"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @AppStorage("dataSourceMode") var dataSourceModeRaw: String = DataSourceMode.onDevice.rawValue
    @AppStorage("backendURL") var backendURL: String = "http://127.0.0.1:8000"
    @AppStorage("otaModelURL") var otaModelURL: String = ""
    @AppStorage("snowUnit") var snowUnitRaw: String = SnowUnit.inches.rawValue
    @AppStorage("tempUnit") var tempUnitRaw: String = TemperatureUnit.fahrenheit.rawValue
    @AppStorage("defaultElevation") var defaultElevationRaw: String = ElevationBand.summit.rawValue
    @AppStorage("favoriteMountainIds") private var favoriteIdsRaw: String = "stowe,jay-peak,wildcat"
    @AppStorage("powderAlertThresholdIn") var powderAlertThresholdIn: Double = 6.0

    @Published var mountains: [MountainSummary] = []
    @Published var discussions: [MeteorologistDiscussion] = []
    @Published var regionalPosts: [RegionalForecastPost] = []
    @Published var trainingStatus: TrainingStatusResponse?
    @Published var learningSummary: OnDeviceLearningSummary?
    @Published var isLoadingMountains: Bool = false
    @Published var isUsingDemoData: Bool = false
    @Published var isUpdatingOTA: Bool = false
    @Published var isVerifyingLearning: Bool = false
    @Published var lastErrorMessage: String?

    private let cacheStore = DiskCacheStore()
    private lazy var onDeviceProvider: OnDeviceForecastProvider? = {
        guard let engine = try? OnDeviceMLEngine.loadLatest(cacheStore: cacheStore) else { return nil }
        return OnDeviceForecastProvider(mlEngine: engine, cacheStore: cacheStore)
    }()

    var dataSourceMode: DataSourceMode {
        get { DataSourceMode(rawValue: dataSourceModeRaw) ?? .onDevice }
        set { dataSourceModeRaw = newValue.rawValue }
    }

    var snowUnit: SnowUnit {
        get { SnowUnit(rawValue: snowUnitRaw) ?? .inches }
        set { snowUnitRaw = newValue.rawValue }
    }

    var tempUnit: TemperatureUnit {
        get { TemperatureUnit(rawValue: tempUnitRaw) ?? .fahrenheit }
        set { tempUnitRaw = newValue.rawValue }
    }

    var defaultElevation: ElevationBand {
        get { ElevationBand(rawValue: defaultElevationRaw) ?? .summit }
        set { defaultElevationRaw = newValue.rawValue }
    }

    var favoriteIds: Set<String> {
        get {
            Set(favoriteIdsRaw.split(separator: ",").map(String.init))
        }
        set {
            favoriteIdsRaw = newValue.sorted().joined(separator: ",")
        }
    }

    func toggleFavorite(_ mountainId: String) {
        var current = favoriteIds
        if current.contains(mountainId) {
            current.remove(mountainId)
        } else {
            current.insert(mountainId)
        }
        favoriteIds = current
    }

    func isFavorite(_ mountainId: String) -> Bool {
        favoriteIds.contains(mountainId)
    }

    func activeProvider() -> SnowForecastProviding? {
        switch dataSourceMode {
        case .onDevice:
            return onDeviceProvider
        case .remoteBackend:
            return try? SnowForecastAPIClient(baseURLString: backendURL)
        }
    }

    func loadInitialData(alertManager: PowderAlertManager? = nil) async {
        // Pre-populate instantaneously from disk cache if available
        if mountains.isEmpty, let diskMountains = cacheStore.loadMountainSummaries(), !diskMountains.isEmpty {
            mountains = diskMountains
        }
        if discussions.isEmpty, let diskDisc = cacheStore.loadDiscussions(), !diskDisc.isEmpty {
            discussions = diskDisc
        }
        if regionalPosts.isEmpty, let diskPosts = cacheStore.loadRegionalPosts(), !diskPosts.isEmpty {
            regionalPosts = diskPosts
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshMountains(alertManager: alertManager) }
            group.addTask { await self.refreshDiscussions() }
            group.addTask { await self.refreshRegionalPosts() }
            group.addTask { await self.refreshMLStatus() }
        }
    }

    func refreshMountains(alertManager: PowderAlertManager? = nil) async {
        isLoadingMountains = true
        defer { isLoadingMountains = false }

        guard let provider = activeProvider() else {
            loadDemoMountains(reason: "Unable to initialize forecast provider.")
            return
        }

        do {
            let fetched = try await provider.fetchMountains(state: nil)
            if fetched.isEmpty {
                loadDemoMountains(reason: "Weather feeds unreachable — showing cached/preview data.")
            } else {
                mountains = fetched
                isUsingDemoData = false
                lastErrorMessage = nil
                if let alertManager {
                    await alertManager.evaluateAndNotify(
                        mountains: fetched,
                        favoriteIds: favoriteIds,
                        thresholdInches: powderAlertThresholdIn
                    )
                }
            }
        } catch {
            loadDemoMountains(reason: "Weather feeds unreachable — showing cached/preview data.")
        }
    }

    func refreshDiscussions() async {
        guard let provider = activeProvider() else {
            discussions = [MockSnowData.sampleDiscussionBTV]
            return
        }
        do {
            let fetched = try await provider.fetchDiscussions()
            if !fetched.isEmpty {
                discussions = fetched
            } else if discussions.isEmpty {
                discussions = [MockSnowData.sampleDiscussionBTV]
            }
        } catch {
            if discussions.isEmpty {
                discussions = [MockSnowData.sampleDiscussionBTV]
            }
        }
    }

    func refreshRegionalPosts() async {
        guard let onDeviceProvider else { return }
        let fetched = await onDeviceProvider.fetchRegionalPosts()
        if !fetched.isEmpty {
            regionalPosts = fetched
        }
    }

    func refreshMLStatus() async {
        guard let provider = activeProvider() else { return }
        do {
            trainingStatus = try await provider.fetchMLStatus(scope: "global")
        } catch {
            // Ignore in offline mode
        }
        if let onDeviceProvider {
            learningSummary = await onDeviceProvider.fetchLearningSummary()
        }
    }

    func verifyAndAdaptOnDevice() async {
        guard let onDeviceProvider else { return }
        isVerifyingLearning = true
        defer { isVerifyingLearning = false }
        let favList = Array(favoriteIds)
        learningSummary = await onDeviceProvider.runSelfLearningVerification(
            mountainIds: favList.isEmpty ? nil : favList
        )
        await refreshMountains()
    }

    func downloadOTAModelUpdate() async {
        guard let onDeviceProvider,
              let url = URL(string: otaModelURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true
        else {
            lastErrorMessage = "Enter a valid HTTPS URL for ml_ensemble_v1.json"
            return
        }
        isUpdatingOTA = true
        defer { isUpdatingOTA = false }
        do {
            trainingStatus = try await onDeviceProvider.reloadOTAModel(from: url)
            lastErrorMessage = nil
            await refreshMountains()
        } catch {
            lastErrorMessage = "OTA weight update failed: \(error.localizedDescription)"
        }
    }

    func retrainModel() async {
        guard let provider = activeProvider() else { return }
        do {
            trainingStatus = try await provider.triggerRetrain()
            await refreshMountains()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func loadForecast(for mountain: MountainSummary, band: ElevationBand) async -> MountainForecastResponse {
        if let provider = activeProvider() {
            do {
                let response = try await provider.fetchMountainForecast(mountainId: mountain.id, elevation: band)
                isUsingDemoData = !response.isLiveWeather
                return response
            } catch {
                // Fall back to sample forecast if offline
            }
        }
        return MockSnowData.sampleForecast(for: mountain, band: band)
    }

    private func loadDemoMountains(reason: String) {
        if mountains.isEmpty {
            mountains = cacheStore.loadMountainSummaries() ?? MockSnowData.sampleMountains
        }
        isUsingDemoData = true
        lastErrorMessage = reason
    }
}
