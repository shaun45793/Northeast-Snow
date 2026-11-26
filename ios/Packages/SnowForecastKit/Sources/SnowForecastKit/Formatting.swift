import Foundation

public enum SnowFormatting {
    public static func formatSnow(_ inches: Double, unit: SnowUnit, decimals: Int = 1) -> String {
        switch unit {
        case .inches:
            return String(format: "%.\(decimals)f\"", inches)
        case .centimeters:
            let cm = inches * 2.54
            return String(format: "%.0f cm", cm)
        }
    }

    public static func formatSnowRange(p10: Double, p90: Double, unit: SnowUnit) -> String {
        switch unit {
        case .inches:
            return String(format: "%.1f–%.1f\"", p10, p90)
        case .centimeters:
            return String(format: "%.0f–%.0f cm", p10 * 2.54, p90 * 2.54)
        }
    }

    public static func formatTemp(_ fahrenheit: Double, unit: TemperatureUnit) -> String {
        switch unit {
        case .fahrenheit:
            return "\(Int(round(fahrenheit)))°F"
        case .celsius:
            let c = (fahrenheit - 32.0) * 5.0 / 9.0
            return "\(Int(round(c)))°C"
        }
    }

    public static func formatWind(_ mph: Double) -> String {
        "\(Int(round(mph))) mph"
    }

    public static func formatElevation(_ feet: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let num = formatter.string(from: NSNumber(value: feet)) ?? "\(feet)"
        return "\(num) ft"
    }

    public static func formatPercent(_ weight: Double) -> String {
        "\(Int(round(weight * 100)))%"
    }

    public static func shortDayLabel(from dateString: String) -> String {
        let input = DateFormatter()
        input.dateFormat = "yyyy-MM-dd"
        input.locale = Locale(identifier: "en_US_POSIX")
        guard let date = input.date(from: dateString) else { return dateString }

        let output = DateFormatter()
        output.dateFormat = "EEE M/d"
        return output.string(from: date)
    }

    public static func shortHourLabel(from date: Date) -> String {
        let output = DateFormatter()
        output.dateFormat = "ha"
        return output.string(from: date).lowercased()
    }

    public static func shortMonthDayLabel(from date: Date) -> String {
        let output = DateFormatter()
        output.dateFormat = "EEE M/d"
        return output.string(from: date)
    }
}
