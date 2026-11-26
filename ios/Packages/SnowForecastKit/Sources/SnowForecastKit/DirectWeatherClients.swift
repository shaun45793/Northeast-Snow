import Foundation

public struct RawModelHour: Sendable {
    public var tempF: Double?
    public var relativeHumidityPct: Double?
    public var temp850hpaF: Double?
    public var temp700hpaF: Double?
    public var precipIn: Double?
    public var snowfallIn: Double?
    public var windMph: Double?
    public var windGustMph: Double?
    public var windDirectionDeg: Double?
    public var freezingLevelFt: Double?
    public var precipProbPct: Double?
}

public struct OpenMeteoBundle: Sendable {
    public let times: [Date]
    public let models: [String: [RawModelHour]]
    public let gridElevationFt: Int?
}

public struct NWSGridForecast: Sendable {
    public let times: [Date]
    public let hours: [RawModelHour]
    public let gridElevationFt: Int?
    public let wfoId: String
}

public final class DirectOpenMeteoClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchMultiModelForecast(
        mountain: ExportedMountain,
        elevationFt: Int,
        modelMap: [String: String],
        forecastDays: Int = 7
    ) async -> OpenMeteoBundle? {
        let elevationM = Int(round(Double(elevationFt) * 0.3048))
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(mountain.latitude)),
            URLQueryItem(name: "longitude", value: String(mountain.longitude)),
            URLQueryItem(name: "elevation", value: String(elevationM)),
            URLQueryItem(name: "models", value: modelMap.values.sorted().joined(separator: ",")),
            URLQueryItem(
                name: "hourly",
                value: "temperature_2m,relative_humidity_2m,temperature_850hPa,temperature_700hPa,precipitation,snowfall,wind_speed_10m,wind_gusts_10m,wind_direction_10m,freezing_level_height,precipitation_probability"
            ),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "precipitation_unit", value: "inch"),
            URLQueryItem(name: "timezone", value: "UTC"),
            URLQueryItem(name: "forecast_days", value: String(forecastDays)),
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hourly = json["hourly"] as? [String: Any],
                  let rawTimes = hourly["time"] as? [String]
            else { return nil }

            let units = json["hourly_units"] as? [String: String] ?? [:]
            let times = rawTimes.compactMap { parseUTCDate($0) }
            guard !times.isEmpty else { return nil }

            var modelsOut: [String: [RawModelHour]] = [:]
            for (sourceKey, omModel) in modelMap {
                let tempKey = hourly["temperature_2m_\(omModel)"] != nil ? "temperature_2m_\(omModel)" : "temperature_2m"
                let rhKey = hourly["relative_humidity_2m_\(omModel)"] != nil ? "relative_humidity_2m_\(omModel)" : "relative_humidity_2m"
                let t850Key = hourly["temperature_850hPa_\(omModel)"] != nil ? "temperature_850hPa_\(omModel)" : "temperature_850hPa"
                let t700Key = hourly["temperature_700hPa_\(omModel)"] != nil ? "temperature_700hPa_\(omModel)" : "temperature_700hPa"
                let precipKey = hourly["precipitation_\(omModel)"] != nil ? "precipitation_\(omModel)" : "precipitation"
                let snowKey = hourly["snowfall_\(omModel)"] != nil ? "snowfall_\(omModel)" : "snowfall"
                let windKey = hourly["wind_speed_10m_\(omModel)"] != nil ? "wind_speed_10m_\(omModel)" : "wind_speed_10m"
                let gustKey = hourly["wind_gusts_10m_\(omModel)"] != nil ? "wind_gusts_10m_\(omModel)" : "wind_gusts_10m"
                let dirKey = hourly["wind_direction_10m_\(omModel)"] != nil ? "wind_direction_10m_\(omModel)" : "wind_direction_10m"
                let flKey = hourly["freezing_level_height_\(omModel)"] != nil ? "freezing_level_height_\(omModel)" : "freezing_level_height"
                let popKey = hourly["precipitation_probability_\(omModel)"] != nil ? "precipitation_probability_\(omModel)" : "precipitation_probability"

                if hourly[tempKey] == nil && hourly[precipKey] == nil {
                    continue
                }

                let temps = doubleArray(hourly[tempKey])
                let rhs = doubleArray(hourly[rhKey])
                let t850s = doubleArray(hourly[t850Key])
                let t700s = doubleArray(hourly[t700Key])
                let precips = doubleArray(hourly[precipKey])
                let snows = doubleArray(hourly[snowKey])
                let winds = doubleArray(hourly[windKey])
                let gusts = doubleArray(hourly[gustKey])
                let dirs = doubleArray(hourly[dirKey])
                let fls = doubleArray(hourly[flKey])
                let pops = doubleArray(hourly[popKey])

                let snowUnit = (units[snowKey] ?? units["snowfall"] ?? "cm").lowercased()
                let precipUnit = (units[precipKey] ?? units["precipitation"] ?? "inch").lowercased()
                let flUnit = (units[flKey] ?? units["freezing_level_height"] ?? "m").lowercased()

                var series: [RawModelHour] = []
                series.reserveCapacity(times.count)
                for i in 0..<times.count {
                    var p = i < precips.count ? precips[i] : nil
                    if let pv = p, precipUnit.hasPrefix("mm") {
                        p = pv / 25.4
                    }
                    var s = i < snows.count ? snows[i] : nil
                    if let sv = s, snowUnit.hasPrefix("cm") {
                        s = sv * 0.393701
                    }
                    var fl = i < fls.count ? fls[i] : nil
                    if let flv = fl, (flUnit == "m" || flUnit.hasPrefix("meter")) {
                        fl = flv * 3.28084
                    }

                    series.append(
                        RawModelHour(
                            tempF: i < temps.count ? temps[i] : nil,
                            relativeHumidityPct: i < rhs.count ? rhs[i] : nil,
                            temp850hpaF: i < t850s.count ? t850s[i] : nil,
                            temp700hpaF: i < t700s.count ? t700s[i] : nil,
                            precipIn: p,
                            snowfallIn: s,
                            windMph: i < winds.count ? winds[i] : nil,
                            windGustMph: i < gusts.count ? gusts[i] : nil,
                            windDirectionDeg: i < dirs.count ? dirs[i] : nil,
                            freezingLevelFt: fl,
                            precipProbPct: i < pops.count ? pops[i] : nil
                        )
                    )
                }
                modelsOut[sourceKey] = series
            }

            let elevM = json["elevation"] as? Double
            let gridElevFt = elevM.map { Int(round($0 * 3.28084)) }
            return modelsOut.isEmpty ? nil : OpenMeteoBundle(times: times, models: modelsOut, gridElevationFt: gridElevFt)
        } catch {
            return nil
        }
    }

    /// Fetches the past 48 hours of hourly actual/analysis temperature & snowfall for on-device ML verification.
    public func fetchRecentActuals(
        mountain: ExportedMountain,
        elevationFt: Int
    ) async -> [(time: Date, tempF: Double, snowIn: Double)] {
        let elevationM = Int(round(Double(elevationFt) * 0.3048))
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(mountain.latitude)),
            URLQueryItem(name: "longitude", value: String(mountain.longitude)),
            URLQueryItem(name: "elevation", value: String(elevationM)),
            URLQueryItem(name: "past_days", value: "2"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "hourly", value: "temperature_2m,snowfall"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "precipitation_unit", value: "inch"),
            URLQueryItem(name: "timezone", value: "UTC"),
        ]
        guard let url = components?.url else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hourly = json["hourly"] as? [String: Any],
                  let rawTimes = hourly["time"] as? [String]
            else { return [] }

            let units = json["hourly_units"] as? [String: String] ?? [:]
            let snowUnit = (units["snowfall"] ?? "cm").lowercased()
            let temps = doubleArray(hourly["temperature_2m"])
            let snows = doubleArray(hourly["snowfall"])
            let now = Date()

            var out: [(Date, Double, Double)] = []
            for (idx, tStr) in rawTimes.enumerated() {
                guard let dt = parseUTCDate(tStr),
                      dt < now.addingTimeInterval(-1800),
                      idx < temps.count,
                      let t = temps[idx]
                else { continue }
                var s = (idx < snows.count ? snows[idx] : nil) ?? 0.0
                if snowUnit.hasPrefix("cm") {
                    s *= 0.393701
                }
                out.append((dt, t, max(0.0, s)))
            }
            return out
        } catch {
            return []
        }
    }

    private func doubleArray(_ value: Any?) -> [Double?] {
        guard let arr = value as? [Any] else { return [] }
        return arr.map { elem in
            if let d = elem as? Double { return d }
            if let i = elem as? Int { return Double(i) }
            return nil
        }
    }

    private func parseUTCDate(_ raw: String) -> Date? {
        let f1 = DateFormatter()
        f1.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f1.timeZone = TimeZone(secondsFromGMT: 0)
        f1.locale = Locale(identifier: "en_US_POSIX")
        if let d = f1.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}

