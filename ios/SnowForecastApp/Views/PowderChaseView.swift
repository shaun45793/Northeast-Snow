import SnowForecastKit
import SwiftUI

struct PowderChaseView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var locationManager: LocationManager

    @State private var sortMode: ChaseSort = .chaseScore
    @State private var maxDriveHours: Double = 6.0

    enum ChaseSort: String, CaseIterable, Identifiable {
        case chaseScore = "Chase Score"
        case snow72h = "72h Snow"
        case nearest = "Nearest"
        var id: String { rawValue }
    }

    private struct ChaseRow: Identifiable {
        let mountain: MountainSummary
        let miles: Double?
        let driveHours: Double?
        let score: Double
        var id: String { mountain.id }
    }

    private var rankedRows: [ChaseRow] {
        let rows: [ChaseRow] = appState.mountains.compactMap { m in
            let miles = locationManager.distanceMiles(toLatitude: m.latitude, longitude: m.longitude)
            let driveH = miles.map { locationManager.estimatedDriveHours(miles: $0) }
            if let driveH, driveH > maxDriveHours {
                return nil
            }
            let holdPenalty = m.liftHoldRisk == "High" ? 0.72 : (m.liftHoldRisk == "Moderate" ? 0.9 : 1.0)
            let denom = max(1.0, driveH ?? 2.5)
            let score = (m.snow72hIn * holdPenalty) / denom
            return ChaseRow(mountain: m, miles: miles, driveHours: driveH, score: score)
        }

        switch sortMode {
        case .chaseScore:
            return rows.sorted { $0.score > $1.score }
        case .snow72h:
            return rows.sorted { $0.mountain.snow72hIn > $1.mountain.snow72hIn }
        case .nearest:
            return rows.sorted { ($0.miles ?? 9999) < ($1.miles ?? 9999) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    controlsCard

                    ForEach(Array(rankedRows.enumerated()), id: \.element.id) { idx, row in
                        NavigationLink(value: row.mountain) {
                            chaseRowCard(rank: idx + 1, row: row)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(AlpineTheme.background.ignoresSafeArea())
            .navigationTitle("Powder Chase")
            .navigationDestination(for: MountainSummary.self) { m in
                MountainDetailView(mountain: m)
            }
        }
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Storm-to-Drive Optimizer")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(locationManager.currentLocation == nil ? "Enable location to rank snow per drive hour" : "Ranked from your current iPhone location")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                Button {
                    locationManager.requestLocation()
                } label: {
                    Label(locationManager.currentLocation == nil ? "Locate" : "Update", systemImage: "location.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(AlpineTheme.powderBlue, in: Capsule())
                        .foregroundStyle(.black)
                }
            }

            Picker("Sort", selection: $sortMode) {
                ForEach(ChaseSort.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if locationManager.currentLocation != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max Drive Time")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text("\(String(format: "%.1f", maxDriveHours)) hrs")
                            .font(.caption.bold())
                            .foregroundStyle(AlpineTheme.iceCyan)
                    }
                    Slider(value: $maxDriveHours, in: 1.5...8.0, step: 0.5)
                        .tint(AlpineTheme.powderBlue)
                }
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func chaseRowCard(rank: Int, row: ChaseRow) -> some View {
        let m = row.mountain
        return HStack(spacing: 12) {
            Text("#\(rank)")
                .font(.headline.bold().monospacedDigit())
                .foregroundStyle(rank <= 3 ? AlpineTheme.iceCyan : .white.opacity(0.6))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(m.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(m.state)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                }

                HStack(spacing: 8) {
                    Text(m.surfaceQuality)
                        .foregroundStyle(AlpineTheme.powderBlue)
                    Text("·")
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Lift Hold: \(m.liftHoldRisk)")
                        .foregroundStyle(m.liftHoldRisk == "High" ? AlpineTheme.amberAlert : .white.opacity(0.7))
                }
                .font(.caption)

                if let driveText = locationManager.formattedDriveEstimate(toLatitude: m.latitude, longitude: m.longitude) {
                    Label(driveText, systemImage: "car.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(SnowFormatting.formatSnow(m.snow72hIn, unit: appState.snowUnit))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(AlpineTheme.iceCyan)
                Text("72h snow")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(14)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
