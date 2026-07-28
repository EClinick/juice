import Foundation
import Testing
@testable import Juice
@testable import JuiceCore

@Suite("System power recording")
struct SystemPowerRecordingTests {
    private func reading(appWatts: Double, systemWatts: Double = 0) -> LivePowerReading {
        let apps = appWatts > 0
            ? [AppPowerReading(
                appKey: "test.app",
                bundlePath: "/Applications/Test.app",
                displayName: "Test",
                watts: appWatts)]
            : []
        return LivePowerReading(
            apps: apps,
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: appWatts,
            systemWatts: systemWatts)
    }

    @Test("Recorder persists at most once per minute")
    func minuteCadence() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-power-test-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let recorder = SamplerService(store: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        await recorder.recordSystemPower(10, at: t0)
        await recorder.recordSystemPower(20, at: t0.addingTimeInterval(30))
        await recorder.recordSystemPower(30, at: t0.addingTimeInterval(60))

        let samples = try store.systemPowerSamples(
            since: t0,
            until: t0.addingTimeInterval(120))
        #expect(samples == [
            StoredSystemPowerSample(date: t0, watts: 10),
            StoredSystemPowerSample(date: t0.addingTimeInterval(60), watts: 30),
        ])
    }

    @Test("Recorder rejects invalid readings")
    func invalidReadings() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-power-test-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let recorder = SamplerService(store: store)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await recorder.recordSystemPower(-1, at: now)
        await recorder.recordSystemPower(.infinity, at: now)

        #expect(try store.systemPowerSamples(
            since: .distantPast,
            until: .distantFuture).isEmpty)
    }

    @Test("Short app workloads are integrated between minute samples")
    func integratesEveryLiveReading() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-power-test-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let recorder = SamplerService(store: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        await recorder.recordServerReading(reading(appWatts: 0), at: t0)
        await recorder.recordServerReading(
            reading(appWatts: 60),
            at: t0.addingTimeInterval(2))
        await recorder.recordServerReading(
            reading(appWatts: 0),
            at: t0.addingTimeInterval(4))
        await recorder.recordServerReading(
            reading(appWatts: 0),
            at: t0.addingTimeInterval(60))

        let totals = try store.systemAppEnergyTotals(
            since: t0,
            until: t0.addingTimeInterval(120))
        let expectedWh = 60.0 * 2 / 3600

        #expect(totals.count == 1)
        #expect(abs((totals.first?.energyWh ?? 0) - expectedWh) < 1e-9)
        #expect(totals.first?.activeDuration == 4)

        let samples = try store.systemPowerSamples(
            since: t0,
            until: t0.addingTimeInterval(120))
        let summary = SystemPowerAnalytics.summary(
            samples: samples,
            windowStart: t0,
            windowEnd: t0.addingTimeInterval(60))
        #expect(abs(summary.energyWh - expectedWh) < 1e-9)
        #expect(summary.averageWatts == 2)
        #expect(summary.peakWatts == 60)
        #expect(summary.coveredDuration == 60)
    }

    @Test("Non-monotonic server readings are ignored")
    func ignoresNonMonotonicReadings() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-power-test-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let recorder = SamplerService(store: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        await recorder.recordServerReading(reading(appWatts: 10), at: t0)
        await recorder.recordServerReading(
            reading(appWatts: 20),
            at: t0.addingTimeInterval(2))
        await recorder.recordServerReading(
            reading(appWatts: 100),
            at: t0.addingTimeInterval(1))
        await recorder.recordServerReading(
            reading(appWatts: 20),
            at: t0.addingTimeInterval(60))

        let totals = try store.systemAppEnergyTotals(
            since: t0,
            until: t0.addingTimeInterval(120))
        let expectedJoules: Double = 30 + 1_160
        let expectedWh = expectedJoules / 3_600

        #expect(abs((totals.first?.energyWh ?? 0) - expectedWh) < 1e-9)
    }

    @Test("Termination flush persists the pending system and app tail")
    func flushesPendingTail() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-power-test-\(UUID().uuidString).sqlite").path
        let store = try JuiceStore(path: path)
        let recorder = SamplerService(store: store)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        await recorder.recordServerReading(reading(appWatts: 0), at: t0)
        await recorder.recordServerReading(
            reading(appWatts: 60),
            at: t0.addingTimeInterval(2))
        await recorder.recordServerReading(
            reading(appWatts: 0),
            at: t0.addingTimeInterval(4))
        await recorder.flushServerHistory()

        let system = try store.systemPowerSamples(
            since: t0,
            until: t0.addingTimeInterval(4))
        let apps = try store.systemAppEnergyTotals(
            since: t0,
            until: t0.addingTimeInterval(4))
        #expect(system.count == 1)
        #expect(apps.count == 1)
        #expect(abs((system.first?.energyWh ?? 0) - (60.0 * 2 / 3600)) < 1e-9)
        #expect(abs((apps.first?.energyWh ?? 0) - (60.0 * 2 / 3600)) < 1e-9)
    }
}
