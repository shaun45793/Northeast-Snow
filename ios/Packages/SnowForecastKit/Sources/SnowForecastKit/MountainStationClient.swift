import Foundation

public struct MountainStationPayload: Sendable {
    public let observations: [MountainObservationReading]
    public let snowReport: ResortSnowReport?

    public init(observations: [MountainObservationReading], snowReport: ResortSnowReport? = nil) {
        self.observations = observations
        self.snowReport = snowReport
    }
}

public actor MountainStationClient {
    private let session: URLSession
    private let userAgent = "NortheastSnowForecast/3.0 (ios-on-device)"
    private var cache: [String: (Date, MountainStationPayload)] = [:]
    private let cacheTTL: TimeInterval = 10 * 60

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchLiveStationData(for mountain: ExportedMountain) async -> MountainStationPayload {
        let now = Date()
        if let (ts, cached) = cache[mountain.id], now.timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        async let nwsTask = fetchNWSStationObservation(stationId: mountain.stationId, mountain: mountain)
        async let resortTask = fetchResortData(for: mountain)

        let (nwsObs, resortPayload) = await (nwsTask, resortTask)
        var readings = resortPayload.observations
        if let nwsObs {
            readings.append(nwsObs)
        }

        // Prioritize real on-mountain sensors ahead of nearby valley NWS airport stations
        readings.sort { a, b in
            if a.isOnMountainSensor != b.isOnMountainSensor {
                return a.isOnMountainSensor && !b.isOnMountainSensor
            }
            return (a.elevationFt ?? 0) > (b.elevationFt ?? 0)
        }

        let payload = MountainStationPayload(observations: readings, snowReport: resortPayload.snowReport)
        if !readings.isEmpty || resortPayload.snowReport != nil {
            cache[mountain.id] = (now, payload)
        }
        return payload
    }

    public func fetchLiveObservations(for mountain: ExportedMountain) async -> [MountainObservationReading] {
        await fetchLiveStationData(for: mountain).observations
    }

    private func fetchNWSStationObservation(
        stationId: String,
        mountain: ExportedMountain
    ) async -> MountainObservationReading? {
        guard let url = URL(string: "https://api.weather.gov/stations/\(stationId.uppercased())/observations/latest") else {
            return nil
        }
        do {
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = json["properties"] as? [String: Any],
                  let tempC = (props["temperature"] as? [String: Any])?["value"] as? Double
            else { return nil }

            let tempF = (tempC * 9.0 / 5.0) + 32.0
            let roundedTempF = (tempF * 10.0).rounded() / 10.0

            let windKmh = (props["windSpeed"] as? [String: Any])?["value"] as? Double
            let windMph = windKmh.map { (($0 * 0.621371) * 10.0).rounded() / 10.0 }
            let elevMeters = (props["elevation"] as? [String: Any])?["value"] as? Double
            let elevFt = elevMeters.map { Int(round($0 * 3.28084)) }

            let iso = ISO8601DateFormatter()
            let obsDate = (props["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? Date()

            let isSummitObservatory = stationId.uppercased() == "KMWN"
            let label = isSummitObservatory
                ? "Mt. Washington Obs (KMWN)"
                : "NWS Station \(stationId.uppercased())"

            return MountainObservationReading(
                id: "nws-\(stationId.uppercased())",
                sourceName: label,
                elevationBand: isSummitObservatory ? "summit" : "station",
                elevationFt: elevFt,
                tempF: roundedTempF,
                windMph: windMph,
                observedAt: obsDate,
                isOnMountainSensor: isSummitObservatory
            )
        } catch {
            return nil
        }
    }

    private func fetchResortData(for mountain: ExportedMountain) async -> MountainStationPayload {
        switch mountain.id {
        case "killington":
            return await fetchKillingtonData()
        case "mad-river-glen":
            return await fetchMadRiverGlenData()
        case "jay-peak":
            return await fetchJayPeakData()
        default:
            return MountainStationPayload(observations: [])
        }
    }

    private func fetchKillingtonData() async -> MountainStationPayload {
        guard let url = URL(string: "https://killington.com/mountain-report"),
              let html = await fetchHTML(url)
        else {
            return MountainStationPayload(observations: [])
        }
        return MountainStationPayload(
            observations: Self.parseKillingtonSensors(html: html),
            snowReport: Self.parseKillingtonSnowReport(html: html)
        )
    }

    private func fetchMadRiverGlenData() async -> MountainStationPayload {
        guard let url = URL(string: "https://www.madriverglen.com/conditions/"),
              let html = await fetchHTML(url)
        else {
            return MountainStationPayload(observations: [])
        }
        return MountainStationPayload(
            observations: Self.parseMadRiverGlenSensors(html: html),
            snowReport: nil
        )
    }

    private func fetchJayPeakData() async -> MountainStationPayload {
        // Only pull verified snowfall measurements; do NOT pull website forecast temps.
        guard let url = URL(string: "https://digital.jaypeakresort.com/conditions/snow-report/snow-report/"),
              let html = await fetchHTML(url)
        else {
            return MountainStationPayload(observations: [])
        }
        return MountainStationPayload(
            observations: [],
            snowReport: Self.parseJayPeakSnowReport(html: html)
        )
    }

    private func fetchHTML(_ url: URL) async -> String? {
        do {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Verified Resort HTML Parsers

    public static func parseKillingtonSensors(html: String, now: Date = Date()) -> [MountainObservationReading] {
        // Matches <div class="dor-sensor-item...">...dor-sensor-name...optional dor-sensor-elevation...dor-sensor-temp...
        let pattern = #"<div class="dor-sensor-item[^"]*">\s*<div class="dor-sensor-name">\s*([^<]+?)\s*</div>(?:\s*<div class="dor-sensor-elevation">\s*([^<]+?)\s*</div>)?\s*<div class="dor-sensor-temp">\s*(-?\d+(?:\.\d+)?)\s*(?:&deg;|°)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var out: [MountainObservationReading] = []

        for m in matches {
            guard let nameR = Range(m.range(at: 1), in: html),
                  let tempR = Range(m.range(at: 3), in: html),
                  let temp = Double(html[tempR])
            else { continue }

            let name = html[nameR].trimmingCharacters(in: .whitespacesAndNewlines)
            var parsedElevFt: Int?
            if let elevR = Range(m.range(at: 2), in: html) {
                let digits = html[elevR].filter { $0.isNumber }
                parsedElevFt = Int(digits)
            }

            let lower = name.lowercased()
            // Exclude Bear Mountain (on the opposite side of Killington from K-1 & main Peak trails)
            if lower.contains("bear") {
                continue
            }

            let band: String
            let defaultElevFt: Int
            if lower.contains("peak") || lower.contains("summit") {
                band = "summit"
                defaultElevFt = 4241
            } else if lower.contains("k-1") || lower.contains("base") {
                band = "base"
                defaultElevFt = 2500
            } else {
                continue
            }

            out.append(
                MountainObservationReading(
                    id: "killington-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    sourceName: "\(name) Sensor",
                    elevationBand: band,
                    elevationFt: parsedElevFt ?? defaultElevFt,
                    tempF: temp,
                    observedAt: now,
                    isOnMountainSensor: true
                )
            )
        }

        if let mid = interpolateMidReading(
            id: "killington-mid-interpolated",
            sourceName: "K-1 ↔ Peak Mid (Est.)",
            midElevFt: 2700,
            readings: out,
            now: now
        ) {
            out.append(mid)
        }
        return out
    }

    private static func interpolateMidReading(
        id: String,
        sourceName: String,
        midElevFt: Int,
        readings: [MountainObservationReading],
        now: Date
    ) -> MountainObservationReading? {
        guard let base = readings.first(where: { $0.elevationBand == "base" }),
              let summit = readings.first(where: { $0.elevationBand == "summit" }),
              let baseElev = base.elevationFt,
              let sumElev = summit.elevationFt,
              sumElev > baseElev
        else { return nil }
        let t = Double(midElevFt - baseElev) / Double(sumElev - baseElev)
        let midTemp = ((base.tempF + t * (summit.tempF - base.tempF)) * 10.0).rounded() / 10.0
        return MountainObservationReading(
            id: id,
            sourceName: sourceName,
            elevationBand: "mid",
            elevationFt: midElevFt,
            tempF: midTemp,
            observedAt: now,
            isOnMountainSensor: true
        )
    }

    public static func parseKillingtonSnowReport(html: String, now: Date = Date()) -> ResortSnowReport? {
        let pattern = #"<div class="dor-snow-label">\s*([^<]+?)\s*</div>\s*<div class="dor-snow-icon">.*?</div>\s*<div class="dor-snow-val">\s*(-?\d+(?:\.\d+)?)\s*(?:&quot;|")"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var s24: Double?
        var s48: Double?
        var s7d: Double?
        var season: Double?

        for m in matches {
            guard let labelR = Range(m.range(at: 1), in: html),
                  let valR = Range(m.range(at: 2), in: html),
                  let val = Double(html[valR])
            else { continue }

            let label = html[labelR].lowercased()
            if label.contains("24") { s24 = val }
            else if label.contains("48") { s48 = val }
            else if label.contains("7 day") { s7d = val }
            else if label.contains("season") { season = val }
        }

        if s24 == nil && s48 == nil && s7d == nil && season == nil {
            return nil
        }
        return ResortSnowReport(
            sourceName: "Killington Snow Report",
            snow24hIn: s24,
            snow48hIn: s48,
            snow7dIn: s7d,
            seasonTotalIn: season,
            reportedAt: now
        )
    }

    public static func parseMadRiverGlenSensors(html: String, now: Date = Date()) -> [MountainObservationReading] {
        var out: [MountainObservationReading] = []
        let patterns: [(String, String, String, Int)] = [
            (#"Current Summit Temp:\s*<span>\s*(-?\d+(?:\.\d+)?)\s*(?:&deg;|°)?"#, "MRG Summit Sensor", "summit", 3637),
            (#"Current Base Temp:\s*<span>\s*(-?\d+(?:\.\d+)?)\s*(?:&deg;|°)?"#, "MRG Basebox Sensor", "base", 1600),
        ]
        for (pat, label, band, elevFt) in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
               let tRange = Range(match.range(at: 1), in: html),
               let temp = Double(html[tRange]) {
                out.append(
                    MountainObservationReading(
                        id: "mrg-\(band)",
                        sourceName: label,
                        elevationBand: band,
                        elevationFt: elevFt,
                        tempF: temp,
                        observedAt: now,
                        isOnMountainSensor: true
                    )
                )
            }
        }
        if let mid = interpolateMidReading(
            id: "mrg-mid-interpolated",
            sourceName: "MRG Base ↔ Summit Mid (Est.)",
            midElevFt: 2600,
            readings: out,
            now: now
        ) {
            out.append(mid)
        }
        return out
    }

    public static func parseJayPeakSnowReport(html: String, now: Date = Date()) -> ResortSnowReport? {
        let pattern = #"<dl class="SnowReport-measure">\s*<dt>\s*([^<]+?)\s*</dt>\s*<dd>\s*(-?\d+(?:\.\d+)?)\s*(?:&quot;|")"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var s24: Double?
        var s48: Double?
        var s7d: Double?
        var season: Double?

        for m in matches {
            guard let labelR = Range(m.range(at: 1), in: html),
                  let valR = Range(m.range(at: 2), in: html),
                  let val = Double(html[valR])
            else { continue }

            let label = html[labelR].lowercased()
            if label.contains("24") { s24 = val }
            else if label.contains("48") { s48 = val }
            else if label.contains("7 day") { s7d = val }
            else if label.contains("season") { season = val }
        }

        if s24 == nil && s48 == nil && s7d == nil && season == nil {
            return nil
        }
        return ResortSnowReport(
            sourceName: "Jay Peak Snow Report",
            snow24hIn: s24,
            snow48hIn: s48,
            snow7dIn: s7d,
            seasonTotalIn: season,
            reportedAt: now
        )
    }
}