public actor DirectNWSClient {
    private let session: URLSession
    private let userAgent = "NortheastSnowForecast/1.0 (ios-on-device)"
    private var pointsCache: [String: String] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchHourlyForecast(for mountain: ExportedMountain) async -> NWSGridForecast? {
        do {
            let hourlyURLString = try await resolveHourlyURL(lat: mountain.latitude, lon: mountain.longitude)
            guard let hourlyURL = URL(string: hourlyURLString) else { return nil }
            let data = try await get(hourlyURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = json["properties"] as? [String: Any],
                  let periods = props["periods"] as? [[String: Any]]
            else { return nil }

            let elevMeters = (props["elevation"] as? [String: Any])?["value"] as? Double
            let gridElevFt = elevMeters.map { Int(round($0 * 3.28084)) }

            let iso = ISO8601DateFormatter()
            var times: [Date] = []
            var hours: [RawModelHour] = []

            for p in periods {
                guard let start = p["startTime"] as? String,
                      let dt = iso.date(from: start)
                else { continue }

                var temp: Double?
                if let t = p["temperature"] as? Double {
                    temp = t
                } else if let t = p["temperature"] as? Int {
                    temp = Double(t)
                }
                if (p["temperatureUnit"] as? String) == "C", let t = temp {
                    temp = (t * 9.0 / 5.0) + 32.0
                }

                let pop = ((p["probabilityOfPrecipitation"] as? [String: Any])?["value"] as? Double)
                    ?? (((p["probabilityOfPrecipitation"] as? [String: Any])?["value"] as? Int).map(Double.init))
                let rh = ((p["relativeHumidity"] as? [String: Any])?["value"] as? Double)
                    ?? (((p["relativeHumidity"] as? [String: Any])?["value"] as? Int).map(Double.init))
                let shortFc = ((p["shortForecast"] as? String) ?? "").lowercased()
                let windMph = parseWindMph(p["windSpeed"] as? String)

                var estPrecip: Double?
                if let pop, pop >= 20 {
                    if shortFc.contains("heavy") {
                        estPrecip = 0.12 * (pop / 100.0)
                    } else if shortFc.contains("snow") || shortFc.contains("rain") || shortFc.contains("showers") || shortFc.contains("sleet") {
                        estPrecip = 0.04 * (pop / 100.0)
                    } else {
                        estPrecip = 0.0
                    }
                }

                var estSnow: Double?
                if let estPrecip {
                    if shortFc.contains("snow") || shortFc.contains("flurr") {
                        let ratio = (temp ?? 30.0) <= 28.0 ? 12.0 : 8.0
                        estSnow = estPrecip * ratio
                    } else {
                        estSnow = 0.0
                    }
                }

                times.append(dt)
                hours.append(
                    RawModelHour(
                        tempF: temp,
                        relativeHumidityPct: rh,
                        precipIn: estPrecip,
                        snowfallIn: estSnow,
                        windMph: windMph,
                        precipProbPct: pop
                    )
                )
            }

            return times.isEmpty ? nil : NWSGridForecast(times: times, hours: hours, gridElevationFt: gridElevFt, wfoId: mountain.nwsWfo)
        } catch {
            return nil
        }
    }

    public func fetchActiveAlerts(lat: Double, lon: Double) async -> [NWSAlert] {
        let point = String(format: "%.4f,%.4f", lat, lon)
        guard let url = URL(string: "https://api.weather.gov/alerts/active?point=\(point)") else {
            return []
        }
        do {
            let data = try await get(url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let features = json["features"] as? [[String: Any]]
            else { return [] }

            let iso = ISO8601DateFormatter()
            return features.compactMap { feature -> NWSAlert? in
                guard let props = feature["properties"] as? [String: Any],
                      let event = props["event"] as? String
                else { return nil }
                let id = (props["id"] as? String) ?? UUID().uuidString
                let severity = (props["severity"] as? String) ?? "Moderate"
                let headline = (props["headline"] as? String) ?? event
                let description = (props["description"] as? String) ?? ""
                let expires = (props["expires"] as? String).flatMap { iso.date(from: $0) }
                return NWSAlert(
                    id: id,
                    event: event,
                    severity: severity,
                    headline: headline,
                    description: description,
                    expires: expires
                )
            }
        } catch {
            return []
        }
    }

    public func fetchLatestDiscussion(
        wfo: ExportedWFO,
        coveredMountainIds: [String]
    ) async -> MeteorologistDiscussion? {
        guard let listURL = URL(string: "https://api.weather.gov/products/types/AFD/locations/\(wfo.id)") else {
            return nil
        }
        do {
            let listData = try await get(listURL)
            guard let listJson = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
                  let graph = listJson["@graph"] as? [[String: Any]],
                  let first = graph.first,
                  let prodId = first["id"] as? String
            else { return nil }

            let prodURLString = (first["@id"] as? String) ?? "https://api.weather.gov/products/\(prodId)"
            guard let prodURL = URL(string: prodURLString) else { return nil }

            let prodData = try await get(prodURL)
            guard let prodJson = try JSONSerialization.jsonObject(with: prodData) as? [String: Any],
                  let rawText = prodJson["productText"] as? String
            else { return nil }

            let iso = ISO8601DateFormatter()
            let issuedAt = (prodJson["issuanceTime"] as? String).flatMap { iso.date(from: $0) } ?? Date()

            return SwiftAFDParser.buildDiscussion(
                wfo: wfo,
                productId: prodId,
                issuedAt: issuedAt,
                rawText: rawText,
                coveredMountainIds: coveredMountainIds,
                isLive: true
            )
        } catch {
            return nil
        }
    }

    private func resolveHourlyURL(lat: Double, lon: Double) async throws -> String {
        let key = String(format: "%.4f,%.4f", lat, lon)
        if let cached = pointsCache[key] { return cached }

        guard let url = URL(string: "https://api.weather.gov/points/\(key)") else {
            throw URLError(.badURL)
        }
        let data = try await get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = json["properties"] as? [String: Any],
              let hourlyURL = props["forecastHourly"] as? String
        else { throw URLError(.cannotParseResponse) }

        pointsCache[key] = hourlyURL
        return hourlyURL
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/geo+json, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func parseWindMph(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let nums = raw.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard !nums.isEmpty else { return nil }
        return nums.reduce(0.0, +) / Double(nums.count)
    }
}

// MARK: - Regional Northeast Ski Weather & MWOBS Client

public final class RegionalForecasterClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchRegionalPosts() async -> [RegionalForecastPost] {
        async let singleChairTask = fetchRSSFeed(
            urlString: "https://madriverglenweather.blogspot.com/feeds/posts/default?alt=rss",
            sourceName: "Single Chair Weather Blog",
            author: "Josh Fox"
        )
        async let mwobsTask = fetchMWOBSHigherSummits()

        let (singleChair, mwobs) = await (singleChairTask, mwobsTask)
        var posts: [RegionalForecastPost] = []
        if let mwobs { posts.append(mwobs) }
        posts.append(contentsOf: singleChair.prefix(3))
        return posts.sorted { $0.publishedAt > $1.publishedAt }
    }

    private func fetchMWOBSHigherSummits() async -> RegionalForecastPost? {
        guard let url = URL(string: "https://mountwashington.org/weather/higher-summits-forecast/") else {
            return nil
        }
        do {
            var req = URLRequest(url: url)
            req.setValue("NortheastSnowForecast/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let text = stripHTML(html)
            // Extract concise excerpt around Higher Summits / Today / Tonight
            let excerpt: String
            if let range = text.range(of: "Today:", options: .caseInsensitive) ?? text.range(of: "Tonight:", options: .caseInsensitive) {
                let tail = String(text[range.lowerBound...].prefix(420))
                excerpt = tail.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
            } else {
                excerpt = "Live Mt. Washington Observatory summit forecast for the Presidential & White Mountain peaks (6,288 ft)."
            }
            return RegionalForecastPost(
                id: "mwobs-higher-summits",
                sourceName: "Mt. Washington Observatory",
                author: "MWOBS Weather Observers",
                title: "Higher Summits Forecast (White Mountains)",
                summary: excerpt,
                publishedAt: Date(),
                urlString: url.absoluteString,
                isLive: true
            )
        } catch {
            return nil
        }
    }

    private func fetchRSSFeed(urlString: String, sourceName: String, author: String) async -> [RegionalForecastPost] {
        guard let url = URL(string: urlString) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return []
            }
            let parser = SimpleRSSParser(sourceName: sourceName, defaultAuthor: author)
            return parser.parse(data: data)
        } catch {
            return []
        }
    }

    private func stripHTML(_ raw: String) -> String {
        let noScripts = raw.replacingOccurrences(of: "(?is)<(script|style).*?>.*?</\\1>", with: " ", options: .regularExpression)
        let noTags = noScripts.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SimpleRSSParser: NSObject, XMLParserDelegate {
    private let sourceName: String
    private let defaultAuthor: String
    private var posts: [RegionalForecastPost] = []
    private var currentElement = ""
    private var inItem = false
    private var title = ""
    private var link = ""
    private var itemSummary = ""
    private var pubDate = ""

    init(sourceName: String, defaultAuthor: String) {
        self.sourceName = sourceName
        self.defaultAuthor = defaultAuthor
    }

    func parse(data: Data) -> [RegionalForecastPost] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return posts
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        if currentElement == "item" || currentElement == "entry" {
            inItem = true
            title = ""
            link = ""
            itemSummary = ""
            pubDate = ""
        } else if inItem, currentElement == "link", let href = attributeDict["href"], link.isEmpty {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch currentElement {
        case "title": title += string
        case "link": link += string
        case "description", "summary", "content": itemSummary += string
        case "pubdate", "published", "updated": pubDate += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let lower = elementName.lowercased()
        if lower == "item" || lower == "entry" {
            inItem = false
            let cleanSummary = itemSummary
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = cleanSummary.count > 260 ? String(cleanSummary.prefix(257)) + "..." : cleanSummary
            let date = parseRSSDate(pubDate.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty {
                posts.append(
                    RegionalForecastPost(
                        id: "\(sourceName)-\(cleanTitle.prefix(30))",
                        sourceName: sourceName,
                        author: defaultAuthor,
                        title: cleanTitle,
                        summary: clipped,
                        publishedAt: date,
                        urlString: link.trimmingCharacters(in: .whitespacesAndNewlines),
                        isLive: true
                    )
                )
            }
        }
    }

    private func parseRSSDate(_ str: String) -> Date? {
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = rfc822.date(from: str) { return d }
        return ISO8601DateFormatter().date(from: str)
    }
}

// MARK: - NWS AFD Parser & Plain-English Skier Translator

public enum SwiftAFDParser {
    private static let categoryKeywords: [(String, [String])] = [
        ("Snow & Upslope", ["snow", "upslope", "flurries", "squall", "accumulation", "inch", "dendritic", "slr", "ratio", "orographic", "green mountain", "white mountain", "adirondack", "lake effect"]),
        ("Temp & Freezing Level", ["freezing level", "snow level", "sleet", "freezing rain", "mixed", "mix", "warm nose", "850", "925", "cold air", "temperature", "elevation"]),
        ("Wind & Hold Risk", ["wind", "gust", "ridgetop", "wind chill", "blowing snow", "lift hold", "advisory", "gale"]),
        ("Confidence & Models", ["confidence", "uncertain", "ensemble", "ecmwf", "gfs", "nam", "hrrr", "nwp", "spread", "cluster", "consensus", "trending"]),
    ]

    public static func buildDiscussion(
        wfo: ExportedWFO,
        productId: String,
        issuedAt: Date,
        rawText: String,
        coveredMountainIds: [String],
        isLive: Bool
    ) -> MeteorologistDiscussion {
        let sections = parseSections(rawText)
        let highlights = extractHighlights(sections: sections)
        let takeaways = plainEnglishTakeaways(from: sections, highlights: highlights)
        let forecaster = extractForecaster(rawText)

        let summary: String
        if !highlights.isEmpty {
            summary = highlights.prefix(2).map(\.summary).joined(separator: " ")
        } else {
            let fallback = sections["SYNOPSIS"] ?? sections["SHORT TERM"] ?? "See full National Weather Service discussion below."
            summary = fallback.count > 320 ? String(fallback.prefix(317)) + "..." : fallback
        }

        return MeteorologistDiscussion(
            wfoId: wfo.id,
            wfoName: wfo.name,
            issuedAt: issuedAt,
            forecaster: forecaster,
            productId: productId,
            mountainRelevanceSummary: summary,
            plainEnglishTakeaways: takeaways,
            highlights: highlights,
            synopsis: sections["SYNOPSIS"],
            shortTerm: sections["SHORT TERM"] ?? sections["NEAR TERM"],
            longTerm: sections["LONG TERM"],
            rawText: rawText,
            coveredMountainIds: coveredMountainIds,
            isLive: isLive
        )
    }

    public static func plainEnglishTakeaways(
        from sections: [String: String],
        highlights: [MeteorologistHighlight]
    ) -> [String] {
        let text = [sections["SYNOPSIS"], sections["SHORT TERM"], sections["NEAR TERM"], sections["LONG TERM"]]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        var bullets: [String] = []

        if text.contains("upslope") || text.contains("orographic") {
            bullets.append("Mountain Enhancement: Northwest upslope flow favors extra snowfall along upper west-facing ridges compared to valley towns.")
        } else if text.contains("coastal") || text.contains("nor'easter") || text.contains("miller") {
            bullets.append("Storm Track Watch: A coastal low-pressure system is driving the main precipitation window—small track shifts will swing snow totals.")
        } else if text.contains("clipper") || text.contains("trough") {
            bullets.append("Fast-Moving System: An upper trough/clipper brings lighter, quick-hitting snow showers rather than a multi-day storm.")
        }

        if text.contains("warm nose") || text.contains("sleet") || text.contains("freezing rain") || text.contains("mixed") {
            bullets.append("Elevation Split / Ice Risk: Warmer air aloft could create sleet or mixed precip at base/mid elevations while summits stay snowier.")
        } else if text.contains("dendritic") || text.contains("15:1") || text.contains("high ratio") || text.contains("fluffy") {
            bullets.append("Snow Quality: Cold air in the snow-growth zone supports light, fluffy powder with higher snow-to-liquid ratios.")
        }

        if text.contains("gust") && (text.contains("35") || text.contains("40") || text.contains("45") || text.contains("50") || text.contains("ridgetop")) {
            bullets.append("Wind Hold Watch: Strong ridgetop gusts may affect exposed summit lifts and scour open trails.")
        } else if text.contains("high confidence") || text.contains("good agreement") {
            bullets.append("Forecaster Confidence: Weather models are in solid agreement on the near-term timing and temperature profile.")
        } else if text.contains("spread") || text.contains("uncertain") || text.contains("diverg") {
            bullets.append("Model Disagreement: Forecasters note spread between global models beyond Day 3—expect forecast adjustments.")
        }

        if bullets.isEmpty, let first = highlights.first {
            bullets.append(first.summary)
        }
        return Array(bullets.prefix(3))
    }

    public static func parseSections(_ rawText: String) -> [String: String] {
        let pattern = #"^\.(SYNOPSIS|NEAR TERM|SHORT TERM|LONG TERM|AVIATION|MARINE|CLIMATE)\b[^.\n]*\.{0,3}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else {
            return [:]
        }
        let nsRange = NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
        let matches = regex.matches(in: rawText, range: nsRange)
        var sections: [String: String] = [:]

        for idx in 0..<matches.count {
            let m = matches[idx]
            guard let nameRange = Range(m.range(at: 1), in: rawText),
                  let matchEnd = Range(m.range, in: rawText)?.upperBound
            else { continue }
            let name = rawText[nameRange].uppercased()
            let endIdx: String.Index = {
                if idx + 1 < matches.count, let nextRange = Range(matches[idx + 1].range, in: rawText) {
                    return nextRange.lowerBound
                }
                return rawText.endIndex
            }()
            var body = String(rawText[matchEnd..<endIdx])
            if let cutoff = body.range(of: "\n&&") ?? body.range(of: "\n$$") {
                body = String(body[..<cutoff.lowerBound])
            }
            let reflowed = reflow(body)
            if !reflowed.isEmpty {
                sections[name] = reflowed
            }
        }
        return sections
    }

    private static func reflow(_ text: String) -> String {
        let blocks = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
        return blocks
            .map { block in
                block.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func extractHighlights(sections: [String: String], maxPerCategory: Int = 2) -> [MeteorologistHighlight] {
        let pool = ["SYNOPSIS", "NEAR TERM", "SHORT TERM", "LONG TERM"]
            .compactMap { sections[$0] }
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard !pool.isEmpty else { return [] }

        let sentences = pool.components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 }

        var byCategory: [String: [(Int, String)]] = [:]
        for s in sentences {
            let low = s.lowercased()
            let bonus = (low.contains("mountain") || low.contains("summit") || low.contains("elev") || low.contains("inch") || low.contains("upslope")) ? 2 : 0
            var bestCat: String?
            var bestHits = 0
            for (cat, keywords) in categoryKeywords {
                let hits = keywords.filter { low.contains($0) }.count
                if hits > bestHits {
                    bestHits = hits
                    bestCat = cat
                }
            }
            if let bestCat, bestHits > 0 {
                let formatted = s.hasSuffix(".") || s.hasSuffix("!") || s.hasSuffix("?") ? s : "\(s)."
                byCategory[bestCat, default: []].append((bestHits + bonus, formatted))
            }
        }

        var result: [MeteorologistHighlight] = []
        for (cat, _) in categoryKeywords {
            let sorted = (byCategory[cat] ?? []).sorted { $0.0 > $1.0 }
            for (_, sentence) in sorted.prefix(maxPerCategory) {
                result.append(MeteorologistHighlight(category: cat, summary: sentence))
            }
        }
        return result
    }

    private static func extractForecaster(_ rawText: String) -> String? {
        let lines = rawText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.suffix(10).reversed() {
            if line == "$$" || line == "&&" { continue }
            if line.count <= 32, !line.hasPrefix("."), line.contains(where: \.isLetter) {
                return line
            }
        }
        return nil
    }
}
