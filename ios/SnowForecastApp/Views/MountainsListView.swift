import SnowForecastKit
import SwiftUI

struct MountainsListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var alertManager: PowderAlertManager

    @State private var searchText: String = ""
    @State private var selectedState: String = "All"
    @State private var favoritesOnly: Bool = false

    private let stateOptions = ["All", "VT", "NH", "ME", "NY", "MA"]

    private var filteredMountains: [MountainSummary] {
        appState.mountains.filter { m in
            let matchesState = selectedState == "All" || m.state == selectedState
            let matchesFav = !favoritesOnly || appState.isFavorite(m.id)
            let matchesSearch = searchText.isEmpty ||
                m.name.localizedCaseInsensitiveContains(searchText) ||
                m.region.localizedCaseInsensitiveContains(searchText)
            return matchesState && matchesFav && matchesSearch
        }
    }

    private var topPowderMountain: MountainSummary? {
        appState.mountains.max(by: { $0.snow5dIn < $1.snow5dIn })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if appState.isUsingDemoData {
                        demoBanner
                    }

                    if let top = topPowderMountain, selectedState == "All", searchText.isEmpty, !favoritesOnly {
                        NavigationLink(value: top) {
                            powderHeroCard(top)
                        }
                        .buttonStyle(.plain)
                    }

                    filterBar

                    ForEach(filteredMountains) { mountain in
                        NavigationLink(value: mountain) {
                            MountainRowCard(
                                mountain: mountain,
                                snowUnit: appState.snowUnit,
                                tempUnit: appState.tempUnit,
                                driveText: locationManager.formattedDriveEstimate(toLatitude: mountain.latitude, longitude: mountain.longitude),
                                isFavorite: appState.isFavorite(mountain.id),
                                onToggleFavorite: { appState.toggleFavorite(mountain.id) }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AlpineTheme.background.ignoresSafeArea())
            .navigationTitle("Northeast Snow")
            .searchable(text: $searchText, prompt: "Search mountains or regions")
            .refreshable {
                await appState.refreshMountains(alertManager: alertManager)
            }
            .navigationDestination(for: MountainSummary.self) { mountain in
                MountainDetailView(mountain: mountain)
            }
        }
    }

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(AlpineTheme.amberAlert)
            Text(appState.lastErrorMessage ?? "Offline — showing cached/preview forecast.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(10)
        .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private func powderHeroCard(_ mountain: MountainSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TOP 5-DAY POWDER WATCH", systemImage: "snowflake")
                    .font(.caption.bold())
                    .foregroundStyle(AlpineTheme.powderBlue)
                Spacer()
                Text(mountain.nwsWfo)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AlpineTheme.powderBlue.opacity(0.2), in: Capsule())
                    .foregroundStyle(AlpineTheme.iceCyan)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mountain.name)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("\(mountain.region), \(mountain.state) · \(SnowFormatting.formatElevation(mountain.elevations.summitFt))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(SnowFormatting.formatSnow(mountain.snow5dIn, unit: appState.snowUnit))
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(AlpineTheme.iceCyan)
                    Text("next 5 days")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            HStack(spacing: 8) {
                Text(mountain.surfaceQuality)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)

                Text("Lift Hold: \(mountain.liftHoldRisk)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((mountain.liftHoldRisk == "High" ? AlpineTheme.amberAlert : AlpineTheme.forestMint).opacity(0.2), in: Capsule())
                    .foregroundStyle(mountain.liftHoldRisk == "High" ? AlpineTheme.amberAlert : AlpineTheme.forestMint)

                Spacer()
            }

            Text(mountain.headline)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.11, green: 0.22, blue: 0.36),
                    AlpineTheme.cardBackground,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AlpineTheme.powderBlue.opacity(0.35), lineWidth: 1)
        )
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    favoritesOnly.toggle()
                } label: {
                    Label("Saved", systemImage: favoritesOnly ? "star.fill" : "star")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            favoritesOnly ? AlpineTheme.amberAlert.opacity(0.22) : AlpineTheme.cardBackground,
                            in: Capsule()
                        )
                        .foregroundStyle(favoritesOnly ? AlpineTheme.amberAlert : .white.opacity(0.85))
                }

                ForEach(stateOptions, id: \.self) { state in
                    Button {
                        selectedState = state
                    } label: {
                        Text(state)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                selectedState == state ? AlpineTheme.powderBlue : AlpineTheme.cardBackground,
                                in: Capsule()
                            )
                            .foregroundStyle(selectedState == state ? .black : .white.opacity(0.85))
                    }
                }
            }
        }
    }
}

private struct MountainRowCard: View {
    let mountain: MountainSummary
    let snowUnit: SnowUnit
    let tempUnit: TemperatureUnit
    let driveText: String?
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mountain.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(mountain.state)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(.white.opacity(0.85))
                        if mountain.activeAlertCount > 0 {
                            Label("\(mountain.activeAlertCount)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AlpineTheme.amberAlert.opacity(0.22), in: Capsule())
                                .foregroundStyle(AlpineTheme.amberAlert)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("\(mountain.region) · \(SnowFormatting.formatElevation(mountain.elevations.summitFt))")
                        if let driveText {
                            Text("· \(driveText)")
                                .foregroundStyle(AlpineTheme.powderBlue)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? AlpineTheme.amberAlert : .white.opacity(0.45))
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                snowStatBox(title: "24h", value: SnowFormatting.formatSnow(mountain.snow24hIn, unit: snowUnit), highlight: mountain.snow24hIn >= 3.0)
                snowStatBox(title: "72h", value: SnowFormatting.formatSnow(mountain.snow72hIn, unit: snowUnit), highlight: mountain.snow72hIn >= 6.0)
                snowStatBox(title: "5-Day", value: SnowFormatting.formatSnow(mountain.snow5dIn, unit: snowUnit), highlight: mountain.snow5dIn >= 8.0)

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Label(SnowFormatting.formatTemp(mountain.summitTempF, unit: tempUnit), systemImage: "thermometer.snowflake")
                        Label(SnowFormatting.formatWind(mountain.summitWindMph), systemImage: "wind")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))

                    HStack(spacing: 4) {
                        Circle()
                            .fill(AlpineTheme.confidenceColor(mountain.confidence))
                            .frame(width: 7, height: 7)
                        Text("\(mountain.surfaceQuality) · Hold: \(mountain.liftHoldRisk)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }

            if mountain.warmNoseRisk {
                Label("850mb warm-nose detected: monitor freezing/sleet levels", systemImage: "cloud.sleet.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(AlpineTheme.amberAlert)
            }
        }
        .padding(14)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func snowStatBox(title: String, value: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(highlight ? AlpineTheme.iceCyan : .white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10))
    }
}
