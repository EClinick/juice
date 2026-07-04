import Foundation

/// Splits chronologically sorted sample arrays into contiguous runs so charts
/// never draw a line or a tint across a recording gap.
public struct ChartSegmentation {
    /// Splits `samples` (sorted ascending by date) into contiguous segments,
    /// starting a new segment wherever consecutive samples are more than
    /// `maxGap` seconds apart.
    public static func segments<S>(
        _ samples: [S],
        date: (S) -> Date,
        maxGap: TimeInterval = 120
    ) -> [[S]] {
        guard let first = samples.first else { return [] }
        var result: [[S]] = []
        var current: [S] = [first]
        for sample in samples.dropFirst() {
            if let last = current.last, date(sample).timeIntervalSince(date(last)) > maxGap {
                result.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        result.append(current)
        return result
    }

    /// Contiguous on-AC periods that never bridge a recording gap: an AC run
    /// breaks at any gap larger than `maxGap`, even if the samples on both
    /// sides of the gap are on AC.
    public static func acRuns<S>(
        _ samples: [S],
        date: (S) -> Date,
        onAC: (S) -> Bool,
        maxGap: TimeInterval = 120
    ) -> [(start: Date, end: Date)] {
        var runs: [(start: Date, end: Date)] = []
        for segment in segments(samples, date: date, maxGap: maxGap) {
            var runStart: Date?
            for sample in segment {
                if onAC(sample) {
                    if runStart == nil { runStart = date(sample) }
                } else if let start = runStart {
                    runs.append((start: start, end: date(sample)))
                    runStart = nil
                }
            }
            if let start = runStart, let last = segment.last {
                runs.append((start: start, end: date(last)))
            }
        }
        return runs
    }
}
