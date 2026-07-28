import Foundation

/// One persisted whole-system compute-power estimate.
public struct StoredSystemPowerSample: Sendable, Equatable {
    public var date: Date
    public var watts: Double

    public init(date: Date, watts: Double) {
        self.date = date
        self.watts = watts
    }
}

/// One app's energy accumulated into an hour-aligned server bucket.
public struct StoredSystemAppEnergyBucket: Sendable, Equatable {
    public var bucketStart: Date
    public var appKey: String
    public var displayName: String
    public var energyWh: Double
    public var activeDuration: TimeInterval
    public var peakWatts: Double

    public init(
        bucketStart: Date,
        appKey: String,
        displayName: String,
        energyWh: Double,
        activeDuration: TimeInterval,
        peakWatts: Double
    ) {
        self.bucketStart = bucketStart
        self.appKey = appKey
        self.displayName = displayName
        self.energyWh = energyWh
        self.activeDuration = activeDuration
        self.peakWatts = peakWatts
    }
}

/// Range total used to rank apps in Mac mini server mode.
public struct StoredSystemAppEnergyTotal: Sendable, Equatable {
    public var appKey: String
    public var displayName: String
    public var energyWh: Double
    public var activeDuration: TimeInterval
    public var peakWatts: Double

    public init(
        appKey: String,
        displayName: String,
        energyWh: Double,
        activeDuration: TimeInterval,
        peakWatts: Double
    ) {
        self.appKey = appKey
        self.displayName = displayName
        self.energyWh = energyWh
        self.activeDuration = activeDuration
        self.peakWatts = peakWatts
    }
}

