import Foundation

/// One persisted whole-system compute-power estimate.
public struct StoredSystemPowerSample: Sendable, Equatable {
    public var date: Date
    public var watts: Double
    /// Present for minute aggregates recorded from the live Mac mini stream.
    /// Older rows remain point samples and leave these fields nil.
    public var coveredDuration: TimeInterval?
    public var energyWh: Double?
    public var peakWatts: Double?
    public var coverageStart: Date?
    public var coverageEnd: Date?

    public init(
        date: Date,
        watts: Double,
        coveredDuration: TimeInterval? = nil,
        energyWh: Double? = nil,
        peakWatts: Double? = nil,
        coverageStart: Date? = nil,
        coverageEnd: Date? = nil
    ) {
        self.date = date
        self.watts = watts
        self.coveredDuration = coveredDuration
        self.energyWh = energyWh
        self.peakWatts = peakWatts
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
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
            previous.attributedApps.map { ($0.appKey, $0) },
            uniquingKeysWith: { first, _ in first })
        let currentApps = Dictionary(
            current.attributedApps.map { ($0.appKey, $0) },
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
    public struct ID: Hashable, Sendable {
        public var start: Date
        public var continuity: Int
    }

    public var id: ID { ID(start: start, continuity: continuity) }
    public var start: Date
    public var averageWatts: Double
    public var peakWatts: Double
    public var sampleCount: Int
    /// Identifies buckets that belong to the same uninterrupted recording
    /// span. Multiple spans can occupy one coarse chart bucket.
    public var continuity: Int

    public init(
        start: Date,
        averageWatts: Double,
        peakWatts: Double,
        sampleCount: Int,
        continuity: Int = 0
    ) {
        self.start = start
        self.averageWatts = averageWatts
        self.peakWatts = peakWatts
        self.sampleCount = sampleCount
        self.continuity = continuity
    }
}

public enum SystemPowerAnalytics {
    private struct BucketKey: Hashable {
        var index: Int
        var continuity: Int
    }

    private struct BucketAccumulator {
        var energyWh = 0.0
        var coveredDuration = 0.0
        var peakWatts = 0.0
        var segmentCount = 0
    }

    private struct Aggregate {
        var start: Date
        var end: Date
        var coveredDuration: TimeInterval
        var energyWh: Double
        var peakWatts: Double
    }

    private static func aggregate(from sample: StoredSystemPowerSample) -> Aggregate? {
        guard let coveredDuration = sample.coveredDuration,
              let energyWh = sample.energyWh,
              let peakWatts = sample.peakWatts,
              coveredDuration > 0,
              coveredDuration <= 60,
              energyWh.isFinite,
              energyWh >= 0,
              peakWatts.isFinite,
              peakWatts >= 0,
              let start = sample.coverageStart,
              let end = sample.coverageEnd,
              end > start,
              coveredDuration <= end.timeIntervalSince(start) else {
            return nil
        }
        return Aggregate(
            start: start,
            end: end,
            coveredDuration: coveredDuration,
            energyWh: energyWh,
            peakWatts: peakWatts)
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

        let valid = samples
            .filter { sample in
                if let aggregate = aggregate(from: sample) {
                    return aggregate.end > windowStart && aggregate.start < windowEnd
                }
                return sample.date >= windowStart && sample.date <= windowEnd
            }
            .filter { $0.watts.isFinite && $0.watts >= 0 }
            .sorted { $0.date < $1.date }
        let aggregates = valid.compactMap(aggregate(from:))
        let ordered = valid.filter { aggregate(from: $0) == nil }

        var energyWh = 0.0
        var coveredDuration = 0.0
        var peaks = ordered.map(\.watts)

        for aggregate in aggregates {
            let overlapStart = max(windowStart, aggregate.start)
            let overlapEnd = min(windowEnd, aggregate.end)
            let wallDuration = overlapEnd.timeIntervalSince(overlapStart)
            guard wallDuration > 0 else { continue }
            let fraction = wallDuration / aggregate.end.timeIntervalSince(aggregate.start)
            energyWh += aggregate.energyWh * fraction
            coveredDuration += aggregate.coveredDuration * fraction
            peaks.append(aggregate.peakWatts)
        }

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
            peakWatts: peaks.max(),
            energyWh: energyWh,
            coveredDuration: coveredDuration,
            sampleCount: ordered.count + aggregates.count)
    }

