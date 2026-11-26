import SnowForecastKit
import SwiftUI

struct ModelBreakdownCard: View {
    let leadBucketWeights: [String: [ModelWeightRatio]]
    let snowUnit: SnowUnit
    let tempUnit: TemperatureUnit

    @State private var selectedBucket: LeadBucket = .short

    private var ratios: [ModelWeightRatio] {
        leadBucketWeights[selectedBucket.rawValue] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("ML Forecast Ratios", systemImage: "cpu")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("Learned Ensemble")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AlpineTheme.powderBlue.opacity(0.18), in: Capsule())
                    .foregroundStyle(AlpineTheme.powderBlue)
            }

            Picker("Lead Window", selection: $selectedBucket) {
                ForEach(LeadBucket.allCases) { bucket in
                    Text(bucket.shortLabel).tag(bucket)
                }
            }
            .pickerStyle(.segmented)

            // Stacked horizontal ratio bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(ratios.filter { $0.weight > 0.01 }) { item in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AlpineTheme.modelColor(item.source))
                            .frame(width: max(4, (geo.size.width - CGFloat(ratios.count) * 2) * item.weight))
                    }
                }
            }
            .frame(height: 12)

            VStack(spacing: 10) {
                ForEach(ratios) { ratio in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(AlpineTheme.modelColor(ratio.source))
                            .frame(width: 9, height: 9)

                        Text(ratio.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 112, alignment: .leading)

                        Text(SnowFormatting.formatPercent(ratio.weight))
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(AlpineTheme.iceCyan)
                            .frame(width: 42, alignment: .trailing)

                        Spacer()

                        if let snow = snowValue(for: ratio) {
                            Text(SnowFormatting.formatSnow(snow, unit: snowUnit))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(.white)
                        } else {
                            Text("—")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }

                        if let temp = ratio.avgTempF {
                            Text(SnowFormatting.formatTemp(temp, unit: tempUnit))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }

            Text("Weights adapt automatically by mountain, elevation band, and forecast lead time using non-negative Ridge + gradient-boosted residual correction.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func snowValue(for ratio: ModelWeightRatio) -> Double? {
        switch selectedBucket {
        case .short:
            return ratio.snow24hIn
        case .medium:
            return ratio.snow72hIn
        case .extended:
            return ratio.snow5dIn
        }
    }
}
