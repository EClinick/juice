import Foundation
import Testing
@testable import Juice
import JuiceXPCShared

@Suite struct SessionEnergyWindowTests {
    private func interval(
        start: Double,
        end: Double,
        bundle: String? = "com.example.app",
        launchd: String? = nil,
        energyWh: Double = 1,
        cpuHours: Double = 0.5
    ) -> EnergyInterval {
        EnergyInterval(
            start: start,
            end: end,
            bundleID: bundle,
            launchdName: launchd,
            energyNJ: energyWh * 3.6e12,
            gpuEnergyNJ: 0,
            aneEnergyNJ: 0,
            cpuTime: cpuHours * 3600)
    }

    @Test func exactWindowKeepsOnlyFullyContainedIntervals() {
        let window = EnergyWindow(
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200))
        let kept = PowerlogEnergySource.intervals([
            interval(start: 90, end: 110),
            interval(start: 100, end: 120),
            interval(start: 180, end: 200),
            interval(start: 190, end: 210),
            interval(start: 160, end: 150),
        ], fullyContainedIn: window)

        #expect(kept.map(\.start) == [100, 180])
    }

    @Test func aggregationCombinesEnergyDomainsAndUsesLaunchdFallback() throws {
        var gpu = interval(start: 100, end: 110, energyWh: 1, cpuHours: 0.25)
        gpu.gpuEnergyNJ = 2 * 3.6e12
        let rows = PowerlogEnergySource.aggregate(intervals: [
            gpu,
            interval(start: 110, end: 120, energyWh: 3, cpuHours: 0.75),
            interval(start: 100, end: 110, bundle: "", launchd: "WindowServer", energyWh: 2),
        ])

        let app = try #require(rows.first { $0.bundleId == "com.example.app" })
        #expect(abs(app.energyWh - 6) < 1e-9)
        #expect(abs(app.cpuHours - 1) < 1e-9)
        #expect(rows.contains { $0.bundleId == "WindowServer" })
    }
}
