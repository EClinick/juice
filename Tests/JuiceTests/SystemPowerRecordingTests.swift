import Foundation
import Testing
@testable import Juice
@testable import JuiceCore

@Suite("System power recording")
struct SystemPowerRecordingTests {
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
}
