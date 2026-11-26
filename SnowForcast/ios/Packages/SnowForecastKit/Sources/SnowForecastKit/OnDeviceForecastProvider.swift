import Foundation

public actor OnDeviceForecastProvider: SnowForecastProviding {
    private var mlEngine: OnDeviceMLEngine
    private let openMeteo: DirectOpenMeteoClient
    private let nws: DirectNWSClient
    private let regionalClient: RegionalForecasterClient
    private let stationClient: MountainStationClient
    private let cacheStore: DiskCacheStore
    private let learningStore: OnDeviceLearningStore

    private var forecastCache: [String: (Date, MountainForecastResponse)] = [:]
    private var discussionCache: [String: (Date, MeteorologistDiscussion)] = [:]
    private var lastAutoVerifyAt: Date?
    private let cacheTTL: TimeInterval = 15 * 60

    public init(
        mlEngine: OnDeviceMLEngine,
        openMeteo: DirectOpenMeteoClient = DirectOpenMeteoClient(),
        nws: DirectNWSClient = DirectNWSClient(),
        regionalClient: RegionalForecasterClient = RegionalForecasterClient(),
        stationClient: MountainStationClient = MountainStationClient(),
        cacheStore: DiskCacheStore = DiskCacheStore(),
        learningStore: OnDeviceLearningStore = OnDeviceLearningStore()
    ) {
        self.mlEngine = mlEngine
        self.openMeteo = openMeteo
        self.nws = nws
        self.regionalClient = regionalClient
        self.stationClient = stationClient
        self.cacheStore = cacheStore
        self.learningStore = learningStore
    }

    public func reloadOTAModel(from url: URL) async throws -> TrainingStatusResponse {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SnowAPIError.httpStatus(http.statusCode, "Failed to download ML weights")
        }
        let updatedEngine = try OnDeviceMLEngine(jsonData: data)
        try cacheStore.saveOTAModelData(data)
        self.mlEngine = updatedEngine
        self.forecastCache.removeAll()
        return updatedEngine.trainingStatus(scope: "global")
    }

    public func fetchLearningSummary() async -> OnDeviceLearningSummary {
        await learningStore.summary()
    }

    public func runSelfLearningVerification(mountainIds: [String]? = nil) async -> OnDeviceLearningSummary {
        let targetIds = mountainIds ?? mlEngine.bundle.mountains.map(\.id)
        var totalVerified = 0

        let results = await withTaskGroup(of: [(ExportedMountain, [(time: Date, tempF: Double, snowIn: Double)], MountainStationPayload)].self) { group in
            for mId in targetIds {
                guard let mountain = mlEngine.mountainsById[mId] else { continue }
                group.addTask {
                    let summitFt = mountain.elevations.summitFt
                    async let actualsTask = self.openMeteo.fetchRecentActuals(mountain: mountain, elevationFt: summitFt)
                    async let obsTask = self.stationClient.fetchLiveStationData(for: mountain)
                    let (actuals, stationData) = await (actualsTask, obsTask)
                    return [(mountain, actuals, stationData)]
                }
            }
            var all: [(ExportedMountain, [(time: Date, tempF: Double, snowIn: Double)], MountainStationPayload)] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        for (mountain, actuals, stationData) in results {
            for row in actuals {
                totalVerified += await learningStore.verifyObservation(
                    mountainId: mountain.id,
                    mountainName: mountain.name,
                    elevationBand: "summit",
                    validTime: row.time,
                    observedTempF: row.tempF,
                    observedSnowIn: row.snowIn
                )
            }
            for obs in stationData.observations where obs.elevationBand == "base" || obs.elevationBand == "summit" || obs.elevationBand == "mid" {
                totalVerified += await learningStore.verifyObservation(
                    mountainId: mountain.id,
                    mountainName: mountain.name,
                    elevationBand: obs.elevationBand,
                    validTime: obs.observedAt,
                    observedTempF: obs.tempF,
                    observedSnowIn: nil
                )
            }
            if let s24 = stationData.snowReport?.snow24hIn {
                if await learningStore.verifyDailySnowReport(
                    mountainId: mountain.id,
                    mountainName: mountain.name,
                    elevationBand: "summit",
                    observedSnow24hIn: s24,
                    reportedAt: stationData.snowReport?.reportedAt ?? Date()
                ) {
                    totalVerified += 1
                }
            }
        }

        if totalVerified > 0 {
            forecastCache.removeAll()
        }
        lastAutoVerifyAt = Date()
        return await learningStore.summary()
    }

    public func fetchMountains(state: String? = nil) async throws -> [MountainSummary] {
        let targets = mlEngine.bundle.mountains.filter { m in
            guard let state, !state.isEmpty, state != "All" else { return true }
            return m.state.uppercased() == state.uppercased()
        }

        let summaries = await withTaskGroup(of: MountainSummary?.self) { group in
            for m in targets {
                group.addTask {
                    try? await self.fetchMountainForecast(mountainId: m.id, elevation: .summit).mountain
                }
            }
            var out: [MountainSummary] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }

        // Periodically run background self-learning verification (every 30 min)
        let now = Date()
        if lastAutoVerifyAt == nil || now.timeIntervalSince(lastAutoVerifyAt ?? .distantPast) > 1800 {
            if await learningStore.pendingSnapshotCount() > 0 {
                _ = await runSelfLearningVerification()
            } else {
                lastAutoVerifyAt = now
            }
        }

        let sorted: [MountainSummary]
        if !summaries.isEmpty {
            sorted = summaries.sorted {
                if $0.snow5dIn != $1.snow5dIn { return $0.snow5dIn > $1.snow5dIn }
                return $0.snow72hIn > $1.snow72hIn
            }
            cacheStore.saveMountainSummaries(sorted)
            let widgetSnaps = sorted.map {
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
            cacheStore.saveWidgetSnapshots(widgetSnaps)
            return sorted
        }

        if let diskCached = cacheStore.loadMountainSummaries() {
            return diskCached.filter { m in
                guard let state, !state.isEmpty, state != "All" else { return true }
                return m.state.uppercased() == state.uppercased()
            }
        }
        return []
    }

    public func fetchMountainForecast(
        mountainId: String,
        elevation: ElevationBand = .summit
    ) async throws -> MountainForecastResponse {
        let cacheKey = "\(mountainId)|\(elevation.rawValue)"
        let now = Date()
        if let (ts, cached) = forecastCache[cacheKey], now.timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        guard let mountain = mlEngine.mountainsById[mountainId] else {
            throw SnowAPIError.invalidURL("Unknown mountain \(mountainId)")
        }

        let elevationFt = mountain.elevations.feet(for: elevation)

        async let omTask = openMeteo.fetchMultiModelForecast(
            mountain: mountain,
            elevationFt: elevationFt,
            modelMap: mlEngine.bundle.openMeteoModelMap,
            forecastDays: 7
        )
        async let nwsTask = nws.fetchHourlyForecast(for: mountain)
        async let discTask = fetchDiscussion(wfoId: mountain.nwsWfo)
        async let alertsTask = nws.fetchActiveAlerts(lat: mountain.latitude, lon: mountain.longitude)
        async let stationTask = stationClient.fetchLiveStationData(for: mountain)

        let omBundle = await omTask
        let nwsGrid = await nwsTask
        let discussion = await discTask
        let alerts = await alertsTask
        let stationData = await stationTask
        let liveObservations = stationData.observations
        let resortSnowReport = stationData.snowReport

        // Verify any matching past snapshots against live on-mountain sensors & resort snow report
        for obs in liveObservations where obs.elevationBand == elevation.rawValue {
            _ = await learningStore.verifyObservation(
                mountainId: mountain.id,
                mountainName: mountain.name,
                elevationBand: elevation.rawValue,
                validTime: obs.observedAt,
                observedTempF: obs.tempF,
                observedSnowIn: nil
            )
        }
        if let s24 = resortSnowReport?.snow24hIn {
            _ = await learningStore.verifyDailySnowReport(
                mountainId: mountain.id,
                mountainName: mountain.name,
                elevationBand: elevation.rawValue,
                observedSnow24hIn: s24,
                reportedAt: resortSnowReport?.reportedAt ?? now
            )
        }

        guard let omBundle else {
            if let cachedDisk = cacheStore.loadForecast(mountainId: mountainId, band: elevation) {
                return MountainForecastResponse(
                    mountain: cachedDisk.mountain,
                    elevationBand: cachedDisk.elevationBand,
                    elevationFt: cachedDisk.elevationFt,
                    leadBucketWeights: cachedDisk.leadBucketWeights,
                    daily: cachedDisk.daily,
                    hourly: cachedDisk.hourly,
                    discussion: discussion ?? cachedDisk.discussion,
                    alerts: alerts.isEmpty ? cachedDisk.alerts : alerts,
                    liveObservations: liveObservations.isEmpty ? cachedDisk.liveObservations : liveObservations,
                    resortSnowReport: resortSnowReport ?? cachedDisk.resortSnowReport,
                    dataSourcesUsed: cachedDisk.dataSourcesUsed,
                    isLiveWeather: false,
                    mlModelVersion: cachedDisk.mlModelVersion
                )
            }

            let fallbackSummary = MountainSummary(
                id: mountain.id,
                name: mountain.name,
                state: mountain.state,
                region: mountain.region,
                latitude: mountain.latitude,
                longitude: mountain.longitude,
                elevations: mountain.elevations,
                nwsWfo: mountain.nwsWfo,
                stationId: mountain.stationId,
                aspect: mountain.aspect,
                snow24hIn: 0.0,
                snow72hIn: 0.0,
                snow5dIn: 0.0,
                summitTempF: 24.0,
                summitWindMph: 14.0,
                confidence: "Low",
                headline: "Offline — unable to reach weather feeds",
                updatedAt: now
            )
            return MockSnowData.sampleForecast(for: fallbackSummary, band: elevation)
        }

        var nwsByHour: [Int: RawModelHour] = [:]
        if let nwsGrid {
            for (t, h) in zip(nwsGrid.times, nwsGrid.hours) {
                let hourEpoch = Int(floor(t.timeIntervalSince1970 / 3600.0)) * 3600
                let adjT = OnDevicePhysics.adjustTempForElevation(
                    tempF: h.tempF,
                    fromElevFt: nwsGrid.gridElevationFt,
                    toElevFt: elevationFt
                )
                nwsByHour[hourEpoch] = RawModelHour(
                    tempF: adjT,
                    relativeHumidityPct: h.relativeHumidityPct,
                    precipIn: h.precipIn,
                    snowfallIn: h.snowfallIn,
                    windMph: h.windMph,
                    precipProbPct: h.precipProbPct
                )
            }
        }

        // Precompute adapted snow & temp weights per lead bucket from on-device learning store
        var adaptedSnowByBucket: [String: [String: Double]] = [:]
        var adaptedTempByBucket: [String: [String: Double]] = [:]
        for bucket in LeadBucket.allCases {
            let baseSnowW = mlEngine.weightsForBucket(mountainId: mountain.id, elevationBand: elevation.rawValue, leadBucket: bucket.rawValue)
            let baseTempW = mlEngine.tempWeightsForBucket(mountainId: mountain.id, elevationBand: elevation.rawValue, leadBucket: bucket.rawValue)
            adaptedSnowByBucket[bucket.rawValue] = await learningStore.adaptedWeights(
                mountainId: mountain.id,
                elevationBand: elevation.rawValue,
                leadBucket: bucket.rawValue,
                baseWeights: baseSnowW,
                forSnow: true
            )
            adaptedTempByBucket[bucket.rawValue] = await learningStore.adaptedWeights(
                mountainId: mountain.id,
                elevationBand: elevation.rawValue,
                leadBucket: bucket.rawValue,
                baseWeights: baseTempW,
                forSnow: false
            )
        }

        let startHourEpoch = Int(floor(now.timeIntervalSince1970 / 3600.0)) * 3600
        let startHour = Date(timeIntervalSince1970: TimeInterval(startHourEpoch))
        var hourlyPoints: [HourlyForecastPoint] = []
        var sourcesPresent: Set<String> = []
        var windDirections: [Double] = []

        for (idx, validTime) in omBundle.times.enumerated() {
            if validTime.timeIntervalSince(startHour) < -3600 { continue }
            let leadHours = max(0, Int(validTime.timeIntervalSince(startHour) / 3600.0))
            if leadHours >= 168 { break }
            let leadBucket = OnDevicePhysics.leadBucket(forHours: leadHours)

            var sourceSnow: [String: Double] = [:]
            var sourceTemp: [String: Double] = [:]
            var winds: [Double] = []
            var gusts: [Double] = []
            var precips: [Double] = []
            var fls: [Double] = []
            var rhs: [Double] = []
            var t850s: [Double] = []
            var t700s: [Double] = []
            var hourDirs: [Double] = []

            for (src, series) in omBundle.models {
                guard idx < series.count else { continue }
                let item = series[idx]
                if let rawT = item.tempF,
                   let adjT = OnDevicePhysics.adjustTempForElevation(
                       tempF: rawT,
                       fromElevFt: omBundle.gridElevationFt,
                       toElevFt: elevationFt
                   ) {
                    sourceTemp[src] = (adjT * 10.0).rounded() / 10.0
                    sourcesPresent.insert(src)
                }
                if let sf = item.snowfallIn {
                    sourceSnow[src] = (max(0.0, sf) * 1000.0).rounded() / 1000.0
                    sourcesPresent.insert(src)
                } else if let p = item.precipIn, let t = sourceTemp[src] {
                    let slrEst = OnDevicePhysics.estimateSLR(
                        tempF: t,
                        windMph: item.windMph ?? 10.0,
                        temp850F: item.temp850hpaF,
                        temp700F: item.temp700hpaF
                    )
                    sourceSnow[src] = (p * slrEst * 1000.0).rounded() / 1000.0
                }
                if let w = item.windMph { winds.append(w) }
                if let g = item.windGustMph { gusts.append(g) }
                if let p = item.precipIn { precips.append(p) }
                if let fl = item.freezingLevelFt { fls.append(fl) }
                if let rh = item.relativeHumidityPct { rhs.append(rh) }
                if let t850 = item.temp850hpaF { t850s.append(t850) }
                if let t700 = item.temp700hpaF { t700s.append(t700) }
                if let wd = item.windDirectionDeg { hourDirs.append(wd) }
            }

            let hourEpoch = Int(floor(validTime.timeIntervalSince1970 / 3600.0)) * 3600
            if let nwsItem = nwsByHour[hourEpoch] {
                if let t = nwsItem.tempF {
                    sourceTemp["nws"] = (t * 10.0).rounded() / 10.0
                    sourcesPresent.insert("nws")
                }
                if let sf = nwsItem.snowfallIn {
                    sourceSnow["nws"] = (sf * 1000.0).rounded() / 1000.0
                }
                if let w = nwsItem.windMph { winds.append(w) }
                if let rh = nwsItem.relativeHumidityPct { rhs.append(rh) }
            }

            if !hourDirs.isEmpty && hourlyPoints.count < 24 {
                windDirections.append(hourDirs.reduce(0.0, +) / Double(hourDirs.count))
            }

            let windMph = winds.isEmpty ? 12.0 : ((winds.reduce(0.0, +) / Double(winds.count)) * 10.0).rounded() / 10.0
            let windGustMph = gusts.isEmpty ? ((windMph * 1.4) * 10.0).rounded() / 10.0 : ((gusts.max() ?? windMph) * 10.0).rounded() / 10.0

            let blended = mlEngine.predictHour(
                mountainId: mountain.id,
                elevationBand: elevation.rawValue,
                elevationFt: elevationFt,
                orographicFactor: mountain.orographicFactor,
                leadHours: leadHours,
                leadBucket: leadBucket,
                validTime: validTime,
                windMph: windMph,
                sourceSnow: sourceSnow,
                sourceTemp: sourceTemp,
                snowWeightOverride: adaptedSnowByBucket[leadBucket],
                tempWeightOverride: adaptedTempByBucket[leadBucket]
            )

            let avgRH = rhs.isEmpty ? nil : (rhs.reduce(0.0, +) / Double(rhs.count))
            let avg850 = t850s.isEmpty ? nil : ((t850s.reduce(0.0, +) / Double(t850s.count)) * 10.0).rounded() / 10.0
            let avg700 = t700s.isEmpty ? nil : ((t700s.reduce(0.0, +) / Double(t700s.count)) * 10.0).rounded() / 10.0
            let wetBulbF = OnDevicePhysics.computeWetBulbF(tempF: blended.tempF, rhPct: avgRH)
            let warmNose = OnDevicePhysics.isWarmNose(surfaceTempF: blended.tempF, temp850F: avg850)

            let slr = OnDevicePhysics.estimateSLR(
                tempF: blended.tempF,
                windMph: windMph,
                temp850F: avg850,
                temp700F: avg700
            )
            let liquidIn: Double = {
                if !precips.isEmpty {
                    return ((precips.reduce(0.0, +) / Double(precips.count)) * 1000.0).rounded() / 1000.0
                }
                return slr > 0 ? ((blended.snowIn / slr) * 1000.0).rounded() / 1000.0 : 0.0
            }()
            let freezingLevelFt: Int = {
                if !fls.isEmpty {
                    return Int(round(fls.reduce(0.0, +) / Double(fls.count)))
                }
                return max(0, Int(round(Double(elevationFt) + ((blended.tempF - 32.0) / 3.5) * 1000.0)))
            }()
            let precipType = OnDevicePhysics.classifyPrecipType(
                liquidIn: liquidIn,
                snowIn: blended.snowIn,
                tempF: blended.tempF,
                temp850F: avg850,
                wetBulbF: wetBulbF
            )

            let hourAvgDir = hourDirs.isEmpty ? nil : (hourDirs.reduce(0.0, +) / Double(hourDirs.count))
            let aspectMult = OnDevicePhysics.orographicAspectMultiplier(
                windDirDeg: hourAvgDir,
                windMph: windMph,
                aspect: mountain.aspect,
                elevationFt: elevationFt
            )
            let baseAdjustedSnow = warmNose ? (blended.snowIn * 0.35) : (blended.snowIn * aspectMult)
            let adjustedSnowIn = (baseAdjustedSnow * 1000.0).rounded() / 1000.0
            let adjustedP10 = warmNose ? ((adjustedSnowIn * 0.6 * 1000.0).rounded() / 1000.0) : ((blended.snowP10In * aspectMult * 1000.0).rounded() / 1000.0)
            let adjustedP90 = warmNose ? ((adjustedSnowIn * 1.4 * 1000.0).rounded() / 1000.0) : ((blended.snowP90In * aspectMult * 1000.0).rounded() / 1000.0)

            hourlyPoints.append(
                HourlyForecastPoint(
                    time: validTime,
                    leadHours: leadHours,
                    leadBucket: leadBucket,
                    snowIn: adjustedSnowIn,
                    snowP10In: adjustedP10,
                    snowP90In: adjustedP90,
                    liquidPrecipIn: liquidIn,
                    tempF: blended.tempF,
                    windMph: windMph,
                    windGustMph: windGustMph,
                    freezingLevelFt: freezingLevelFt,
                    temp850hpaF: avg850,
                    wetBulbF: wetBulbF,
                    warmNoseRisk: warmNose,
                    slrRatio: slr,
                    precipType: precipType,
                    sourceSnowIn: sourceSnow,
                    sourceTempF: sourceTemp
                )
            )
        }

        // Record raw forecast snapshots for future on-device verification & self-learning
        await learningStore.recordForecastSnapshots(
            mountainId: mountain.id,
            elevationBand: elevation.rawValue,
            elevationFt: elevationFt,
            hourly: hourlyPoints
        )

        // Anchor near-term (0-18h) temperatures using exact band sensor or Base<->Summit profile interpolation
        let baseSensor = liveObservations.first(where: { $0.isOnMountainSensor && $0.elevationBand == "base" })
        let summitSensor = liveObservations.first(where: { $0.isOnMountainSensor && $0.elevationBand == "summit" })
        let anchorObs = liveObservations.first(where: { $0.isOnMountainSensor && $0.elevationBand == elevation.rawValue })
            ?? liveObservations.first(where: { $0.isOnMountainSensor })
            ?? liveObservations.first

        if let firstHour = hourlyPoints.first {
            let anchorTempAtBand: Double? = {
                if let exact = liveObservations.first(where: { $0.isOnMountainSensor && $0.elevationBand == elevation.rawValue }) {
                    return exact.tempF
                }
                if let baseSensor, let summitSensor,
                   let baseElev = baseSensor.elevationFt, let sumElev = summitSensor.elevationFt,
                   sumElev > baseElev {
                    let frac = Double(elevationFt - baseElev) / Double(sumElev - baseElev)
                    return baseSensor.tempF + frac * (summitSensor.tempF - baseSensor.tempF)
                }
                if let anchorObs {
                    return OnDevicePhysics.adjustTempForElevation(
                        tempF: anchorObs.tempF,
                        fromElevFt: anchorObs.elevationFt,
                        toElevFt: elevationFt
                    ) ?? anchorObs.tempF
                }
                return nil
            }()

            if let anchorTempAtBand {
                let rawOffset = anchorTempAtBand - firstHour.tempF
                let clampedOffset = max(-12.0, min(12.0, rawOffset))
                if abs(clampedOffset) >= 0.5 {
                    for i in 0..<hourlyPoints.count where hourlyPoints[i].leadHours < 18 {
                        let h = hourlyPoints[i]
                        let decay = exp(-Double(h.leadHours) / 8.0)
                        let deltaT = clampedOffset * decay
                        let adjTemp = ((h.tempF + deltaT) * 10.0).rounded() / 10.0
                        let adjWetBulb = h.wetBulbF.map { (($0 + deltaT) * 10.0).rounded() / 10.0 }
                        let adjWarmNose = OnDevicePhysics.isWarmNose(surfaceTempF: adjTemp, temp850F: h.temp850hpaF)
                        let adjSLR = OnDevicePhysics.estimateSLR(tempF: adjTemp, windMph: h.windMph, temp850F: h.temp850hpaF)
                        let adjFL = h.freezingLevelFt.map { max(0, $0 + Int(round((deltaT / 3.5) * 1000.0))) }

                        // Recompute snow if shifted across the marginal 28F..37F rain/snow boundary
                        var adjSnow = h.snowIn
                        var adjP10 = h.snowP10In
                        var adjP90 = h.snowP90In
                        if h.liquidPrecipIn >= 0.005 && (min(h.tempF, adjTemp) <= 37.0 && max(h.tempF, adjTemp) >= 28.0) {
                            let recomputed = adjWarmNose ? (h.liquidPrecipIn * 2.5) : (h.liquidPrecipIn * adjSLR)
                            adjSnow = ((recomputed * 1000.0).rounded() / 1000.0)
                            adjP10 = ((adjSnow * 0.65 * 1000.0).rounded() / 1000.0)
                            adjP90 = ((adjSnow * 1.35 * 1000.0).rounded() / 1000.0)
                        }

                        let adjType = OnDevicePhysics.classifyPrecipType(
                            liquidIn: h.liquidPrecipIn,
                            snowIn: adjSnow,
                            tempF: adjTemp,
                            temp850F: h.temp850hpaF,
                            wetBulbF: adjWetBulb
                        )
                        hourlyPoints[i] = HourlyForecastPoint(
                            time: h.time,
                            leadHours: h.leadHours,
                            leadBucket: h.leadBucket,
                            snowIn: adjSnow,
                            snowP10In: adjP10,
                            snowP90In: adjP90,
                            liquidPrecipIn: h.liquidPrecipIn,
                            tempF: adjTemp,
                            windMph: h.windMph,
                            windGustMph: h.windGustMph,
                            freezingLevelFt: adjFL,
                            temp850hpaF: h.temp850hpaF,
                            wetBulbF: adjWetBulb,
                            warmNoseRisk: adjWarmNose,
                            slrRatio: adjSLR,
                            precipType: adjType,
                            sourceSnowIn: h.sourceSnowIn,
                            sourceTempF: h.sourceTempF
                        )
                    }
                }
            }
        }

        let snow24h = (hourlyPoints.filter { $0.leadHours < 24 }.reduce(0.0) { $0 + $1.snowIn } * 10.0).rounded() / 10.0
        let snow72h = (hourlyPoints.filter { $0.leadHours < 72 }.reduce(0.0) { $0 + $1.snowIn } * 10.0).rounded() / 10.0
        let snow5d = (hourlyPoints.filter { $0.leadHours < 120 }.reduce(0.0) { $0 + $1.snowIn } * 10.0).rounded() / 10.0

        let dailyPoints = buildDailyRollups(from: hourlyPoints)
        let leadBucketWeights = buildLeadBucketWeights(
            adaptedWeightsByBucket: adaptedSnowByBucket,
            hourlyPoints: hourlyPoints
        )

        // Prefer live on-mountain sensor reading if it matches the requested band, else blended forecast
        let matchingBandSensor = liveObservations.first(where: { $0.isOnMountainSensor && $0.elevationBand == elevation.rawValue })
        let currTemp = matchingBandSensor?.tempF ?? hourlyPoints.first?.tempF ?? 24.0
        let currWind = matchingBandSensor?.windMph ?? hourlyPoints.first?.windMph ?? 12.0
        let max24Wind = hourlyPoints.prefix(24).map(\.windMph).max() ?? currWind
        let max24Gust = hourlyPoints.prefix(24).map(\.windGustMph).max() ?? (currWind * 1.4)
        let avgDir24 = windDirections.isEmpty ? nil : (windDirections.reduce(0.0, +) / Double(windDirections.count))

        let liftHoldRisk = OnDevicePhysics.computeLiftHoldRisk(
            windMph: max24Wind,
            windGustMph: max24Gust,
            elevationFt: elevationFt,
            windDirDeg: avgDir24,
            aspect: mountain.aspect
        )
        let surfaceQuality = OnDevicePhysics.computeSurfaceQuality(snow24hIn: snow24h, hourly: hourlyPoints)
        let hasWarmNose = hourlyPoints.prefix(48).contains(where: \.warmNoseRisk)
        let confidence = computeConfidence(hourlyPoints)
        let headline = buildHeadline(
            snow24h: snow24h,
            snow72h: snow72h,
            snow5d: snow5d,
            tempF: currTemp,
            windMph: max24Wind,
            warmNose: hasWarmNose
        )

        let summary = MountainSummary(
            id: mountain.id,
            name: mountain.name,
            state: mountain.state,
            region: mountain.region,
            latitude: mountain.latitude,
            longitude: mountain.longitude,
            elevations: mountain.elevations,
            nwsWfo: mountain.nwsWfo,
            stationId: mountain.stationId,
            aspect: mountain.aspect,
            snow24hIn: snow24h,
            snow72hIn: snow72h,
            snow5dIn: snow5d,
            summitTempF: currTemp,
            summitWindMph: currWind,
            confidence: confidence,
            liftHoldRisk: liftHoldRisk,
            surfaceQuality: surfaceQuality,
            warmNoseRisk: hasWarmNose,
            activeAlertCount: alerts.count,
            headline: headline,
            updatedAt: now
        )

        let response = MountainForecastResponse(
            mountain: summary,
            elevationBand: elevation.rawValue,
            elevationFt: elevationFt,
            leadBucketWeights: leadBucketWeights,
            daily: dailyPoints,
            hourly: hourlyPoints,
            discussion: discussion,
            alerts: alerts,
            liveObservations: liveObservations,
            resortSnowReport: resortSnowReport,
            dataSourcesUsed: sourcesPresent.sorted(),
            isLiveWeather: true,
            mlModelVersion: "\(mlEngine.bundle.version)-adaptive"
        )
        forecastCache[cacheKey] = (now, response)
        cacheStore.saveForecast(response, mountainId: mountainId, band: elevation)
        return response
    }

    public func fetchDiscussions() async throws -> [MeteorologistDiscussion] {
        let offices = Array(mlEngine.bundle.wfoOffices.keys).sorted()
        let results = await withTaskGroup(of: MeteorologistDiscussion?.self) { group in
            for wfoId in offices {
                group.addTask {
                    await self.fetchDiscussion(wfoId: wfoId)
                }
            }
            var out: [MeteorologistDiscussion] = []
            for await d in group {
                if let d { out.append(d) }
            }
            return out
        }
        if !results.isEmpty {
            let sorted = results.sorted { $0.issuedAt > $1.issuedAt }
            cacheStore.saveDiscussions(sorted)
            return sorted
        }
        return cacheStore.loadDiscussions() ?? []
    }

    public func fetchRegionalPosts() async -> [RegionalForecastPost] {
        let posts = await regionalClient.fetchRegionalPosts()
        if !posts.isEmpty {
            cacheStore.saveRegionalPosts(posts)
            return posts
        }
        return cacheStore.loadRegionalPosts() ?? []
    }

    public func fetchMLStatus(scope: String?) async throws -> TrainingStatusResponse {
        var base = mlEngine.trainingStatus(scope: scope)
        let targetScope = scope ?? "global"
        let adjs = await learningStore.allAdjustmentsSnapshot()
        if targetScope != "global" {
            let updatedMetrics = base.metrics.map { m -> ModelPerformanceMetric in
                let bKey = "\(targetScope)|\(m.elevationBand)|\(m.leadBucket)"
                guard adjs[bKey] != nil else { return m }
                return m
            }
            base = TrainingStatusResponse(
                trainedAt: base.trainedAt,
                modelVersion: base.modelVersion,
                totalTrainingSamples: base.totalTrainingSamples,
                metrics: updatedMetrics
            )
        }
        return base
    }

    public func triggerRetrain() async throws -> TrainingStatusResponse {
        _ = await runSelfLearningVerification()
        return try await fetchMLStatus(scope: "global")
    }

    private func fetchDiscussion(wfoId: String) async -> MeteorologistDiscussion? {
        let now = Date()
        if let (ts, cached) = discussionCache[wfoId], now.timeIntervalSince(ts) < cacheTTL {
            return cached
        }
        guard let wfo = mlEngine.bundle.wfoOffices[wfoId] else { return nil }
        let covered = mlEngine.bundle.mountains.filter { $0.nwsWfo == wfoId }.map(\.id)
        if let live = await nws.fetchLatestDiscussion(wfo: wfo, coveredMountainIds: covered) {
            discussionCache[wfoId] = (now, live)
            return live
        }
        return cacheStore.loadDiscussions()?.first(where: { $0.wfoId == wfoId })
    }

    private func buildDailyRollups(from hourlyPoints: [HourlyForecastPoint]) -> [DailyForecastPoint] {
        let eastern = TimeZone(secondsFromGMT: -5 * 3600) ?? .current
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = eastern
        df.locale = Locale(identifier: "en_US_POSIX")

        var grouped: [String: [HourlyForecastPoint]] = [:]
        for h in hourlyPoints {
            let key = df.string(from: h.time)
            grouped[key, default: []].append(h)
        }

        return grouped.keys.sorted().prefix(7).map { dateStr in
            let pts = grouped[dateStr] ?? []
            let dSnow = (pts.reduce(0.0) { $0 + $1.snowIn } * 10.0).rounded() / 10.0
            let dP10 = min(dSnow, (pts.reduce(0.0) { $0 + $1.snowP10In } * 10.0).rounded() / 10.0)
            let dP90 = max(dSnow, (pts.reduce(0.0) { $0 + $1.snowP90In } * 10.0).rounded() / 10.0)
            let dLiq = (pts.reduce(0.0) { $0 + $1.liquidPrecipIn } * 100.0).rounded() / 100.0
            let temps = pts.map(\.tempF)
            let winds = pts.map(\.windMph)
            let gusts = pts.map(\.windGustMph)
            let slrs = pts.map(\.slrRatio).filter { $0 > 0 }
            let avgSLR = slrs.isEmpty ? 0.0 : ((slrs.reduce(0.0, +) / Double(slrs.count)) * 10.0).rounded() / 10.0

            var srcDaily: [String: Double] = [:]
            for src in mlEngine.bundle.modelSources {
                let vals = pts.compactMap { $0.sourceSnowIn[src] }
                if !vals.isEmpty {
                    srcDaily[src] = (vals.reduce(0.0, +) * 10.0).rounded() / 10.0
                }
            }

            let hasMix = pts.contains { $0.precipType == "Mix" }
            let hasRain = pts.contains { $0.precipType == "Rain" }
            let maxWind = winds.max() ?? 10.0
            let maxTemp = temps.max() ?? 28.0

            let condition: String
            if dSnow >= 4.0 {
                condition = dSnow >= 8.0 ? "Heavy Snow" : "Snow"
            } else if dSnow >= 0.5 {
                condition = hasMix ? "Wintry Mix" : "Snow Showers"
            } else if hasRain && dLiq >= 0.1 {
                condition = "Rain"
            } else if maxWind >= 35.0 {
                condition = "Windy"
            } else {
                condition = maxTemp <= 32.0 ? "Cold & Dry" : "Partly Cloudy"
            }

            let activeHrs = pts.filter { $0.liquidPrecipIn >= 0.01 || $0.snowIn >= 0.05 }.count
            let pop = min(95, max(10, Int(round((Double(activeHrs) / Double(max(1, pts.count))) * 140.0))))

            return DailyForecastPoint(
                date: dateStr,
                snowIn: dSnow,
                snowP10In: dP10,
                snowP90In: dP90,
                liquidPrecipIn: dLiq,
                slrRatio: avgSLR,
                tempHighF: ((temps.max() ?? 28.0) * 10.0).rounded() / 10.0,
                tempLowF: ((temps.min() ?? 15.0) * 10.0).rounded() / 10.0,
                windMaxMph: (maxWind * 10.0).rounded() / 10.0,
                windGustMph: ((gusts.max() ?? 18.0) * 10.0).rounded() / 10.0,
                precipProbPct: pop,
                condition: condition,
                sourceSnowIn: srcDaily
            )
        }
    }

    private func buildLeadBucketWeights(
        adaptedWeightsByBucket: [String: [String: Double]],
        hourlyPoints: [HourlyForecastPoint]
    ) -> [String: [ModelWeightRatio]] {
        var result: [String: [ModelWeightRatio]] = [:]
        for bucket in LeadBucket.allCases {
            let wMap = adaptedWeightsByBucket[bucket.rawValue] ?? [:]
            let ratios = mlEngine.bundle.modelSources.map { src -> ModelWeightRatio in
                let s24 = hourlyPoints.filter { $0.leadHours < 24 }.compactMap { $0.sourceSnowIn[src] }
                let s72 = hourlyPoints.filter { $0.leadHours < 72 }.compactMap { $0.sourceSnowIn[src] }
                let s5d = hourlyPoints.filter { $0.leadHours < 120 }.compactMap { $0.sourceSnowIn[src] }
                let t72 = hourlyPoints.filter { $0.leadHours < 72 }.compactMap { $0.sourceTempF[src] }
                return ModelWeightRatio(
                    source: src,
                    displayName: mlEngine.bundle.modelDisplayNames[src] ?? src.uppercased(),
                    weight: ((wMap[src] ?? 0.0) * 10000.0).rounded() / 10000.0,
                    snow24hIn: s24.isEmpty ? nil : (s24.reduce(0.0, +) * 10.0).rounded() / 10.0,
                    snow72hIn: s72.isEmpty ? nil : (s72.reduce(0.0, +) * 10.0).rounded() / 10.0,
                    snow5dIn: s5d.isEmpty ? nil : (s5d.reduce(0.0, +) * 10.0).rounded() / 10.0,
                    avgTempF: t72.isEmpty ? nil : ((t72.reduce(0.0, +) / Double(t72.count)) * 10.0).rounded() / 10.0
                )
            }
            .sorted { $0.weight > $1.weight }
            result[bucket.rawValue] = ratios
        }
        return result
    }

    private func computeConfidence(_ hourly: [HourlyForecastPoint]) -> String {
        let snowHours = hourly.prefix(72).filter { $0.snowIn >= 0.05 }
        guard !snowHours.isEmpty else { return "High" }
        var cvs: [Double] = []
        for h in snowHours {
            let vals = Array(h.sourceSnowIn.values)
            guard vals.count >= 2 else { continue }
            let mean = vals.reduce(0.0, +) / Double(vals.count)
            let std = sqrt(vals.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(vals.count))
            cvs.append(std / max(0.1, mean))
        }
        guard !cvs.isEmpty else { return "Moderate" }
        let avgCV = cvs.reduce(0.0, +) / Double(cvs.count)
        if avgCV < 0.35 { return "High" }
        if avgCV < 0.65 { return "Moderate" }
        return "Low"
    }

    private func buildHeadline(
        snow24h: Double,
        snow72h: Double,
        snow5d: Double,
        tempF: Double,
        windMph: Double,
        warmNose: Bool
    ) -> String {
        if warmNose && (snow24h >= 1.0 || snow72h >= 2.0) {
            return "Warm nose aloft: watch for sleet/mix on mid/upper slopes"
        }
        if snow24h >= 6.0 { return String(format: "Powder Alert: %.1f\" expected in 24h", snow24h) }
        if snow72h >= 6.0 { return String(format: "Storm cycle: %.1f\" over the next 72h", snow72h) }
        if snow5d >= 4.0 { return String(format: "Accumulating snow: %.1f\" next 5 days", snow5d) }
        if windMph >= 34.0 { return String(format: "Windy summit (%.0f mph) · Lift-hold risk", windMph) }
        if tempF <= 30.0 && snow72h >= 1.0 { return String(format: "Light snow showers (%.1f\" / 72h) & cold", snow72h) }
        if tempF > 35.0 { return String(format: "Mild temps (%.0f°F) · Soft spring/mixed conditions", tempF) }
        return "Cold & dry snow-preservation pattern"
    }
}
