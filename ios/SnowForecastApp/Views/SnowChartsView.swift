import Charts
import SnowForecastKit
import SwiftUI

struct SnowChartsView: View {
    let daily: [DailyForecastPoint]
    let hourly: [HourlyForecastPoint]
    let snowUnit: SnowUnit
    let tempUnit: TemperatureUnit

    @State private var selectedTempDayIdx: Int = 0
    @State private var tempHourSliderPos: Double = 0

    @State private var selectedPrecipDayIdx: Int = 0
    @State private var precipHourSliderPos: Double = 0

    @State private var showSpaghetti: Bool = false

    private struct ModelLinePoint: Identifiable {
        let id = UUID()
        let time: Date
        let modelName: String
        let cumulativeSnow: Double
    }

    private var snowFactor: Double {
        snowUnit == .inches ? 1.0 : 2.54
    }

    private func convertTemp(_ f: Double) -> Double {
        tempUnit == .fahrenheit ? f : (f - 32.0) * 5.0 / 9.0
    }

    private var freezingLineValue: Double {
        tempUnit == .fahrenheit ? 32.0 : 0.0
    }

    private static let easternDayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .current
        df.locale = Locale(identifier: "en_US_POSIX")
        return df
    }()

    private static let dayChipFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEE\nd"
        df.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .current
        return df
    }()

    private func hoursForDay(at index: Int) -> [HourlyForecastPoint] {
        guard index >= 0 && index < daily.count else { return [] }
        let targetDate = daily[index].date
        let matched = hourly.filter { Self.easternDayFormatter.string(from: $0.time) == targetDate }
        return matched
    }

    private func dayChipTitle(for day: DailyForecastPoint, index: Int) -> (weekday: String, dayNum: String) {
        if index == 0 {
            let parts = SnowFormatting.shortDayLabel(from: day.date).components(separatedBy: " ")
            let num = parts.last?.components(separatedBy: "/").last ?? ""
            return ("Today", num)
        }
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        input.locale = Locale(identifier: "en_US_POSIX")
        guard let d = input.date(from: day.date) else { return (day.date, "") }
        let wk = DateFormatter()
        wk.dateFormat = "EEE"
        let dn = DateFormatter()
        dn.dateFormat = "d"
        return (wk.string(from: d), dn.string(from: d))
    }

    private var spaghettiSeries: [ModelLinePoint] {
        let slice = Array(hourly.prefix(72))
        let sources = ["ml", "hrrr", "nam", "ecmwf", "gfs", "gem"]
        var running: [String: Double] = Dictionary(uniqueKeysWithValues: sources.map { ($0, 0.0) })
        var points: [ModelLinePoint] = []

        for (idx, hr) in slice.enumerated() {
            running["ml", default: 0.0] += hr.snowIn
            for src in ["hrrr", "nam", "ecmwf", "gfs", "gem"] {
                if let val = hr.sourceSnowIn[src] {
                    running[src, default: 0.0] += val
                }
            }
            if idx % 3 == 0 || idx == slice.count - 1 {
                for src in sources {
                    if src == "ml" || !(src == "hrrr" && hr.leadHours > 48) {
                        let label = src == "ml" ? "ML Blend" : src.uppercased()
                        points.append(
                            ModelLinePoint(
                                time: hr.time,
                                modelName: label,
                                cumulativeSnow: (running[src] ?? 0.0) * snowFactor
                            )
                        )
                    }
                }
            }
        }
        return points
    }

    var body: some View {
        VStack(spacing: 16) {
            temperatureCard
            precipitationCard
            spaghettiCard
        }
    }

    // MARK: - 1. Temperature Card (7-Day Summary Bars + Swipeable Day-by-Day Hourly Line Chart)

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Temperature Forecast", systemImage: "thermometer.snowflake")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("7-Day & Daily")
                    .font(.caption2.bold())
                    .foregroundStyle(AlpineTheme.powderBlue)
            }

            // A) Full 7-Day Summary Range Bar Chart (kept on page)
            if !daily.isEmpty {
                Chart {
                    RuleMark(y: .value("Freezing", freezingLineValue))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(AlpineTheme.amberAlert.opacity(0.6))

                    ForEach(Array(daily.enumerated()), id: \.element.id) { idx, day in
                        let label = SnowFormatting.shortDayLabel(from: day.date)
                        BarMark(
                            x: .value("Day", label),
                            yStart: .value("Low", convertTemp(day.tempLowF)),
                            yEnd: .value("High", convertTemp(day.tempHighF))
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AlpineTheme.powderBlue, AlpineTheme.amberAlert],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .cornerRadius(5)
                        .opacity(idx == selectedTempDayIdx ? 1.0 : 0.42)
                    }
                }
                .chartYAxisLabel(tempUnit.symbol)
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s.components(separatedBy: " ").first ?? s)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 135)
            }

            Divider().overlay(Color.white.opacity(0.08))

            // B) Apple Weather-Style Day Strip + Swipeable Day-by-Day Line Chart
            daySelectorStrip(selectedIndex: $selectedTempDayIdx) {
                tempHourSliderPos = 0
            }

            if !daily.isEmpty {
                TabView(selection: $selectedTempDayIdx) {
                    ForEach(Array(daily.enumerated()), id: \.element.id) { idx, day in
                        temperatureDayPage(day: day, hours: hoursForDay(at: idx))
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 270)
                .onChange(of: selectedTempDayIdx) { _, _ in
                    tempHourSliderPos = 0
                }
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func temperatureDayPage(day: DailyForecastPoint, hours: [HourlyForecastPoint]) -> some View {
        let clampedIdx = hours.isEmpty ? 0 : min(max(0, Int(round(tempHourSliderPos))), hours.count - 1)
        return VStack(alignment: .leading, spacing: 10) {
            if !hours.isEmpty {
                let selected = hours[clampedIdx]
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SnowFormatting.shortDayLabel(from: day.date)) · \(selected.time.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        if let fl = selected.freezingLevelFt {
                            Text("Freezing Level: \(SnowFormatting.formatElevation(fl))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(SnowFormatting.formatTemp(selected.tempF, unit: tempUnit))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(AlpineTheme.iceCyan)
                        if let wb = selected.wetBulbF {
                            Text("Wet-Bulb \(SnowFormatting.formatTemp(wb, unit: tempUnit))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                .padding(10)
                .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))

                Chart {
                    RuleMark(y: .value("Freezing", freezingLineValue))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(AlpineTheme.amberAlert.opacity(0.6))

                    ForEach(hours) { hr in
                        AreaMark(
                            x: .value("Hour", hr.time),
                            y: .value("Temp", convertTemp(hr.tempF))
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AlpineTheme.powderBlue.opacity(0.35), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Hour", hr.time),
                            y: .value("Temp", convertTemp(hr.tempF))
                        )
                        .foregroundStyle(AlpineTheme.iceCyan)
                        .lineStyle(StrokeStyle(lineWidth: 2.6))
                        .interpolationMethod(.catmullRom)
                    }

                    RuleMark(x: .value("Selected", selected.time))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(.white.opacity(0.85))

                    PointMark(
                        x: .value("Selected", selected.time),
                        y: .value("Temp", convertTemp(selected.tempF))
                    )
                    .symbolSize(75)
                    .foregroundStyle(.white)
                }
                .chartYAxisLabel(tempUnit.symbol)
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 150)

                if hours.count > 1 {
                    Slider(value: $tempHourSliderPos, in: 0...Double(hours.count - 1), step: 1)
                        .tint(AlpineTheme.iceCyan)
                }
            } else {
                VStack(spacing: 6) {
                    Text("\(SnowFormatting.shortDayLabel(from: day.date)): Low \(SnowFormatting.formatTemp(day.tempLowF, unit: tempUnit)) / High \(SnowFormatting.formatTemp(day.tempHighF, unit: tempUnit))")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Hourly breakdown unavailable for this day.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 2. Precipitation Card (7-Day Summary Bars + Swipeable Day-by-Day Hourly Line Chart)

    private var precipitationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Precipitation & Snowfall", systemImage: "cloud.snow.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text("7-Day & Daily")
                    .font(.caption2.bold())
                    .foregroundStyle(AlpineTheme.iceCyan)
            }

            // A) Full 7-Day Summary Bar Chart (kept on page)
            if !daily.isEmpty {
                Chart {
                    ForEach(Array(daily.enumerated()), id: \.element.id) { idx, day in
                        let label = SnowFormatting.shortDayLabel(from: day.date)
                        BarMark(
                            x: .value("Day", label),
                            y: .value("Snow", day.snowIn * snowFactor)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AlpineTheme.powderBlue, AlpineTheme.iceCyan],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .cornerRadius(5)
                        .opacity(idx == selectedPrecipDayIdx ? 1.0 : 0.42)

                        RuleMark(
                            x: .value("Day", label),
                            yStart: .value("P10", day.snowP10In * snowFactor),
                            yEnd: .value("P90", day.snowP90In * snowFactor)
                        )
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.white.opacity(idx == selectedPrecipDayIdx ? 0.95 : 0.4))
                    }
                }
                .chartYAxisLabel(snowUnit.symbol)
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s.components(separatedBy: " ").first ?? s)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 135)
            }

            Divider().overlay(Color.white.opacity(0.08))

            // B) Apple Weather-Style Day Strip + Swipeable Day-by-Day Hourly Line Chart
            daySelectorStrip(selectedIndex: $selectedPrecipDayIdx) {
                precipHourSliderPos = 0
            }

            if !daily.isEmpty {
                TabView(selection: $selectedPrecipDayIdx) {
                    ForEach(Array(daily.enumerated()), id: \.element.id) { idx, day in
                        precipitationDayPage(day: day, hours: hoursForDay(at: idx))
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 270)
                .onChange(of: selectedPrecipDayIdx) { _, _ in
                    precipHourSliderPos = 0
                }
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func precipitationDayPage(day: DailyForecastPoint, hours: [HourlyForecastPoint]) -> some View {
        let clampedIdx = hours.isEmpty ? 0 : min(max(0, Int(round(precipHourSliderPos))), hours.count - 1)
        return VStack(alignment: .leading, spacing: 10) {
            if !hours.isEmpty {
                let selected = hours[clampedIdx]
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SnowFormatting.shortDayLabel(from: day.date)) · \(selected.time.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text("\(selected.precipType) · Liquid \(String(format: "%.2f\"", selected.liquidPrecipIn)) · SLR \(Int(round(selected.slrRatio))):1")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(SnowFormatting.formatSnow(selected.snowIn, unit: snowUnit, decimals: 2))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(selected.precipType == "Mix" ? AlpineTheme.amberAlert : AlpineTheme.iceCyan)
                        Text("Day Total: \(SnowFormatting.formatSnow(day.snowIn, unit: snowUnit))")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(10)
                .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))

                Chart {
                    ForEach(hours) { hr in
                        AreaMark(
                            x: .value("Hour", hr.time),
                            y: .value("Snow", hr.snowIn * snowFactor)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    (hr.precipType == "Mix" ? AlpineTheme.amberAlert : AlpineTheme.iceCyan).opacity(0.4),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Hour", hr.time),
                            y: .value("Snow", hr.snowIn * snowFactor)
                        )
                        .foregroundStyle(AlpineTheme.iceCyan)
                        .lineStyle(StrokeStyle(lineWidth: 2.6))
                        .interpolationMethod(.catmullRom)
                    }

                    RuleMark(x: .value("Selected", selected.time))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(.white.opacity(0.85))

                    PointMark(
                        x: .value("Selected", selected.time),
                        y: .value("Snow", selected.snowIn * snowFactor)
                    )
                    .symbolSize(75)
                    .foregroundStyle(.white)
                }
                .chartYAxisLabel("\(snowUnit.symbol)/hr")
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 150)

                if hours.count > 1 {
                    Slider(value: $precipHourSliderPos, in: 0...Double(hours.count - 1), step: 1)
                        .tint(AlpineTheme.powderBlue)
                }
            } else {
                VStack(spacing: 6) {
                    Text("\(SnowFormatting.shortDayLabel(from: day.date)): \(SnowFormatting.formatSnow(day.snowIn, unit: snowUnit)) (\(day.condition))")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Hourly breakdown unavailable for this day.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Shared Apple Weather-Style 7-Day Selector Strip

    private func daySelectorStrip(selectedIndex: Binding<Int>, onSelect: @escaping () -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(daily.enumerated()), id: \.element.id) { idx, day in
                    let parts = dayChipTitle(for: day, index: idx)
                    let isSelected = selectedIndex.wrappedValue == idx
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedIndex.wrappedValue = idx
                            onSelect()
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text(parts.weekday)
                                .font(.caption2.bold())
                            Text(parts.dayNum)
                                .font(.caption.bold().monospacedDigit())
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? AlpineTheme.powderBlue : AlpineTheme.cardElevated,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .foregroundStyle(isSelected ? .black : .white.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: - 3. Multi-Model Spaghetti Chart

    private var spaghettiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup("72h Multi-Model Spaghetti Comparison", isExpanded: $showSpaghetti) {
                Chart(spaghettiSeries) { pt in
                    LineMark(
                        x: .value("Time", pt.time),
                        y: .value("Cumulative", pt.cumulativeSnow)
                    )
                    .foregroundStyle(by: .value("Model", pt.modelName))
                    .lineStyle(StrokeStyle(lineWidth: pt.modelName == "ML Blend" ? 3.2 : 1.6))
                    .interpolationMethod(.catmullRom)
                }
                .chartForegroundStyleScale([
                    "ML Blend": Color.white,
                    "HRRR": AlpineTheme.modelColor("hrrr"),
                    "NAM": AlpineTheme.modelColor("nam"),
                    "ECMWF": AlpineTheme.modelColor("ecmwf"),
                    "GEM": AlpineTheme.modelColor("gem"),
                    "GFS": AlpineTheme.modelColor("gfs"),
                ])
                .chartYAxisLabel("Cum. \(snowUnit.symbol)")
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                            .foregroundStyle(Color.white.opacity(0.12))
                        AxisValueLabel()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(height: 190)
                .padding(.top, 8)

                Text("Compares HRRR, NAM, ECMWF, GFS, GEM, and the adaptive ML Blend over the next 72 hours.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .tint(AlpineTheme.powderBlue)
            .font(.headline)
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
