import Foundation

/// Computes which parts of a time window are NOT covered by existing battery
/// samples, so powerlog backfill can import history without ever duplicating
/// the live sampler's data.
///
/// Complements ``ChartSegmentation``: the same gap threshold that makes a
/// chart break its line across a recording gap defines an uncovered region
/// here, so backfill fills exactly the holes the charts would show.
public enum BackfillCoverage {
    /// The default gap threshold, matching ChartSegmentation's default.
    public static let defaultMaxGap: TimeInterval = 120

    /// A contiguous region of a window with no existing sample coverage.
    ///
    /// Edges bounded by an existing sample are exclusive, so a candidate
    /// point carrying exactly an existing sample's timestamp is never
    /// considered uncovered. Edges bounded by the window itself are
    /// inclusive. This makes backfill idempotent: once a point is inserted
    /// it bounds future regions exclusively and can never be re-inserted.
    public struct Region: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// Whether ts == start lies inside the region (window edge: yes;
        /// existing-sample edge: no).
        public var includesStart: Bool
        /// Whether ts == end lies inside the region (window edge: yes;
        /// existing-sample edge: no).
        public var includesEnd: Bool

        public init(start: Double, end: Double, includesStart: Bool, includesEnd: Bool) {
            self.start = start
            self.end = end
            self.includesStart = includesStart
            self.includesEnd = includesEnd
        }

        public func contains(_ ts: Double) -> Bool {
            let afterStart = includesStart ? ts >= start : ts > start
            let beforeEnd = includesEnd ? ts <= end : ts < end
            return afterStart && beforeEnd
        }
    }

    /// Returns the uncovered regions of `[windowStart, windowEnd]` given the
    /// timestamps (epoch seconds, sorted ascending) of existing samples:
    /// before the first sample, between consecutive samples more than
    /// `maxGap` seconds apart, and after the last sample. Samples outside
    /// the window are ignored.
    public static func uncoveredRegions(
        existing: [Double],
        windowStart: Double,
        windowEnd: Double,
        maxGap: TimeInterval = defaultMaxGap
    ) -> [Region] {
        guard windowStart <= windowEnd else { return [] }

        let inWindow = existing.filter { $0 >= windowStart && $0 <= windowEnd }
        guard let first = inWindow.first, let last = inWindow.last else {
            return [Region(
                start: windowStart, end: windowEnd,
                includesStart: true, includesEnd: true)]
        }

        var regions: [Region] = []
        if first > windowStart {
            regions.append(Region(
                start: windowStart, end: first,
                includesStart: true, includesEnd: false))
        }
        for (previous, next) in zip(inWindow, inWindow.dropFirst())
        where next - previous > maxGap {
            regions.append(Region(
                start: previous, end: next,
                includesStart: false, includesEnd: false))
        }
        if last < windowEnd {
            regions.append(Region(
                start: last, end: windowEnd,
                includesStart: false, includesEnd: true))
        }
        return regions
    }

    /// Whether `ts` falls inside any of `regions`.
    public static func contains(_ regions: [Region], _ ts: Double) -> Bool {
        regions.contains { $0.contains(ts) }
    }
}
