import Foundation
import Testing
import JuiceXPCShared
@testable import JuiceCore

@Suite struct RollupBuilderTests {
    /// A fixed calendar so day boundaries do not depend on the machine's zone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func epoch(_ year: Int, _ month: Int, _ day: Int, hour: Int) -> Double {
        let components = DateComponents(year: year, month: month, day: day, hour: hour)
        return utcCalendar.date(from: components)!.timeIntervalSince1970
    }

    private func interval(
        start: Double,
        bundleID: String?,
        launchdName: String? = nil,
        energyNJ: Double,
        gpuEnergyNJ: Double = 0,
        aneEnergyNJ: Double = 0,
        cpuTime: Double = 0
    ) -> EnergyInterval {
        EnergyInterval(
            start: start, end: start + 300,
            bundleID: bundleID, launchdName: launchdName,
            energyNJ: energyNJ, gpuEnergyNJ: gpuEnergyNJ,
            aneEnergyNJ: aneEnergyNJ, cpuTime: cpuTime)
    }

    @Test func groupsByDayAndAppAndSumsEnergy() throws {
        let day1Morning = epoch(2026, 7, 1, hour: 9)
        let day1Evening = epoch(2026, 7, 1, hour: 21)
        let day2 = epoch(2026, 7, 2, hour: 10)

        let intervals = [
            // VS Code, day 1: two intervals, CPU+GPU+ANE energy.
            interval(
                start: day1Morning, bundleID: "com.microsoft.VSCode",
                energyNJ: 3.0e12, gpuEnergyNJ: 1.0e12, aneEnergyNJ: 0.4e12,
                cpuTime: 1800),
            interval(
                start: day1Evening, bundleID: "com.microsoft.VSCode",
                energyNJ: 1.0e12, cpuTime: 900),
            // Safari, day 1.
            interval(
                start: day1Morning, bundleID: "com.apple.Safari",
                energyNJ: 1.8e12, cpuTime: 360),
            // VS Code again on day 2: must land in a separate rollup.
            interval(
                start: day2, bundleID: "com.microsoft.VSCode",
                energyNJ: 7.2e12, cpuTime: 3600),
            // Empty bundleID falls back to the launchd coalition name.
            interval(
                start: day2, bundleID: "", launchdName: "WindowServer",
                energyNJ: 3.6e12, cpuTime: 7200),
        ]

        let rollups = RollupBuilder.dailyRollups(from: intervals, calendar: utcCalendar)
        #expect(rollups.count == 4)

        func rollup(_ day: String, _ appKey: String) -> DailyEnergyRollup? {
            rollups.first { $0.day == day && $0.appKey == appKey }
        }

        // VS Code day 1: (3.0 + 1.0 + 0.4 + 1.0)e12 nJ = 5.4e12 nJ = 1.5 Wh;
        // 2700 s CPU = 0.75 h.
        let vscodeDay1 = try #require(rollup("2026-07-01", "com.microsoft.VSCode"))
        #expect(abs(vscodeDay1.wh - 1.5) < 0.0005)
        #expect(abs(vscodeDay1.cpuHours - 0.75) < 0.0005)

        // Safari day 1: 1.8e12 nJ = 0.5 Wh; 360 s = 0.1 h.
        let safari = try #require(rollup("2026-07-01", "com.apple.Safari"))
        #expect(abs(safari.wh - 0.5) < 0.0005)
        #expect(abs(safari.cpuHours - 0.1) < 0.0005)

        // VS Code day 2: 7.2e12 nJ = 2.0 Wh; 3600 s = 1.0 h.
        let vscodeDay2 = try #require(rollup("2026-07-02", "com.microsoft.VSCode"))
        #expect(abs(vscodeDay2.wh - 2.0) < 0.0005)
        #expect(abs(vscodeDay2.cpuHours - 1.0) < 0.0005)

        // WindowServer day 2 (keyed by launchd name): 3.6e12 nJ = 1.0 Wh; 2 h CPU.
        let windowServer = try #require(rollup("2026-07-02", "WindowServer"))
        #expect(abs(windowServer.wh - 1.0) < 0.0005)
        #expect(abs(windowServer.cpuHours - 2.0) < 0.0005)
    }

    @Test func skipsIntervalsWithoutAnyAppKey() {
        let start = epoch(2026, 7, 1, hour: 12)
        let intervals = [
            interval(start: start, bundleID: nil, launchdName: nil, energyNJ: 1e12),
            interval(start: start, bundleID: "", launchdName: "", energyNJ: 1e12),
        ]
        #expect(RollupBuilder.dailyRollups(from: intervals, calendar: utcCalendar).isEmpty)
    }

    @Test func emptyInputYieldsEmptyOutput() {
        #expect(RollupBuilder.dailyRollups(from: [], calendar: utcCalendar).isEmpty)
    }
}
