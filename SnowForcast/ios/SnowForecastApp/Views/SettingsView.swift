import SnowForecastKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var alertManager: PowderAlertManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Units & Defaults") {
                    Picker("Snowfall Units", selection: $appState.snowUnitRaw) {
                        ForEach(SnowUnit.allCases) { unit in
                            Text(unit.symbol).tag(unit.rawValue)
                        }
                    }

                    Picker("Temperature Units", selection: $appState.tempUnitRaw) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.symbol).tag(unit.rawValue)
                        }
                    }

                    Picker("Default Mountain Elevation", selection: $appState.defaultElevationRaw) {
                        ForEach(ElevationBand.allCases) { band in
                            Text(band.label).tag(band.rawValue)
                        }
                    }
                }

                Section("Powder Alerts & Location") {
                    HStack {
                        Text("72h Alert Threshold")
                        Spacer()
                        Text(String(format: "%.0f\"", appState.powderAlertThresholdIn))
                            .foregroundStyle(AlpineTheme.powderBlue)
                    }
                    Slider(value: $appState.powderAlertThresholdIn, in: 2.0...12.0, step: 1.0)
                        .tint(AlpineTheme.powderBlue)

                    Button {
                        Task {
                            _ = await alertManager.requestAuthorization()
                        }
                    } label: {
                        HStack {
                            Text(alertManager.isAuthorized ? "Powder Alerts Enabled" : "Enable Powder Alerts")
                            Spacer()
                            Image(systemName: alertManager.isAuthorized ? "bell.badge.fill" : "bell")
                                .foregroundStyle(alertManager.isAuthorized ? AlpineTheme.forestMint : AlpineTheme.powderBlue)
                        }
                    }

                    Button {
                        locationManager.requestLocation()
                    } label: {
                        HStack {
                            Text(locationManager.currentLocation == nil ? "Enable Location for Drive Times" : "Refresh Current Location")
                            Spacer()
                            Image(systemName: "location.fill")
                                .foregroundStyle(locationManager.currentLocation != nil ? AlpineTheme.forestMint : AlpineTheme.powderBlue)
                        }
                    }
                }

                Section("ML & Weather Engine") {
                    Picker("Inference Mode", selection: $appState.dataSourceModeRaw) {
                        ForEach(DataSourceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }

                    if appState.dataSourceMode == .remoteBackend {
                        TextField("Backend URL", text: $appState.backendURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Text("Runs the trained Ridge + Gradient Boosted ML ensemble (19,872 training samples) directly on your iPhone using live Open-Meteo, NWS, and MWOBS feeds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("Optional OTA Weights JSON URL", text: $appState.otaModelURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task {
                                await appState.downloadOTAModelUpdate()
                            }
                        } label: {
                            HStack {
                                Text(appState.isUpdatingOTA ? "Downloading ML Weights..." : "Check for OTA ML Weight Update")
                                Spacer()
                                if appState.isUpdatingOTA {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(appState.isUpdatingOTA || appState.otaModelURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button("Refresh All Forecasts Now") {
                        Task {
                            await appState.loadInitialData(alertManager: alertManager)
                        }
                    }
                }

                Section("Sources & Coverage") {
                    LabeledContent("Weather Models", value: "HRRR, NAM, ECMWF, GFS, GEM, NWS")
                    LabeledContent("Meteorologists", value: "NWS BTV/GYX/ALY/BOX/CAR, MWOBS, Single Chair")
                    LabeledContent("Mountains Covered", value: "\(appState.mountains.count) Northeast Peaks")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AlpineTheme.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }
}
