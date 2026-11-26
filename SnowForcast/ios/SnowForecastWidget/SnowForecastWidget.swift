import SnowForecastKit
import SwiftUI
import WidgetKit

struct SnowWidgetEntry: TimelineEntry {
    let date: Date
    let snapshots: [WidgetMountainSnapshot]
}

struct SnowWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnowWidgetEntry {
        SnowWidgetEntry(date: Date(), snapshots: fallbackSnapshots())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnowWidgetEntry) -> Void) {
        let cached = DiskCacheStore.loadWidgetSnapshots()
        completion(SnowWidgetEntry(date: Date(), snapshots: cached.isEmpty ? fallbackSnapshots() : cached))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnowWidgetEntry>) -> Void) {
        Task {
            let cached = DiskCacheStore.loadWidgetSnapshots()
            var snapshots = cached

            // Refresh top 3 saved mountains directly on-device if cache is missing or stale
            if snapshots.isEmpty, let engine = try? OnDeviceMLEngine.loadLatest() {
                let provider = OnDeviceForecastProvider(mlEngine: engine)
                let targetIds = ["stowe", "jay-peak", "wildcat"]
                var fresh: [WidgetMountainSnapshot] = []
                for id in targetIds {
                    if let fc = try? await provider.fetchMountainForecast(mountainId: id, elevation: .summit) {
                        let m = fc.mountain
                        fresh.append(
                            WidgetMountainSnapshot(
                                id: m.id,
                                name: m.name,
                                state: m.state,
                                snow24hIn: m.snow24hIn,
                                snow72hIn: m.snow72hIn,
                                summitTempF: m.summitTempF,
                                liftHoldRisk: m.liftHoldRisk,
                                updatedAt: m.updatedAt
                            )
                        )
                    }
                }
                if !fresh.isEmpty {
                    snapshots = fresh
                }
            }

            if snapshots.isEmpty {
                snapshots = fallbackSnapshots()
            }

            let nextRefresh = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date().addingTimeInterval(7200)
            let entry = SnowWidgetEntry(date: Date(), snapshots: snapshots)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func fallbackSnapshots() -> [WidgetMountainSnapshot] {
        MockSnowData.sampleMountains.prefix(3).map {
            WidgetMountainSnapshot(
                id: $0.id,
                name: $0.name,
                state: $0.state,
                snow24hIn: $0.snow24hIn,
                snow72hIn: $0.snow72hIn,
                summitTempF: $0.summitTempF,
                liftHoldRisk: $0.liftHoldRisk,
                updatedAt: $0.updatedAt
            )
        }
    }
}

struct SnowForecastWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnowWidgetEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            lockScreenView
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    private var lockScreenView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let top = entry.snapshots.first {
                Label(top.name, systemImage: "snowflake")
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(String(format: "24h: %.1f\" · 72h: %.1f\"", top.snow24hIn, top.snow72hIn))
                    .font(.caption2)
                Text(String(format: "%.0f°F · Hold: %@", top.summitTempF, top.liftHoldRisk))
                    .font(.caption2)
            }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("NORTHEAST", systemImage: "snowflake")
                .font(.caption2.bold())
                .foregroundStyle(Color(red: 0.35, green: 0.76, blue: 0.98))

            if let top = entry.snapshots.first {
                Text(top.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer()

                Text(String(format: "%.1f\"", top.snow72hIn))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.56, green: 0.88, blue: 1.0))

                Text("next 72h · \(Int(round(top.summitTempF)))°F")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("NORTHEAST SNOW WATCH", systemImage: "snowflake")
                    .font(.caption2.bold())
                    .foregroundStyle(Color(red: 0.35, green: 0.76, blue: 0.98))
                Spacer()
                Text("72h ML")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            ForEach(entry.snapshots.prefix(3)) { m in
                HStack {
                    Text(m.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(m.state)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(round(m.summitTempF)))°F")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                    Text(String(format: "%.1f\"", m.snow72hIn))
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(Color(red: 0.56, green: 0.88, blue: 1.0))
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@main
struct SnowForecastWidget: Widget {
    let kind: String = "SnowForecastWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnowWidgetProvider()) { entry in
            SnowForecastWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(red: 0.05, green: 0.08, blue: 0.13)
                }
        }
        .configurationDisplayName("Northeast Snow Watch")
        .description("On-device ML snowfall totals for your top Northeast mountains.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
