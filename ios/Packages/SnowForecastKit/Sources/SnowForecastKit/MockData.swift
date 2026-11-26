import Foundation

public enum MockSnowData {
    public static let sampleMountains: [MountainSummary] = [
        MountainSummary(
            id: "jay-peak",
            name: "Jay Peak",
            state: "VT",
            region: "Northern Green Mountains",
            latitude: 44.9379,
            longitude: -72.5045,
            elevations: ElevationSummary(baseFt: 1815, midFt: 2800, summitFt: 3968),
            nwsWfo: "BTV",
            stationId: "KEFK",
            aspect: "NW",
            snow24hIn: 5.8,
            snow72hIn: 11.4,
            snow5dIn: 15.2,
            summitTempF: 17.0,
            summitWindMph: 26.0,
            confidence: "High",
            headline: "Storm cycle: 11.4\" over the next 72h",
            updatedAt: Date()
        ),
        MountainSummary(
            id: "stowe",
            name: "Stowe Mountain Resort",
            state: "VT",
            region: "Northern Green Mountains",
            latitude: 44.5303,
            longitude: -72.7814,
            elevations: ElevationSummary(baseFt: 1559, midFt: 2600, summitFt: 3625),
            nwsWfo: "BTV",
            stationId: "KMVL",
            aspect: "NW",
            snow24hIn: 4.9,
            snow72hIn: 9.6,
            snow5dIn: 13.1,
            summitTempF: 19.0,
            summitWindMph: 24.0,
            confidence: "High",
            headline: "Storm cycle: 9.6\" over the next 72h",
            updatedAt: Date()
        ),
        MountainSummary(
            id: "wildcat",
            name: "Wildcat Mountain",
            state: "NH",
            region: "White Mountains",
            latitude: 44.2636,
            longitude: -71.2392,
            elevations: ElevationSummary(baseFt: 1950, midFt: 3000, summitFt: 4062),
            nwsWfo: "GYX",
            stationId: "KMWN",
            aspect: "NW",
            snow24hIn: 3.4,
            snow72hIn: 7.2,
            snow5dIn: 10.4,
            summitTempF: 16.0,
            summitWindMph: 34.0,
            confidence: "Moderate",
            headline: "Storm cycle: 7.2\" over the next 72h",
            updatedAt: Date()
        ),
        MountainSummary(
            id: "sugarloaf",
            name: "Sugarloaf",
            state: "ME",
            region: "Western Maine Mountains",
            latitude: 45.0314,
            longitude: -70.3131,
            elevations: ElevationSummary(baseFt: 1417, midFt: 2800, summitFt: 4237),
            nwsWfo: "GYX",
            stationId: "KBML",
            aspect: "NNE",
            snow24hIn: 2.8,
            snow72hIn: 6.5,
            snow5dIn: 9.1,
            summitTempF: 15.0,
            summitWindMph: 29.0,
            confidence: "Moderate",
            headline: "Storm cycle: 6.5\" over the next 72h",
            updatedAt: Date()
        ),
        MountainSummary(
            id: "whiteface",
            name: "Whiteface Mountain",
            state: "NY",
            region: "Adirondacks",
            latitude: 44.3659,
            longitude: -73.9026,
            elevations: ElevationSummary(baseFt: 1220, midFt: 2800, summitFt: 4650),
            nwsWfo: "BTV",
            stationId: "KSLK",
            aspect: "ENE",
            snow24hIn: 2.1,
            snow72hIn: 5.4,
            snow5dIn: 7.8,
            summitTempF: 14.0,
            summitWindMph: 31.0,
            confidence: "Moderate",
            headline: "Accumulating snow: 7.8\" next 5 days",
            updatedAt: Date()
        ),
    ]

