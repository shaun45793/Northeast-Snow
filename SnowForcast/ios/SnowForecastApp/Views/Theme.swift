import SwiftUI

enum AlpineTheme {
    static let background = Color(red: 0.05, green: 0.08, blue: 0.13)
    static let cardBackground = Color(red: 0.09, green: 0.13, blue: 0.20)
    static let cardElevated = Color(red: 0.13, green: 0.18, blue: 0.27)
    static let powderBlue = Color(red: 0.35, green: 0.76, blue: 0.98)
    static let iceCyan = Color(red: 0.56, green: 0.88, blue: 1.0)
    static let forestMint = Color(red: 0.28, green: 0.84, blue: 0.63)
    static let amberAlert = Color(red: 1.0, green: 0.72, blue: 0.25)

    static func modelColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "hrrr": return Color(red: 0.31, green: 0.82, blue: 0.98)
        case "nam": return Color(red: 0.45, green: 0.65, blue: 1.0)
        case "ecmwf": return Color(red: 0.32, green: 0.88, blue: 0.66)
        case "nws": return Color(red: 0.98, green: 0.75, blue: 0.28)
        case "gem": return Color(red: 0.78, green: 0.56, blue: 0.98)
        case "gfs": return Color(red: 0.96, green: 0.48, blue: 0.52)
        default: return .gray
        }
    }

    static func confidenceColor(_ confidence: String) -> Color {
        switch confidence.lowercased() {
        case "high": return forestMint
        case "moderate": return amberAlert
        default: return Color(red: 0.96, green: 0.48, blue: 0.52)
        }
    }
}
