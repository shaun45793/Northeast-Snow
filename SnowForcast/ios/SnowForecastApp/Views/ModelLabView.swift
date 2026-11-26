import SnowForecastKit
import SwiftUI

struct ModelLabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedBand: ElevationBand = .summit
    @State private var isRetraining: Bool = false

    private var filteredMetrics: [ModelPerformanceMetric] {
        (appState.trainingStatus?.metrics ?? []).filter { $0.elevationBand == selectedBand.rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusHeader
                    onDeviceLearningCard

                    Picker("Elevation", selection: $selectedBand) {
                        ForEach(ElevationBand.allCases) { band in
                            Text(band.label).tag(band)
                        }
                    }
                    .pickerStyle(.segmented)

                    if filteredMetrics.isEmpty {
                        Text("Start the FastAPI backend to inspect live ML ensemble weights and MAE verification metrics.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        ForEach(filteredMetrics) { metric in
                            metricCard(metric)
                        }
                    }

                    if appState.dataSourceMode == .remoteBackend {
                        Button {
                            Task {
                                isRetraining = true
                                await appState.retrainModel()
                                isRetraining = false
                            }
                        } label: {
                            HStack {
                                if isRetraining {
                                    ProgressView()
                                        .tint(.black)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(isRetraining ? "Retraining ML Ensemble..." : "Ingest Observations & Retrain ML")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AlpineTheme.powderBlue, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.black)
                        }
                        .disabled(isRetraining)
                    } else {
                        Button {
                            Task {
                                await appState.verifyAndAdaptOnDevice()
                            }
                        } label: {
                            HStack {
                                if appState.isVerifyingLearning {
                                    ProgressView()
                                        .tint(.black)
                                } else {
                                    Image(systemName: "brain.head.profile")
                                }
                                Text(appState.isVerifyingLearning ? "Verifying Against Stations..." : "Verify Past Forecasts & Adapt Weights")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AlpineTheme.powderBlue, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.black)
                        }
                        .disabled(appState.isVerifyingLearning)
                    }
                }
                .padding(16)
            }
            .background(AlpineTheme.background.ignoresSafeArea())
            .navigationTitle("ML Model Lab")
            .refreshable {
                await appState.refreshMLStatus()
            }
        }
    }

    private var onDeviceLearningCard: some View {
        let summary = appState.learningSummary
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("On-Device Self-Learning Loop", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(summary?.verifiedCount ?? 0) verified")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AlpineTheme.forestMint.opacity(0.2), in: Capsule())
                    .foregroundStyle(AlpineTheme.forestMint)
            }

            Text("Logs your iPhone's past predictions, checks actual station/mountain temperatures & snowfall, and shifts model ratios automatically.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            if let summary, summary.verifiedCount > 0 {
                HStack(spacing: 12) {
                    if let tMae = summary.blendedTempMaeF {
                        statTile(
                            title: "Live Temp MAE",
                            value: String(format: "%.1f°F", tMae),
                            accent: AlpineTheme.iceCyan
                        )
                    }
                    if let sMae = summary.blendedSnowMaeIn {
                        statTile(
                            title: "Live Snow MAE",
                            value: String(format: "%.2f\"/hr", sMae),
                            accent: AlpineTheme.forestMint
                        )
                    }
                }

                ForEach(summary.recentLogs.prefix(3)) { log in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(log.mountainName) (\(log.elevationBand))")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                            Text(log.validTime.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Text("Pred \(SnowFormatting.formatTemp(log.predictedTempF, unit: appState.tempUnit)) · Obs \(SnowFormatting.formatTemp(log.observedTempF, unit: appState.tempUnit))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AlpineTheme.iceCyan)
                    }
                    .padding(8)
                    .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multi-Source Stacker")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Combines HRRR, NAM, ECMWF, GFS, GEM, and NWS using non-negative Ridge ratios + Gradient Boosted residual correction.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            if let status = appState.trainingStatus {
                HStack(spacing: 16) {
                    Label("\(status.totalTrainingSamples) samples", systemImage: "chart.bar.doc.horizontal")
                    Label(status.modelVersion, systemImage: "tag")
                }
                .font(.caption.bold())
                .foregroundStyle(AlpineTheme.iceCyan)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func metricCard(_ metric: ModelPerformanceMetric) -> some View {
        let bucketTitle = LeadBucket(rawValue: metric.leadBucket)?.title ?? metric.leadBucket

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(bucketTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("\(metric.sampleCount) pts")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 12) {
                statTile(
                    title: "ML Snow MAE",
                    value: String(format: "%.3f\"/hr", metric.blendedSnowMaeIn),
                    accent: AlpineTheme.forestMint
                )
                statTile(
                    title: "Best Single (\(metric.bestSingleModel))",
                    value: String(format: "%.3f\"/hr", metric.bestSingleSnowMaeIn),
                    accent: .white
                )
                statTile(
                    title: "ML Temp MAE",
                    value: String(format: "%.1f°F", metric.blendedTempMaeF),
                    accent: AlpineTheme.powderBlue
                )
            }

            VStack(spacing: 6) {
                ForEach(metric.weights) { w in
                    HStack {
                        Text(w.displayName)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 110, alignment: .leading)

                        GeometryReader { geo in
                            Capsule()
                                .fill(AlpineTheme.modelColor(w.source))
                                .frame(width: max(3, geo.size.width * w.weight), height: 7)
                        }
                        .frame(height: 7)

                        Text(SnowFormatting.formatPercent(w.weight))
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(AlpineTheme.iceCyan)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statTile(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10))
    }
}