    public static let sampleDiscussionBTV = MeteorologistDiscussion(
        wfoId: "BTV",
        wfoName: "NWS Burlington, VT",
        issuedAt: Date(),
        forecaster: "BTV Forecast Desk",
        productId: "demo-btv-001",
        mountainRelevanceSummary: "Favorable northwest upslope flow and dendritic growth zone saturation will bring 4 to 8 inches along the northern Green Mountain spine above 2,000 ft.",
        highlights: [
            MeteorologistHighlight(
                category: "Snow & Upslope",
                summary: "Expect 15:1 snow ratios on upper slopes at Jay Peak and Stowe overnight as cold air deepens behind the frontal boundary."
            ),
            MeteorologistHighlight(
                category: "Wind & Hold Risk",
                summary: "Ridgetop wind gusts 30–38 mph late tonight could create brief exposed summit lift holds early morning."
            ),
            MeteorologistHighlight(
                category: "Confidence & Models",
                summary: "High-res HRRR and NAM align closely on 0–24h upslope totals; ECMWF/GEM favor another clipper late week."
            ),
        ],
        synopsis: "A progressive northern stream trough crosses northern New York and Vermont tonight, ushering 850mb temperatures down to -12C and setting up classic blocked northwest upslope snow.",
        shortTerm: "Snow showers intensify along the western slopes of the Green Mountains after midnight with fluffy 15:1 ratios above 2,000 feet.",
        longTerm: "Quiet and cold mid-week before ensemble clusters signal another northern stream wave by Friday.",
        rawText: "DEMO DISCUSSION FOR OFFLINE PREVIEW",
        coveredMountainIds: ["stowe", "jay-peak", "sugarbush", "mad-river-glen", "killington", "whiteface"],
        isLive: false
    )

