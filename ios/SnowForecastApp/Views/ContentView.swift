import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var alertManager: PowderAlertManager

    var body: some View {
        TabView {
            MountainsListView()
                .tabItem {
                    Label("Mountains", systemImage: "mountain.2.fill")
                }

            PowderChaseView()
                .tabItem {
                    Label("Chase", systemImage: "car.fill")
                }

            MeteorologistFeedView()
                .tabItem {
                    Label("Forecasters", systemImage: "text.bubble.fill")
                }

            ModelLabView()
                .tabItem {
                    Label("ML Lab", systemImage: "cpu")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(AlpineTheme.powderBlue)
        .preferredColorScheme(.dark)
        .task {
            await alertManager.refreshAuthorizationStatus()
            await appState.loadInitialData(alertManager: alertManager)
        }
    }
}
