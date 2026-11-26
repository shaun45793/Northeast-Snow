import BackgroundTasks
import Foundation
import SnowForecastKit
import UserNotifications

@MainActor
final class PowderAlertManager: ObservableObject {
    static let refreshTaskIdentifier = "com.snowforecast.northeast.refresh"

    @Published var isAuthorized: Bool = false

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            if granted {
                scheduleBackgroundRefresh()
            }
            return granted
        } catch {
            return false
        }
    }

    func evaluateAndNotify(
        mountains: [MountainSummary],
        favoriteIds: Set<String>,
        thresholdInches: Double
    ) async {
        guard isAuthorized else { return }
        let matches = mountains.filter {
            favoriteIds.contains($0.id) && $0.snow72hIn >= thresholdInches
        }
        guard let top = matches.max(by: { $0.snow72hIn < $1.snow72hIn }) else { return }

        let lastNotifiedKey = "lastPowderAlertDate_\(top.id)"
        let now = Date()
        if let last = UserDefaults.standard.object(forKey: lastNotifiedKey) as? Date,
           now.timeIntervalSince(last) < 12 * 3600 {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Powder Alert: \(top.name)"
        content.body = String(
            format: "%.1f\" expected over the next 72h (%@). Lift hold risk: %@.",
            top.snow72hIn,
            top.surfaceQuality,
            top.liftHoldRisk
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "powder-alert-\(top.id)-\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(now, forKey: lastNotifiedKey)
    }

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleBackgroundRefresh(task: refreshTask)
        }
    }

    nonisolated func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated private static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)

        let workTask = Task {
            guard let engine = try? OnDeviceMLEngine.loadLatest() else {
                task.setTaskCompleted(success: false)
                return
            }
            let provider = OnDeviceForecastProvider(mlEngine: engine)
            let mountains = (try? await provider.fetchMountains(state: nil)) ?? []
            let favRaw = UserDefaults.standard.string(forKey: "favoriteMountainIds") ?? "stowe,jay-peak,wildcat"
            let favIds = Set(favRaw.split(separator: ",").map(String.init))
            let threshold = UserDefaults.standard.double(forKey: "powderAlertThresholdIn")
            let effectiveThreshold = threshold > 0 ? threshold : 6.0

            await MainActor.run {
                Task {
                    let mgr = PowderAlertManager()
                    await mgr.refreshAuthorizationStatus()
                    await mgr.evaluateAndNotify(
                        mountains: mountains,
                        favoriteIds: favIds,
                        thresholdInches: effectiveThreshold
                    )
                }
            }
            task.setTaskCompleted(success: !mountains.isEmpty)
        }

        task.expirationHandler = {
            workTask.cancel()
        }
    }
}