    public static func sampleForecast(for mountain: MountainSummary, band: ElevationBand = .summit) -> MountainForecastResponse {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let daily: [DailyForecastPoint] = (0..<7).map { dayOffset in
            let date = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
            let snow = [4.8, 3.6, 1.2, 0.4, 2.9, 1.8, 0.5][dayOffset]
            return DailyForecastPoint(
                date: formatter.string(from: date),
                snowIn: snow,
                snowP10In: max(0, (snow * 0.7 * 10).rounded() / 10),
                snowP90In: (snow * 1.35 * 10).rounded() / 10,
                liquidPrecipIn: (snow / 14.0 * 100).rounded() / 100,
                slrRatio: 14.5,
                tempHighF: 23.0 - Double(band == .summit ? 4 : 0),
                tempLowF: 12.0 - Double(band == .summit ? 4 : 0),
                windMaxMph: 26.0,
                windGustMph: 37.0,
                precipProbPct: snow > 1 ? 85 : 30,
                condition: snow >= 3.5 ? "Snow" : (snow > 0.5 ? "Snow Showers" : "Cold & Dry"),
                sourceSnowIn: [
                    "hrrr": (snow * 1.1 * 10).rounded() / 10,
                    "nam": (snow * 1.02 * 10).rounded() / 10,
                    "ecmwf": (snow * 0.94 * 10).rounded() / 10,
                    "gfs": (snow * 0.85 * 10).rounded() / 10,
                    "gem": (snow * 1.04 * 10).rounded() / 10,
                    "nws": (snow * 0.98 * 10).rounded() / 10,
                ]
            )
        }

        let hourly: [HourlyForecastPoint] = (0..<168).map { hr in
            let dt = calendar.date(byAdding: .hour, value: hr, to: now) ?? now
            let wave = exp(-pow(Double(hr - 10), 2) / 48.0)
            let snow = (0.42 * wave * 100).rounded() / 100
            return HourlyForecastPoint(
                time: dt,
                leadHours: hr,
                leadBucket: OnDevicePhysics.leadBucket(forHours: hr),
                snowIn: snow,
                snowP10In: (snow * 0.7 * 100).rounded() / 100,
                snowP90In: (snow * 1.35 * 100).rounded() / 100,
                liquidPrecipIn: (snow / 14.0 * 1000).rounded() / 1000,
                tempF: 19.0 + 3.0 * sin(Double(hr) / 4.0),
                windMph: 22.0 + 6.0 * wave,
                windGustMph: 32.0 + 8.0 * wave,
                freezingLevelFt: 1200,
                slrRatio: 15.0,
                precipType: snow > 0.04 ? "Snow" : "Dry",
                sourceSnowIn: [
                    "hrrr": snow * 1.12,
                    "nam": snow * 1.03,
                    "ecmwf": snow * 0.92,
                    "gfs": snow * 0.84,
                    "gem": snow * 1.01,
                    "nws": snow * 0.97,
                ],
                sourceTempF: [
                    "hrrr": 18.5,
                    "nam": 19.0,
                    "ecmwf": 19.8,
                    "gfs": 20.6,
                    "gem": 18.2,
                    "nws": 19.2,
                ]
            )
        }

        let weights: [String: [ModelWeightRatio]] = [
            LeadBucket.short.rawValue: [
                ModelWeightRatio(source: "hrrr", displayName: "HRRR 3km", weight: 0.36, snow24hIn: 5.4, snow72hIn: 9.8, snow5dIn: nil, avgTempF: 18.5),
                ModelWeightRatio(source: "nam", displayName: "NAM 3km/12km", weight: 0.25, snow24hIn: 4.9, snow72hIn: 9.5, snow5dIn: nil, avgTempF: 19.0),
                ModelWeightRatio(source: "ecmwf", displayName: "ECMWF IFS", weight: 0.16, snow24hIn: 4.3, snow72hIn: 8.9, snow5dIn: 12.6, avgTempF: 19.8),
                ModelWeightRatio(source: "nws", displayName: "NWS Blend", weight: 0.13, snow24hIn: 4.7, snow72hIn: 9.2, snow5dIn: 12.8, avgTempF: 19.2),
                ModelWeightRatio(source: "gem", displayName: "CMC GEM", weight: 0.06, snow24hIn: 5.0, snow72hIn: 9.4, snow5dIn: 13.0, avgTempF: 18.2),
                ModelWeightRatio(source: "gfs", displayName: "NOAA GFS", weight: 0.04, snow24hIn: 3.9, snow72hIn: 8.1, snow5dIn: 11.2, avgTempF: 20.6),
            ],
            LeadBucket.medium.rawValue: [
                ModelWeightRatio(source: "ecmwf", displayName: "ECMWF IFS", weight: 0.33, snow24hIn: 4.3, snow72hIn: 8.9, snow5dIn: 12.6, avgTempF: 19.8),
                ModelWeightRatio(source: "nam", displayName: "NAM 3km/12km", weight: 0.24, snow24hIn: 4.9, snow72hIn: 9.5, snow5dIn: nil, avgTempF: 19.0),
                ModelWeightRatio(source: "nws", displayName: "NWS Blend", weight: 0.17, snow24hIn: 4.7, snow72hIn: 9.2, snow5dIn: 12.8, avgTempF: 19.2),
                ModelWeightRatio(source: "gem", displayName: "CMC GEM", weight: 0.12, snow24hIn: 5.0, snow72hIn: 9.4, snow5dIn: 13.0, avgTempF: 18.2),
                ModelWeightRatio(source: "gfs", displayName: "NOAA GFS", weight: 0.08, snow24hIn: 3.9, snow72hIn: 8.1, snow5dIn: 11.2, avgTempF: 20.6),
                ModelWeightRatio(source: "hrrr", displayName: "HRRR 3km", weight: 0.06, snow24hIn: 5.4, snow72hIn: 9.8, snow5dIn: nil, avgTempF: 18.5),
            ],
            LeadBucket.extended.rawValue: [
                ModelWeightRatio(source: "ecmwf", displayName: "ECMWF IFS", weight: 0.44, snow24hIn: 4.3, snow72hIn: 8.9, snow5dIn: 12.6, avgTempF: 19.8),
                ModelWeightRatio(source: "gem", displayName: "CMC GEM", weight: 0.24, snow24hIn: 5.0, snow72hIn: 9.4, snow5dIn: 13.0, avgTempF: 18.2),
                ModelWeightRatio(source: "gfs", displayName: "NOAA GFS", weight: 0.18, snow24hIn: 3.9, snow72hIn: 8.1, snow5dIn: 11.2, avgTempF: 20.6),
                ModelWeightRatio(source: "nws", displayName: "NWS Blend", weight: 0.11, snow24hIn: 4.7, snow72hIn: 9.2, snow5dIn: 12.8, avgTempF: 19.2),
                ModelWeightRatio(source: "nam", displayName: "NAM 3km/12km", weight: 0.03, snow24hIn: 4.9, snow72hIn: 9.5, snow5dIn: nil, avgTempF: 19.0),
                ModelWeightRatio(source: "hrrr", displayName: "HRRR 3km", weight: 0.00, snow24hIn: nil, snow72hIn: nil, snow5dIn: nil, avgTempF: nil),
            ],
        ]

        return MountainForecastResponse(
            mountain: mountain,
            elevationBand: band.rawValue,
            elevationFt: mountain.elevations.feet(for: band),
            leadBucketWeights: weights,
            daily: daily,
            hourly: hourly,
            discussion: sampleDiscussionBTV,
            dataSourcesUsed: ["hrrr", "nam", "ecmwf", "gfs", "gem", "nws"],
            isLiveWeather: false,
            mlModelVersion: "ml-stacker-v1-demo"
        )
    }
}
