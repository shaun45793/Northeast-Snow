import SnowForecastKit
import SwiftUI

struct MountainDetailView: View {
    @EnvironmentObject private var appState: AppState
    let mountain: MountainSummary

    @State private var selectedBand: ElevationBand = .summit
    @State private var forecast: MountainForecastResponse?
    @State private var isLoading: Bool = true
    @State private var showFullDiscussion: Bool = false
    @State private var expandedAlertId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                elevationPicker

                if let forecast {
                    if !forecast.alerts.isEmpty {
                        alertsSection(forecast.alerts)
                    }

                    if !forecast.liveObservations.isEmpty || forecast.resortSnowReport != nil {
                        liveSensorsSection(forecast.liveObservations, snowReport: forecast.resortSnowReport)
                    }

                    SnowChartsView(
                        daily: forecast.daily,
                        hourly: forecast.hourly,
                        snowUnit: appState.snowUnit,
                        tempUnit: appState.tempUnit
                    )

                    dailySnowSection(forecast)
                    hourlyTimelineSection(forecast)
                    ModelBreakdownCard(
                        leadBucketWeights: forecast.leadBucketWeights,
                        snowUnit: appState.snowUnit,
                        tempUnit: appState.tempUnit
                    )
                    if let discussion = forecast.discussion {
                        meteorologistSection(discussion)
                    }
                } else if isLoading {
                    ProgressView("Blending multi-model snow forecast...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .tint(AlpineTheme.powderBlue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(AlpineTheme.background.ignoresSafeArea())
        .navigationTitle(mountain.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.toggleFavorite(mountain.id)
                } label: {
                    Image(systemName: appState.isFavorite(mountain.id) ? "star.fill" : "star")
                        .foregroundStyle(appState.isFavorite(mountain.id) ? AlpineTheme.amberAlert : .white)
                }
            }
        }
        .task {
            selectedBand = appState.defaultElevation
            await fetchBand(selectedBand)
        }
        .onChange(of: selectedBand) { _, newBand in
            Task { await fetchBand(newBand) }
        }
        .sheet(isPresented: $showFullDiscussion) {
            if let discussion = forecast?.discussion {
                NavigationStack {
                    DiscussionDetailView(discussion: discussion)
                }
            }
        }
    }

    private func fetchBand(_ band: ElevationBand) async {
        isLoading = true
        forecast = await appState.loadForecast(for: mountain, band: band)
        isLoading = false
    }

    private var headerCard: some View {
        let activeSummary = forecast?.mountain ?? mountain
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(mountain.region), \(mountain.state)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(selectedBand.label): \(SnowFormatting.formatElevation(mountain.elevations.feet(for: selectedBand))) · Aspect \(mountain.aspect)")
                        .font(.caption)
                        .foregroundStyle(AlpineTheme.powderBlue)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(AlpineTheme.confidenceColor(activeSummary.confidence))
                        .frame(width: 8, height: 8)
                    Text("\(activeSummary.confidence) Conf.")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AlpineTheme.cardElevated, in: Capsule())
            }

            HStack(spacing: 12) {
                metricPill(title: "24h Snow", value: SnowFormatting.formatSnow(activeSummary.snow24hIn, unit: appState.snowUnit))
                metricPill(title: "72h Snow", value: SnowFormatting.formatSnow(activeSummary.snow72hIn, unit: appState.snowUnit))
                metricPill(title: "5-Day", value: SnowFormatting.formatSnow(activeSummary.snow5dIn, unit: appState.snowUnit))
                metricPill(title: "Temp", value: SnowFormatting.formatTemp(activeSummary.summitTempF, unit: appState.tempUnit))
            }

            HStack(spacing: 8) {
                Label(activeSummary.surfaceQuality, systemImage: "sparkles")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AlpineTheme.cardElevated, in: Capsule())
                    .foregroundStyle(AlpineTheme.iceCyan)

                Label("Lift Hold: \(activeSummary.liftHoldRisk)", systemImage: "wind")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (activeSummary.liftHoldRisk == "High" ? AlpineTheme.amberAlert : AlpineTheme.forestMint).opacity(0.2),
                        in: Capsule()
                    )
                    .foregroundStyle(activeSummary.liftHoldRisk == "High" ? AlpineTheme.amberAlert : AlpineTheme.forestMint)
            }

            Text(activeSummary.headline)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private func alertsSection(_ alerts: [NWSAlert]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(alerts) { alert in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation {
                            expandedAlertId = (expandedAlertId == alert.id) ? nil : alert.id
                        }
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AlpineTheme.amberAlert)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.event.uppercased())
                                    .font(.caption.bold())
                                    .foregroundStyle(AlpineTheme.amberAlert)
                                Text(alert.headline)
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: expandedAlertId == alert.id ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)

                    if expandedAlertId == alert.id {
                        Text(alert.description)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.top, 4)
                    }
                }
                .padding(12)
                .background(AlpineTheme.amberAlert.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AlpineTheme.amberAlert.opacity(0.45), lineWidth: 1)
                )
            }
        }
    }

    private func liveSensorsSection(
        _ readings: [MountainObservationReading],
        snowReport: ResortSnowReport?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live Mountain & Station Sensors", systemImage: "sensor.tag.radiowaves.forward.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("Real-Time")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AlpineTheme.forestMint.opacity(0.2), in: Capsule())
                    .foregroundStyle(AlpineTheme.forestMint)
            }

            if readings.contains(where: \.isOnMountainSensor) {
                Text("On-mountain sensor readings calibrate near-term (0–18h) temperatures and ML weights.")
                    .font(.caption2)
                    .foregroundStyle(AlpineTheme.iceCyan.opacity(0.85))
            }

            ForEach(readings) { reading in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(reading.sourceName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(reading.isOnMountainSensor ? "On-Mountain" : "Nearby NWS")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (reading.isOnMountainSensor ? AlpineTheme.iceCyan : .white).opacity(0.14),
                                    in: Capsule()
                                )
                                .foregroundStyle(reading.isOnMountainSensor ? AlpineTheme.iceCyan : .white.opacity(0.7))
                        }
                        if let elev = reading.elevationFt {
                            Text("Elevation: \(SnowFormatting.formatElevation(elev)) · \(reading.observedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(SnowFormatting.formatTemp(reading.tempF, unit: appState.tempUnit))
                            .font(.headline.bold().monospacedDigit())
                            .foregroundStyle(AlpineTheme.iceCyan)
                        if let wind = reading.windMph {
                            Text(SnowFormatting.formatWind(wind))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                .padding(10)
                .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
            }

            if let snowReport {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(snowReport.sourceName)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        Text("Observed Snowfall")
                            .font(.caption2)
                            .foregroundStyle(AlpineTheme.powderBlue)
                    }
                    HStack(spacing: 12) {
                        if let s24 = snowReport.snow24hIn {
                            snowReportPill(label: "24h", inches: s24)
                        }
                        if let s48 = snowReport.snow48hIn {
                            snowReportPill(label: "48h", inches: s48)
                        }
                        if let s7 = snowReport.snow7dIn {
                            snowReportPill(label: "7-Day", inches: s7)
                        }
                        if let season = snowReport.seasonTotalIn {
                            snowReportPill(label: "Season", inches: season)
                        }
                    }
                }
                .padding(10)
                .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func snowReportPill(label: String, inches: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            Text(SnowFormatting.formatSnow(inches, unit: appState.snowUnit))
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.headline.bold().monospacedDigit())
                .foregroundStyle(AlpineTheme.iceCyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    private var elevationPicker: some View {
        Picker("Elevation Band", selection: $selectedBand) {
            ForEach(ElevationBand.allCases) { band in
                Text("\(band.label) (\(mountain.elevations.feet(for: band))')").tag(band)
            }
        }
        .pickerStyle(.segmented)
    }

    private func dailySnowSection(_ forecast: MountainForecastResponse) -> some View {
        let maxSnow = max(2.0, forecast.daily.map(\.snowIn).max() ?? 2.0)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("7-Day Blended Snowfall", systemImage: "calendar")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(forecast.isLiveWeather ? "Live Multi-Model" : "Cached Offline")
                    .font(.caption2)
                    .foregroundStyle(forecast.isLiveWeather ? AlpineTheme.forestMint : AlpineTheme.amberAlert)
            }

            ForEach(forecast.daily) { day in
                VStack(spacing: 6) {
                    HStack {
                        Text(SnowFormatting.shortDayLabel(from: day.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 78, alignment: .leading)

                        Text(day.condition)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)

                        Spacer()

                        Text("\(SnowFormatting.formatTemp(day.tempLowF, unit: appState.tempUnit)) / \(SnowFormatting.formatTemp(day.tempHighF, unit: appState.tempUnit))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))

                        Text(SnowFormatting.formatSnow(day.snowIn, unit: appState.snowUnit))
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(day.snowIn >= 2.0 ? AlpineTheme.iceCyan : .white)
                            .frame(width: 58, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [AlpineTheme.powderBlue, AlpineTheme.iceCyan],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(4, geo.size.width * min(1.0, day.snowIn / maxSnow)))
                            }
                        }
                        .frame(height: 8)

                        Text("P10–90: \(SnowFormatting.formatSnowRange(p10: day.snowP10In, p90: day.snowP90In, unit: appState.snowUnit))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    HStack {
                        if day.slrRatio > 0 {
                            Text("Ratio \(Int(round(day.slrRatio))):1")
                        }
                        Text("Gusts \(SnowFormatting.formatWind(day.windGustMph))")
                        Spacer()
                        Text("PoP \(day.precipProbPct)%")
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 6)
                Divider().overlay(Color.white.opacity(0.08))
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func hourlyTimelineSection(_ forecast: MountainForecastResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Next 72 Hours (ML + 850mb Physics)", systemImage: "clock")
                .font(.headline)
                .foregroundStyle(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(forecast.hourly.prefix(72)) { hr in
                        VStack(spacing: 5) {
                            Text(SnowFormatting.shortMonthDayLabel(from: hr.time))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(AlpineTheme.powderBlue)

                            Text(SnowFormatting.shortHourLabel(from: hr.time))
                                .font(.caption2.bold())
                                .foregroundStyle(.white.opacity(0.75))

                            Image(systemName: iconForPrecip(hr.precipType))
                                .foregroundStyle(
                                    hr.warmNoseRisk ? AlpineTheme.amberAlert :
                                        (hr.precipType == "Snow" ? AlpineTheme.iceCyan : (hr.precipType == "Mix" ? AlpineTheme.amberAlert : .white.opacity(0.6)))
                                )

                            Text(SnowFormatting.formatSnow(hr.snowIn, unit: appState.snowUnit, decimals: 2))
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(hr.snowIn >= 0.1 ? AlpineTheme.iceCyan : .white.opacity(0.75))

                            Text(SnowFormatting.formatTemp(hr.tempF, unit: appState.tempUnit))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)

                            if let wb = hr.wetBulbF {
                                Text("WB \(SnowFormatting.formatTemp(wb, unit: appState.tempUnit))")
                                    .font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                            }

                            if let fl = hr.freezingLevelFt {
                                Text("FL \(fl)'")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func meteorologistSection(_ discussion: MeteorologistDiscussion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Local Meteorologist Take", systemImage: "text.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(discussion.wfoId)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AlpineTheme.forestMint.opacity(0.2), in: Capsule())
                    .foregroundStyle(AlpineTheme.forestMint)
            }

            Text(discussion.wfoName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))

            if !discussion.plainEnglishTakeaways.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SKIER TRANSLATION")
                        .font(.caption2.bold())
                        .foregroundStyle(AlpineTheme.iceCyan)
                    ForEach(discussion.plainEnglishTakeaways, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundStyle(AlpineTheme.powderBlue)
                            Text(bullet)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10))
            }

            ForEach(discussion.highlights.prefix(3)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.category.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(AlpineTheme.powderBlue)
                    Text(item.summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10))
            }

            Button {
                showFullDiscussion = true
            } label: {
                HStack {
                    Text("Read Full NWS Area Forecast Discussion")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(AlpineTheme.powderBlue)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func iconForPrecip(_ precipType: String) -> String {
        switch precipType {
        case "Snow": return "snowflake"
        case "Mix": return "cloud.sleet.fill"
        case "Rain": return "cloud.rain.fill"
        default: return "cloud.fill"
        }
    }
}
