import Testing
import Foundation
import JuiceCore
@testable import Juice

@Suite struct LiveTodayMergerTests {
    private func liveApp(_ key: String, watts: Double, name: String? = nil) -> AppPowerReading {
        AppPowerReading(appKey: key, bundlePath: nil, displayName: name ?? key, watts: watts)
    }

    private func reading(_ apps: [AppPowerReading]) -> LivePowerReading {
        LivePowerReading(
            apps: apps,
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: apps.reduce(0) { $0 + $1.watts },
            systemWatts: 0)
    }

    private func energy(_ bundleId: String, wh: Double, name: String? = nil) -> AppEnergy {
        AppEnergy(bundleId: bundleId, displayName: name ?? bundleId, energyWh: wh, cpuHours: 0)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func splitsActiveFromEarlierByThreshold() {
        var merger = LiveTodayMerger(activeThresholdWatts: 0.05)
        let live = reading([liveApp("a", watts: 4.1), liveApp("b", watts: 0.01)])
        let today = [energy("a", wh: 2.0), energy("c", wh: 1.0)]

        let result = merger.merge(live: live, today: today, now: t0)

        #expect(result.active.map(\.appKey) == ["a"])
        // "a" is excluded from earlier; "b" was never in history; "c" remains.
        #expect(result.earlier.map(\.bundleId) == ["c"])
    }

    @Test func activeAppMatchesTodayWh() {
        var merger = LiveTodayMerger()
        let live = reading([liveApp("a", watts: 4.1), liveApp("b", watts: 1.0)])
        let today = [energy("a", wh: 2.0)]

        let result = merger.merge(live: live, today: today, now: t0)

        let a = result.active.first { $0.appKey == "a" }
        let b = result.active.first { $0.appKey == "b" }
        #expect(a?.todayWh == 2.0)
        // "b" has no history yet, so its subtext value is nil.
        #expect(b?.todayWh == nil)
    }

    @Test func gracePeriodKeepsAppActiveUntilElapsed() {
        var merger = LiveTodayMerger(activeThresholdWatts: 0.05, idleGraceSeconds: 30)
        _ = merger.merge(live: reading([liveApp("a", watts: 4.0)]), today: [], now: t0)

        // 10 s later "a" drops below the threshold but is still within grace.
        let during = merger.merge(
            live: reading([liveApp("a", watts: 0.01)]),
            today: [],
            now: t0.addingTimeInterval(10))
        #expect(during.active.map(\.appKey) == ["a"])

        // 40 s after the last above-threshold tick, grace has elapsed.
        let after = merger.merge(
            live: reading([liveApp("a", watts: 0.01)]),
            today: [],
            now: t0.addingTimeInterval(40))
        #expect(after.active.isEmpty)
    }

    @Test func resetClearsState() {
        var merger = LiveTodayMerger(idleGraceSeconds: 30)
        _ = merger.merge(live: reading([liveApp("a", watts: 4.0)]), today: [], now: t0)
        merger.reset()

        // After reset, an app below threshold with no fresh above-threshold tick
        // is not held over.
        let result = merger.merge(
            live: reading([liveApp("a", watts: 0.01)]),
            today: [],
            now: t0.addingTimeInterval(1))
        #expect(result.active.isEmpty)
    }

    @Test func preservesLiveOrderWithHoldoversAfter() {
        var merger = LiveTodayMerger(activeThresholdWatts: 0.05, idleGraceSeconds: 30)
        // Establish "c" as active first.
        _ = merger.merge(live: reading([liveApp("c", watts: 3.0)]), today: [], now: t0)

        // Next tick: "a" then "b" are live (that order), "c" drops below but is
        // still in grace. Live apps come first in live order, holdover last.
        let result = merger.merge(
            live: reading([
                liveApp("a", watts: 5.0),
                liveApp("b", watts: 2.0),
                liveApp("c", watts: 0.0),
            ]),
            today: [],
            now: t0.addingTimeInterval(5))

        #expect(result.active.map(\.appKey) == ["a", "b", "c"])
    }
}