    public static func buckets(
        samples: [StoredSystemPowerSample],
        windowStart: Date,
        windowEnd: Date,
        bucketDuration: TimeInterval,
        maximumGap: TimeInterval = 5 * 60
    ) -> [SystemPowerBucket] {
        guard windowEnd > windowStart, bucketDuration > 0 else { return [] }

        let valid = samples
            .filter { sample in
                if let aggregate = aggregate(from: sample) {
                    return aggregate.end > windowStart && aggregate.start < windowEnd
                }
                return sample.date >= windowStart && sample.date <= windowEnd
            }
            .filter { $0.watts.isFinite && $0.watts >= 0 }
            .sorted { $0.date < $1.date }
        let aggregates = valid.compactMap(aggregate(from:))
            .sorted { $0.start < $1.start }
        let ordered = valid.filter { aggregate(from: $0) == nil }
        var accumulators: [BucketKey: BucketAccumulator] = [:]

        var aggregateContinuity = 0
        var previousAggregateEnd: Date?
        for aggregate in aggregates {
            if let previousAggregateEnd,
               aggregate.start.timeIntervalSince(previousAggregateEnd) > maximumGap {
                aggregateContinuity += 1
            }
            var segmentStart = max(windowStart, aggregate.start)
            let aggregateEnd = min(windowEnd, aggregate.end)
            while segmentStart < aggregateEnd {
                let offset = segmentStart.timeIntervalSince(windowStart)
                let index = max(0, Int(floor(offset / bucketDuration)))
                let key = BucketKey(
                    index: index,
                    continuity: aggregateContinuity)
                let segmentEnd = min(
                    aggregateEnd,
                    windowStart.addingTimeInterval(Double(index + 1) * bucketDuration))
                let segmentDuration = segmentEnd.timeIntervalSince(segmentStart)
                guard segmentDuration > 0 else { break }

                var accumulator = accumulators[key] ?? BucketAccumulator()
                let fraction = segmentDuration
                    / aggregate.end.timeIntervalSince(aggregate.start)
                accumulator.energyWh += aggregate.energyWh * fraction
                accumulator.coveredDuration += aggregate.coveredDuration * fraction
                accumulator.peakWatts = max(
                    accumulator.peakWatts,
                    aggregate.peakWatts)
                accumulator.segmentCount += 1
                accumulators[key] = accumulator
                segmentStart = segmentEnd
            }
            previousAggregateEnd = max(
                previousAggregateEnd ?? aggregate.end,
                aggregate.end)
        }

        // Aggregate and legacy point histories are kept in distinct
        // continuity spaces so an upgrade boundary cannot draw a fabricated
        // connection between their independently derived coverage.
        var orderedContinuity = aggregates.isEmpty ? 0 : aggregateContinuity + 1
        for (previous, current) in zip(ordered, ordered.dropFirst()) {
            let fullDuration = current.date.timeIntervalSince(previous.date)
            guard fullDuration > 0 else { continue }
            guard fullDuration <= maximumGap else {
                orderedContinuity += 1
                continue
            }

            var segmentStart = previous.date
            while segmentStart < current.date {
                let offset = segmentStart.timeIntervalSince(windowStart)
                let index = max(0, Int(floor(offset / bucketDuration)))
                let key = BucketKey(
                    index: index,
                    continuity: orderedContinuity)
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

                var accumulator = accumulators[key] ?? BucketAccumulator()
                accumulator.energyWh += (startWatts + endWatts) / 2
                    * segmentDuration / 3600
                accumulator.coveredDuration += segmentDuration
                accumulator.peakWatts = max(
                    accumulator.peakWatts,
                    max(startWatts, endWatts))
                accumulator.segmentCount += 1
                accumulators[key] = accumulator
                segmentStart = bucketEnd
            }
        }

        let keys = accumulators.keys.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.continuity < $1.continuity
        }
        return keys.compactMap { key in
            guard let accumulator = accumulators[key],
                  accumulator.coveredDuration > 0 else {
                return nil
            }
            return SystemPowerBucket(
                start: windowStart.addingTimeInterval(Double(key.index) * bucketDuration),
                averageWatts: accumulator.energyWh * 3600
                    / accumulator.coveredDuration,
                peakWatts: accumulator.peakWatts,
                sampleCount: accumulator.segmentCount,
                continuity: key.continuity)
        }
    }
}