public enum SystemAppEnergyAnalytics {
    /// Trapezoid-integrates live app watts and splits the result into
    /// hour-aligned buckets. Missing apps are treated as zero at that endpoint,
    /// which makes launches and exits taper honestly.
    public static func increments(
        previous: LivePowerReading,
        current: LivePowerReading,
        start: Date,
        end: Date,
        maximumGap: TimeInterval = 5 * 60,
        calendar: Calendar = .current
    ) -> [StoredSystemAppEnergyBucket] {
        let duration = end.timeIntervalSince(start)
        guard duration > 0, duration <= maximumGap else { return [] }

        let previousApps = Dictionary(
            previous.apps.map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let currentApps = Dictionary(
            current.apps.map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let keys = Set(previousApps.keys).union(currentApps.keys)

        var increments: [StoredSystemAppEnergyBucket] = []
        for key in keys {
            let previousWatts = previousApps[key]?.watts ?? 0
            let currentWatts = currentApps[key]?.watts ?? 0
            let displayName = currentApps[key]?.displayName
                ?? previousApps[key]?.displayName
                ?? key

            var segmentStart = start
            while segmentStart < end {
                guard let hour = calendar.dateInterval(of: .hour, for: segmentStart) else {
                    break
                }
                let segmentEnd = min(end, hour.end)
                let segmentDuration = segmentEnd.timeIntervalSince(segmentStart)
                let startFraction = segmentStart.timeIntervalSince(start) / duration
                let endFraction = segmentEnd.timeIntervalSince(start) / duration
                let startWatts = previousWatts
                    + (currentWatts - previousWatts) * startFraction
                let endWatts = previousWatts
                    + (currentWatts - previousWatts) * endFraction
                let energyWh = (startWatts + endWatts) / 2
                    * segmentDuration / 3600

                if energyWh > 0 {
                    increments.append(StoredSystemAppEnergyBucket(
                        bucketStart: hour.start,
                        appKey: key,
                        displayName: displayName,
                        energyWh: energyWh,
                        activeDuration: segmentDuration,
                        peakWatts: max(startWatts, endWatts)))
                }
                segmentStart = segmentEnd
            }
        }
        return increments
    }
}

/// Gap-aware power and energy statistics for a fixed reporting window.
public struct SystemPowerSummary: Sendable, Equatable {
    public var windowStart: Date
    public var windowEnd: Date
    public var averageWatts: Double?
    public var peakWatts: Double?
    public var energyWh: Double
    public var coveredDuration: TimeInterval
    public var sampleCount: Int

    public init(
        windowStart: Date,
        windowEnd: Date,
        averageWatts: Double?,
        peakWatts: Double?,
        energyWh: Double,
        coveredDuration: TimeInterval,
        sampleCount: Int
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.averageWatts = averageWatts
        self.peakWatts = peakWatts
        self.energyWh = energyWh
        self.coveredDuration = coveredDuration
        self.sampleCount = sampleCount
    }

    public var windowDuration: TimeInterval {
        max(0, windowEnd.timeIntervalSince(windowStart))
    }

    public var coverageFraction: Double {
        guard windowDuration > 0 else { return 0 }
        return min(1, coveredDuration / windowDuration)
    }
}

/// One chart bucket derived from the same gap-aware, time-weighted segments as
/// the summary, so uneven scheduling cannot bias its average.
public struct SystemPowerBucket: Identifiable, Sendable, Equatable {
    public var id: Date { start }
    public var start: Date
    public var averageWatts: Double
    public var peakWatts: Double
    public var sampleCount: Int

    public init(
        start: Date,
        averageWatts: Double,
        peakWatts: Double,
        sampleCount: Int
    ) {
        self.start = start
        self.averageWatts = averageWatts
        self.peakWatts = peakWatts
        self.sampleCount = sampleCount
    }
}

public enum SystemPowerAnalytics {
    private struct BucketAccumulator {
        var energyWh = 0.0
        var coveredDuration = 0.0
        var peakWatts = 0.0
        var segmentCount = 0
    }

    /// Integrates consecutive samples using a trapezoid. Segments separated by
    /// more than `maximumGap` are omitted so app downtime is reported as
    /// missing coverage rather than fabricated server energy.
    public static func summary(
        samples: [StoredSystemPowerSample],
        windowStart: Date,
        windowEnd: Date,
        maximumGap: TimeInterval = 5 * 60
    ) -> SystemPowerSummary {
        guard windowEnd > windowStart else {
            return SystemPowerSummary(
                windowStart: windowStart,
                windowEnd: windowEnd,
                averageWatts: nil,
                peakWatts: nil,
                energyWh: 0,
                coveredDuration: 0,
                sampleCount: 0)
        }

        let ordered = samples
            .filter { $0.date >= windowStart && $0.date <= windowEnd }
            .filter { $0.watts.isFinite && $0.watts >= 0 }
            .sorted { $0.date < $1.date }

        var energyWh = 0.0
        var coveredDuration = 0.0

        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            let duration = current.date.timeIntervalSince(previous.date)
            guard duration > 0, duration <= maximumGap else { continue }
            energyWh += ((previous.watts + current.watts) / 2) * duration / 3600
            coveredDuration += duration
        }

        let averageWatts = coveredDuration > 0
            ? energyWh * 3600 / coveredDuration
            : nil

        return SystemPowerSummary(
            windowStart: windowStart,
            windowEnd: windowEnd,
            averageWatts: averageWatts,
            peakWatts: ordered.map(\.watts).max(),
            energyWh: energyWh,
            coveredDuration: coveredDuration,
            sampleCount: ordered.count)
    }

    public static func buckets(
        samples: [StoredSystemPowerSample],
        windowStart: Date,
        windowEnd: Date,
        bucketDuration: TimeInterval,
        maximumGap: TimeInterval = 5 * 60
    ) -> [SystemPowerBucket] {
        guard windowEnd > windowStart, bucketDuration > 0 else { return [] }

        let ordered = samples
            .filter { $0.date >= windowStart && $0.date <= windowEnd }
            .filter { $0.watts.isFinite && $0.watts >= 0 }
            .sorted { $0.date < $1.date }
        var accumulators: [Int: BucketAccumulator] = [:]

        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            let fullDuration = current.date.timeIntervalSince(previous.date)
            guard fullDuration > 0, fullDuration <= maximumGap else { continue }

            var segmentStart = previous.date
            while segmentStart < current.date {
                let offset = segmentStart.timeIntervalSince(windowStart)
                let index = max(0, Int(floor(offset / bucketDuration)))
                let bucketEnd = min(
                    current.date,
                    windowStart.addingTimeInterval(Double(index + 1) * bucketDuration))
                let segmentDuration = bucketEnd.timeIntervalSince(segmentStart)
                guard segmentDuration > 0 else { break }

                let startFraction = segmentStart.timeIntervalSince(previous.date)
                    / fullDuration
                let endFraction = bucketEnd.timeIntervalSince(previous.date)
                    / fullDuration
                let startWatts = previous.watts
                    + (current.watts - previous.watts) * startFraction
                let endWatts = previous.watts
                    + (current.watts - previous.watts) * endFraction

                var accumulator = accumulators[index] ?? BucketAccumulator()
                accumulator.energyWh += (startWatts + endWatts) / 2
                    * segmentDuration / 3600
                accumulator.coveredDuration += segmentDuration
                accumulator.peakWatts = max(
                    accumulator.peakWatts,
                    max(startWatts, endWatts))
                accumulator.segmentCount += 1
                accumulators[index] = accumulator
                segmentStart = bucketEnd
            }
        }

        return accumulators.keys.sorted().compactMap { index in
            guard let accumulator = accumulators[index],
                  accumulator.coveredDuration > 0 else {
                return nil
            }
            return SystemPowerBucket(
                start: windowStart.addingTimeInterval(Double(index) * bucketDuration),
                averageWatts: accumulator.energyWh * 3600
                    / accumulator.coveredDuration,
                peakWatts: accumulator.peakWatts,
                sampleCount: accumulator.segmentCount)
        }
    }
}
