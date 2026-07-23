import Foundation

/// The most recent contiguous period during which the Mac ran on battery.
///
/// A session starts at the first observed off-AC sample after AC power and ends
/// at the first subsequent on-AC sample. The resolver can also return an active
/// session (whose end is the newest sample) or a partial session when history
/// begins after the unplug transition.
public struct BatterySession: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var startPercent: Int
    public var endPercent: Int
    public var isActive: Bool
    public var isStartPartial: Bool

    public init(
        start: Date,
        end: Date,
        startPercent: Int,
        endPercent: Int,
        isActive: Bool,
        isStartPartial: Bool
    ) {
        self.start = start
        self.end = end
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.isActive = isActive
        self.isStartPartial = isStartPartial
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Battery percentage points lost during the off-AC period. Battery
    /// calibration can occasionally make the reported percentage rise while
    /// unplugged, so never present a negative loss.
    public var batteryPercentUsed: Int { max(0, startPercent - endPercent) }
}

/// Resolves the current battery session, or the most recently completed one
/// when the newest sample is on AC power.
public enum BatterySessionResolver {
    /// When the on-AC sample before an unplug is farther away than this, the
    /// transition happened inside an unobserved gap and the start is partial.
    public static let defaultMaximumBoundaryGap: TimeInterval = 5 * 60

    public static func latest(
        in samples: [StoredBatterySample],
        maximumBoundaryGap: TimeInterval = defaultMaximumBoundaryGap
    ) -> BatterySession? {
        let ordered = orderedUniqueSamples(samples)
        guard !ordered.isEmpty else { return nil }

        struct OpenSession {
            var firstOffAC: StoredBatterySample
            var lastOffAC: StoredBatterySample
            var isStartPartial: Bool
        }

        var open: OpenSession?
        var latestCompleted: BatterySession?

        for (index, sample) in ordered.enumerated() {
            if sample.onAC {
                if let closing = open {
                    latestCompleted = BatterySession(
                        start: closing.firstOffAC.date,
                        end: sample.date,
                        startPercent: closing.firstOffAC.percent,
                        endPercent: closing.lastOffAC.percent,
                        isActive: false,
                        isStartPartial: closing.isStartPartial)
                    open = nil
                }
                continue
            }

            if open == nil {
                let previous = index > 0 ? ordered[index - 1] : nil
                let hasObservedNearbyAC = previous.map {
                    $0.onAC && sample.date.timeIntervalSince($0.date) <= maximumBoundaryGap
                } ?? false
                open = OpenSession(
                    firstOffAC: sample,
                    lastOffAC: sample,
                    isStartPartial: !hasObservedNearbyAC)
            } else {
                open?.lastOffAC = sample
            }
        }

        if let open {
            return BatterySession(
                start: open.firstOffAC.date,
                end: open.lastOffAC.date,
                startPercent: open.firstOffAC.percent,
                endPercent: open.lastOffAC.percent,
                isActive: true,
                isStartPartial: open.isStartPartial)
        }
        return latestCompleted
    }

    /// Sorts samples chronologically and lets the last value at an identical
    /// timestamp win. Live and backfilled samples should not overlap, but this
    /// keeps a boundary deterministic if they ever do.
    private static func orderedUniqueSamples(
        _ samples: [StoredBatterySample]
    ) -> [StoredBatterySample] {
        let ordered = samples.enumerated().sorted { lhs, rhs in
            if lhs.element.date == rhs.element.date { return lhs.offset < rhs.offset }
            return lhs.element.date < rhs.element.date
        }
        var unique: [StoredBatterySample] = []
        for (_, sample) in ordered {
            if unique.last?.date == sample.date {
                unique[unique.count - 1] = sample
            } else {
                unique.append(sample)
            }
        }
        return unique
    }
}
