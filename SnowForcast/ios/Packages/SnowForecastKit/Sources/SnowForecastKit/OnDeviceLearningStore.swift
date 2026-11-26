import Foundation

public struct PendingForecastSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let mountainId: String
    public let elevationBand: String
    public let elevationFt: Int
    public let leadBucket: String
    public let validHourEpoch: Int
    public let sourceSnow: [String: Double]
    public let sourceTemp: [String: Double]
    public let blendedSnowIn: Double
    public let blendedTempF: Double
}

public struct AdaptiveBucketAdjustment: Codable, Sendable {
    public var snowLogBoost: [String: Double] = [:]
    public var tempLogBoost: [String: Double] = [:]
    public var verifiedCount: Int = 0
}

public struct PersistedLearningState: Codable, Sendable {
    public var snapshots: [String: PendingForecastSnapshot] = [:]
    public var adjustments: [String: AdaptiveBucketAdjustment] = [:]
    public var verifiedKeys: Set<String> = []
    public var tempAbsErrors: [Double] = []
    public var snowAbsErrors: [Double] = []
    public var recentLogs: [VerificationLogEntry] = []
    public var lastVerifiedAt: Date?
}

public actor OnDeviceLearningStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var state: PersistedLearningState

    public init(baseDirectory: URL? = nil) {
        let fm = FileManager.default
        let dir: URL
        if let baseDirectory {
            dir = baseDirectory
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            dir = support.appendingPathComponent("SnowForecast", isDirectory: true)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("on_device_learning_v1.json")

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        self.decoder = SnowForecastAPIClient.makeDecoder()

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(PersistedLearningState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedLearningState()
        }
    }

    private func persist() {
        if let data = try? encoder.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func bucketKey(_ mountainId: String, _ band: String, _ lead: String) -> String {
        "\(mountainId)|\(band)|\(lead)"
    }

    public func recordForecastSnapshots(
        mountainId: String,
        elevationBand: String,
        elevationFt: Int,
        hourly: [HourlyForecastPoint]
    ) {
        let nowEpoch = Int(Date().timeIntervalSince1970)
        // Keep snapshots within next 72h and prune snapshots older than 7 days
        for hr in hourly where hr.leadHours >= 1 && hr.leadHours <= 72 {
            let validEpoch = Int(floor(hr.time.timeIntervalSince1970 / 3600.0)) * 3600
            let key = "\(mountainId)|\(elevationBand)|\(hr.leadBucket)|\(validEpoch)"
            if state.verifiedKeys.contains(key) { continue }
            // Keep earliest issued forecast for each hour to preserve honest lead-time error
            if state.snapshots[key] == nil {
                state.snapshots[key] = PendingForecastSnapshot(
                    id: key,
                    mountainId: mountainId,
                    elevationBand: elevationBand,
                    elevationFt: elevationFt,
                    leadBucket: hr.leadBucket,
                    validHourEpoch: validEpoch,
                    sourceSnow: hr.sourceSnowIn,
                    sourceTemp: hr.sourceTempF,
                    blendedSnowIn: hr.snowIn,
                    blendedTempF: hr.tempF
                )
            }
        }

        // Prune very old unverified snapshots (> 7 days) and cap total
        let cutoff = nowEpoch - 7 * 86400
        state.snapshots = state.snapshots.filter { $0.value.validHourEpoch >= cutoff }
        if state.snapshots.count > 1200 {
            let sortedKeys = state.snapshots.values
                .sorted { $0.validHourEpoch > $1.validHourEpoch }
                .prefix(900)
                .map(\.id)
            let keepSet = Set(sortedKeys)
            state.snapshots = state.snapshots.filter { keepSet.contains($0.key) }
        }
        persist()
    }

    public func verifyObservation(
        mountainId: String,
        mountainName: String,
        elevationBand: String,
        validTime: Date,
        observedTempF: Double,
        observedSnowIn: Double? = nil
    ) -> Int {
        let targetEpoch = Int(floor(validTime.timeIntervalSince1970 / 3600.0)) * 3600
        let matching = state.snapshots.values.filter { snap in
            snap.mountainId == mountainId &&
            snap.elevationBand == elevationBand &&
            abs(snap.validHourEpoch - targetEpoch) <= 3600 &&
            !state.verifiedKeys.contains(snap.id)
        }

        var newlyVerified = 0
        let etaTemp = 0.08
        let etaSnow = 0.25

        for snap in matching {
            let bKey = Self.bucketKey(snap.mountainId, snap.elevationBand, snap.leadBucket)
            var adj = state.adjustments[bKey] ?? AdaptiveBucketAdjustment()

            var bestSrc = "ml"
            var bestErr = Double.infinity

            for (src, predTemp) in snap.sourceTemp {
                let err = abs(predTemp - observedTempF)
                let curr = adj.tempLogBoost[src] ?? 0.0
                adj.tempLogBoost[src] = max(-1.5, min(1.5, curr - etaTemp * (err / 5.0)))
                if observedSnowIn == nil && err < bestErr {
                    bestErr = err
                    bestSrc = src.uppercased()
                }
            }

            if let obsSnow = observedSnowIn {
                for (src, predSnow) in snap.sourceSnow {
                    let err = abs(predSnow - obsSnow)
                    let curr = adj.snowLogBoost[src] ?? 0.0
                    adj.snowLogBoost[src] = max(-1.5, min(1.5, curr - etaSnow * err))
                    if err < bestErr {
                        bestErr = err
                        bestSrc = src.uppercased()
                    }
                }
                state.snowAbsErrors.append(abs(snap.blendedSnowIn - obsSnow))
                if state.snowAbsErrors.count > 300 { state.snowAbsErrors.removeFirst() }
            }

            adj.verifiedCount += 1
            state.adjustments[bKey] = adj
            state.verifiedKeys.insert(snap.id)
            state.snapshots.removeValue(forKey: snap.id)

            state.tempAbsErrors.append(abs(snap.blendedTempF - observedTempF))
            if state.tempAbsErrors.count > 300 { state.tempAbsErrors.removeFirst() }

            let log = VerificationLogEntry(
                id: snap.id,
                mountainId: mountainId,
                mountainName: mountainName,
                elevationBand: elevationBand,
                validTime: Date(timeIntervalSince1970: TimeInterval(snap.validHourEpoch)),
                predictedTempF: snap.blendedTempF,
                observedTempF: (observedTempF * 10.0).rounded() / 10.0,
                predictedSnowIn: snap.blendedSnowIn,
                observedSnowIn: ((observedSnowIn ?? 0.0) * 100.0).rounded() / 100.0,
                bestSource: bestSrc
            )
            state.recentLogs.insert(log, at: 0)
            if state.recentLogs.count > 30 {
                state.recentLogs = Array(state.recentLogs.prefix(30))
            }
            newlyVerified += 1
        }

        if newlyVerified > 0 {
            state.lastVerifiedAt = Date()
            persist()
        }
        return newlyVerified
    }

    /// Verifies a resort's observed 24-hour snow report against stored hourly snapshots from the past 24 hours.
    public func verifyDailySnowReport(
        mountainId: String,
        mountainName: String,
        elevationBand: String = "summit",
        observedSnow24hIn: Double,
        reportedAt: Date = Date()
    ) -> Bool {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(secondsFromGMT: -5 * 3600) ?? .current
        let dayKey = "snowreport|\(mountainId)|\(elevationBand)|\(df.string(from: reportedAt))"
        guard !state.verifiedKeys.contains(dayKey) else { return false }

        let endEpoch = Int(reportedAt.timeIntervalSince1970)
        let startEpoch = endEpoch - 86400
        let windowSnaps = state.snapshots.values.filter {
            $0.mountainId == mountainId &&
            $0.elevationBand == elevationBand &&
            $0.validHourEpoch >= startEpoch &&
            $0.validHourEpoch <= endEpoch
        }
        guard windowSnaps.count >= 6 else { return false }

        // Sum each source's predicted snow over the captured hours (scaled to 24h if partial coverage)
        let scale = 24.0 / Double(windowSnaps.count)
        var sourceTotals: [String: Double] = [:]
        var sourceCounts: [String: Int] = [:]
        var blendedTotal = 0.0

        for snap in windowSnaps {
            blendedTotal += snap.blendedSnowIn
            for (src, val) in snap.sourceSnow {
                sourceTotals[src, default: 0.0] += val
                sourceCounts[src, default: 0] += 1
            }
        }
        let predBlended24 = blendedTotal * scale

        let bKey = Self.bucketKey(mountainId, elevationBand, "short_0_24h")
        var adj = state.adjustments[bKey] ?? AdaptiveBucketAdjustment()
        let etaSnow = 0.12

        for (src, totalVal) in sourceTotals {
            guard (sourceCounts[src] ?? 0) >= 4 else { continue }
            let srcScale = 24.0 / Double(sourceCounts[src] ?? 24)
            let pred24 = totalVal * srcScale
            let err = abs(pred24 - observedSnow24hIn)
            let curr = adj.snowLogBoost[src] ?? 0.0
            adj.snowLogBoost[src] = max(-1.5, min(1.5, curr - etaSnow * min(4.0, err)))
        }

        adj.verifiedCount += 1
        state.adjustments[bKey] = adj
        state.verifiedKeys.insert(dayKey)
        state.snowAbsErrors.append(abs(predBlended24 - observedSnow24hIn) / 24.0)
        if state.snowAbsErrors.count > 300 { state.snowAbsErrors.removeFirst() }
        state.lastVerifiedAt = Date()
        persist()
        return true
    }

    public func adaptedWeights(
        mountainId: String,
        elevationBand: String,
        leadBucket: String,
        baseWeights: [String: Double],
        forSnow: Bool = true
    ) -> [String: Double] {
        let bKey = Self.bucketKey(mountainId, elevationBand, leadBucket)
        guard let adj = state.adjustments[bKey], adj.verifiedCount > 0 else {
            return baseWeights
        }
        let boosts = forSnow ? adj.snowLogBoost : adj.tempLogBoost
        var updated: [String: Double] = [:]
        var total = 0.0
        for (src, w) in baseWeights {
            let mult = exp(boosts[src] ?? 0.0)
            let nw = max(0.0, w * mult)
            updated[src] = nw
            total += nw
        }
        guard total > 1e-9 else { return baseWeights }
        return updated.mapValues { $0 / total }
    }

    public func allAdjustmentsSnapshot() -> [String: AdaptiveBucketAdjustment] {
        state.adjustments
    }

    public func summary() -> OnDeviceLearningSummary {
        let tMae = state.tempAbsErrors.isEmpty
            ? nil
            : ((state.tempAbsErrors.reduce(0.0, +) / Double(state.tempAbsErrors.count)) * 100.0).rounded() / 100.0
        let sMae = state.snowAbsErrors.isEmpty
            ? nil
            : ((state.snowAbsErrors.reduce(0.0, +) / Double(state.snowAbsErrors.count)) * 1000.0).rounded() / 1000.0

        return OnDeviceLearningSummary(
            verifiedCount: state.verifiedKeys.count,
            blendedTempMaeF: tMae,
            blendedSnowMaeIn: sMae,
            lastVerifiedAt: state.lastVerifiedAt,
            recentLogs: state.recentLogs
        )
    }

    public func pendingSnapshotCount() -> Int {
        state.snapshots.count
    }
}
