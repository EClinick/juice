import Foundation
import Testing
@testable import Juice
import JuiceCore

@Suite struct BatterySessionUsageLoaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ offset: TimeInterval, percent: Int, onAC: Bool) -> StoredBatterySample {
        StoredBatterySample(
            date: now.addingTimeInterval(offset), percent: percent,
            onAC: onAC, isCharging: onAC, watts: onAC ? -20 : 10)
    }

    @Test func loadsExactResolvedWindowAndBatterySummary() async throws {
        actor WindowCapture {
            var value: EnergyWindow?
            func set(_ value: EnergyWindow) { self.value = value }
        }
        let capture = WindowCapture()
        let loader = BatterySessionUsageLoader(
            loadSamples: { _, _ in [
                sample(-3_660, percent: 100, onAC: true),
                sample(-3_600, percent: 100, onAC: false),
                sample(-60, percent: 72, onAC: false),
            ] },
            currentReading: { nil },
            loadApps: { window in
                await capture.set(window)
                return [AppEnergy(bundleId: "zoom", displayName: "Zoom", energyWh: 2.4, cpuHours: 1)]
            })

        let result = await loader.load(now: now)
        let session = try #require(result.session)
        let capturedWindow = await capture.value
        let window = try #require(capturedWindow)
        #expect(result.origin == .live)
        #expect(result.apps.map(\.bundleId) == ["zoom"])
        #expect(session.batteryPercentUsed == 28)
        #expect(window.start == now.addingTimeInterval(-3_600))
        #expect(window.end == now.addingTimeInterval(-60))
    }

    @Test func noBatterySessionIsSuccessfulEmptyStateWithoutEnergyQuery() async {
        actor Counter {
            var value = 0
            func increment() { value += 1 }
        }
        let counter = Counter()
        let loader = BatterySessionUsageLoader(
            loadSamples: { _, _ in [sample(-60, percent: 100, onAC: true)] },
            currentReading: { nil },
            loadApps: { _ in
                await counter.increment()
                return []
            })

        let result = await loader.load(now: now)
        let loadCount = await counter.value
        #expect(result.session == nil)
        #expect(result.origin == .live)
        #expect(loadCount == 0)
    }

    @Test func energyFailurePreservesSessionForHonestErrorUI() async throws {
        struct Expected: LocalizedError { var errorDescription: String? { "helper unavailable" } }
        let loader = BatterySessionUsageLoader(
            loadSamples: { _, _ in [
                sample(-120, percent: 100, onAC: true),
                sample(-60, percent: 99, onAC: false),
            ] },
            currentReading: { nil },
            loadApps: { _ in throw Expected() })

        let result = await loader.load(now: now)
        #expect(result.session != nil)
        #expect(result.origin == .unavailable)
        #expect(result.errorDescription == "helper unavailable")
    }
}
