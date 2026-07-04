import Foundation
import Testing
import JuiceXPCShared
@testable import JuiceCore

/// A fixed calendar so hourly bucketing does not depend on the machine's
/// time zone.
private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2023-11-14 00:00:00 UTC, a round hour boundary.
private let baseEpoch: Double = 1_700_000_000 - 1_700_000_000.truncatingRemainder(dividingBy: 3600)

private func interval(
    start: Double,
    end: Double,
    bundleID: String? = "com.example.app",
    launchdName: String? = nil,
    cpuNJ: Double = 0,
    gpuNJ: Double = 0,
    aneNJ: Double = 0,
    cpuTime: Double = 0
) -> EnergyInterval {
    EnergyInterval(
        start: baseEpoch + start,
        end: baseEpoch + end,
        bundleID: bundleID,
        launchdName: launchdName,
        energyNJ: cpuNJ,
        gpuEnergyNJ: gpuNJ,
        aneEnergyNJ: aneNJ,
        cpuTime: cpuTime
    )
}

@Suite struct BreakdownBuilderTests {
    @Test func convertsNanojoulesToWattHoursPerComponent() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(
                start: 0, end: 600,
                cpuNJ: 3.6e12, gpuNJ: 7.2e12, aneNJ: 1.8e12, cpuTime: 1800)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        #expect(abs(breakdown.cpuWh - 1.0) < 1e-9)
        #expect(abs(breakdown.gpuWh - 2.0) < 1e-9)
        #expect(abs(breakdown.aneWh - 0.5) < 1e-9)
        #expect(abs(breakdown.totalWh - 3.5) < 1e-9)
        #expect(abs(breakdown.cpuHours - 0.5) < 1e-9)
    }

    @Test func sharesSumToOneWhenThereIsEnergy() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(start: 0, end: 60, cpuNJ: 1e12, gpuNJ: 2e12, aneNJ: 3e12)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let sum = breakdown.cpuShare + breakdown.gpuShare + breakdown.aneShare
        #expect(abs(sum - 1.0) < 1e-9)
    }

    @Test func sharesAreZeroWhenTotalIsZero() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(start: 0, end: 60)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        #expect(breakdown.totalWh == 0)
        #expect(breakdown.cpuShare == 0)
        #expect(breakdown.gpuShare == 0)
        #expect(breakdown.aneShare == 0)
    }

    @Test func bucketsByHourOfIntervalStart() {
        // One interval starting at 13:59 (crossing into 14:00) and one
        // starting at 14:30: the first belongs entirely to the 13:00 bucket.
        let breakdown = BreakdownBuilder.build(
            intervals: [
                interval(start: 13 * 3600 + 59 * 60, end: 14 * 3600 + 9 * 60, cpuNJ: 3.6e12),
                interval(start: 14 * 3600 + 30 * 60, end: 14 * 3600 + 40 * 60, cpuNJ: 7.2e12)
            ],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        #expect(breakdown.hourlyWh.count == 2)
        #expect(breakdown.hourlyWh[0].bucketStart
                == Date(timeIntervalSince1970: baseEpoch + 13 * 3600))
        #expect(abs(breakdown.hourlyWh[0].wh - 1.0) < 1e-9)
        #expect(breakdown.hourlyWh[1].bucketStart
                == Date(timeIntervalSince1970: baseEpoch + 14 * 3600))
        #expect(abs(breakdown.hourlyWh[1].wh - 2.0) < 1e-9)
    }

    @Test func filtersToTheRequestedAppByBundleID() {
        let breakdown = BreakdownBuilder.build(
            intervals: [
                interval(start: 0, end: 60, bundleID: "com.example.app", cpuNJ: 3.6e12),
                interval(start: 0, end: 60, bundleID: "com.other.app", cpuNJ: 9e12)
            ],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        #expect(abs(breakdown.totalWh - 1.0) < 1e-9)
    }

    @Test func emptyBundleIDFallsBackToLaunchdName() {
        let breakdown = BreakdownBuilder.build(
            intervals: [
                interval(start: 0, end: 60, bundleID: "", launchdName: "WindowServer", cpuNJ: 3.6e12),
                interval(start: 60, end: 120, bundleID: nil, launchdName: "WindowServer", gpuNJ: 3.6e12),
                // A real bundle id must win over the launchd name.
                interval(start: 120, end: 180, bundleID: "com.example.app",
                         launchdName: "WindowServer", cpuNJ: 9e12)
            ],
            appKey: "WindowServer",
            calendar: utcCalendar
        )
        #expect(abs(breakdown.totalWh - 2.0) < 1e-9)
        #expect(abs(breakdown.cpuWh - 1.0) < 1e-9)
        #expect(abs(breakdown.gpuWh - 1.0) < 1e-9)
    }

    @Test func activeHoursExcludesZeroEnergyIntervals() {
        let breakdown = BreakdownBuilder.build(
            intervals: [
                interval(start: 0, end: 1800, cpuNJ: 3.6e12),
                interval(start: 1800, end: 5400)
            ],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        #expect(abs(breakdown.activeHours - 0.5) < 1e-9)
        // Zero-energy intervals create no hourly bucket either.
        #expect(breakdown.hourlyWh.count == 1)
    }

    @Test func explanationClassifiesCPUDominance() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(start: 0, end: 3600, cpuNJ: 8.7e12, gpuNJ: 1.3e12, cpuTime: 3600)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let lines = BreakdownBuilder.explanation(for: breakdown, windowHours: 24)
        #expect(lines.first?.contains("came from CPU") == true)
        #expect(lines.first?.contains("87%") == true)
    }

    @Test func explanationClassifiesGPUDominance() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(start: 0, end: 3600, cpuNJ: 2e12, gpuNJ: 8e12)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let lines = BreakdownBuilder.explanation(for: breakdown, windowHours: 24)
        #expect(lines.first?.contains("came from the GPU") == true)
    }

    @Test func explanationMentionsNeuralEngineAboveTenPercent() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(start: 0, end: 3600, cpuNJ: 7e12, gpuNJ: 1e12, aneNJ: 2e12)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let lines = BreakdownBuilder.explanation(for: breakdown, windowHours: 24)
        #expect(lines.contains { $0.contains("Neural Engine") })
    }

    @Test func explanationDescribesActivityPatternAndAverageDraw() {
        // Active in 20 of 24 hours: constant background activity.
        let constant = BreakdownBuilder.build(
            intervals: (0..<20).map {
                interval(start: Double($0) * 3600, end: Double($0) * 3600 + 1800, cpuNJ: 3.6e12)
            },
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let constantLines = BreakdownBuilder.explanation(for: constant, windowHours: 24)
        #expect(constantLines.contains { $0.contains("active in 20 of the last 24 hours") })
        #expect(constantLines.contains { $0.contains("roughly constant background activity") })
        // 20 Wh over 10 active hours is 2.0 W on average.
        #expect(constantLines.contains { $0.contains("2.0 W on average while active") })

        // Active in 2 of 24 hours: concentrated bursts.
        let bursty = BreakdownBuilder.build(
            intervals: [
                interval(start: 0, end: 1800, cpuNJ: 3.6e12),
                interval(start: 5 * 3600, end: 5 * 3600 + 1800, cpuNJ: 3.6e12)
            ],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let burstyLines = BreakdownBuilder.explanation(for: bursty, windowHours: 24)
        #expect(burstyLines.contains { $0.contains("concentrated bursts") })
    }

    @Test func explanationIsDeterministic() {
        let breakdown = BreakdownBuilder.build(
            intervals: [interval(start: 0, end: 3600, cpuNJ: 5e12, gpuNJ: 3e12, aneNJ: 2e12)],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let first = BreakdownBuilder.explanation(for: breakdown, windowHours: 24)
        let second = BreakdownBuilder.explanation(for: breakdown, windowHours: 24)
        #expect(first == second)
        #expect((2...4).contains(first.count))
    }

    @Test func explanationGuardsAgainstZeroTotal() {
        let breakdown = BreakdownBuilder.build(
            intervals: [],
            appKey: "com.example.app",
            calendar: utcCalendar
        )
        let lines = BreakdownBuilder.explanation(for: breakdown, windowHours: 24)
        #expect(lines == ["No measurable energy use was recorded for this app in the selected range."])
    }
}
