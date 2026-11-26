import SwiftUI

@main
struct SnowForecastApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var alertManager = PowderAlertManager()

    init() {
        PowderAlertManager.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .environmentObject(alertManager)
        }
    }
}
