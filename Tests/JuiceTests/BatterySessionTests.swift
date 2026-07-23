import Foundation
import Testing
@testable import JuiceCore

@Suite struct BatterySessionTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ minutes: Double,
        percent: Int,
        onAC: Bool
    ) -> StoredBatterySample {
        StoredBatterySample(
            date: base.addingTimeInterval(minutes * 60),
            percent: percent,
            onAC: onAC,
            isCharging: onAC,
            watts: onAC ? -20 : 10)
    }

    @Test func resolvesCurrentSessionFromLatestUnplug() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(0, percent: 100, onAC: true),
            sample(1, percent: 100, onAC: false),
            sample(30, percent: 91, onAC: false),
        ]))

        #expect(session.isActive)
        #expect(!session.isStartPartial)
        #expect(session.start == base.addingTimeInterval(60))
        #expect(session.end == base.addingTimeInterval(30 * 60))
        #expect(session.batteryPercentUsed == 9)
    }

    @Test func returnsLastCompletedSessionWhileOnAC() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(0, percent: 100, onAC: true),
            sample(1, percent: 100, onAC: false),
            sample(40, percent: 78, onAC: false),
            sample(41, percent: 78, onAC: true),
            sample(80, percent: 92, onAC: true),
        ]))

        #expect(!session.isActive)
        #expect(session.start == base.addingTimeInterval(60))
        #expect(session.end == base.addingTimeInterval(41 * 60))
        #expect(session.endPercent == 78)
        #expect(session.batteryPercentUsed == 22)
    }

    @Test func reconnectEndsOneSessionAndNextUnplugStartsAnother() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(0, percent: 100, onAC: true),
            sample(1, percent: 100, onAC: false),
            sample(20, percent: 90, onAC: false),
            sample(21, percent: 90, onAC: true),
            sample(22, percent: 90, onAC: false),
            sample(35, percent: 84, onAC: false),
        ]))

        #expect(session.isActive)
        #expect(session.start == base.addingTimeInterval(22 * 60))
        #expect(session.batteryPercentUsed == 6)
    }

    @Test func marksSessionPartialWhenHistoryStartsOffAC() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(10, percent: 82, onAC: false),
            sample(20, percent: 78, onAC: false),
        ]))

        #expect(session.isActive)
        #expect(session.isStartPartial)
    }

    @Test func marksSessionPartialAcrossLongUnobservedBoundaryGap() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(0, percent: 100, onAC: true),
            sample(30, percent: 91, onAC: false),
        ]))

        #expect(session.isStartPartial)
    }

    @Test func crossesCalendarBoundariesWithoutSplitting() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(0, percent: 100, onAC: true),
            sample(1, percent: 100, onAC: false),
            sample(24 * 60 + 30, percent: 45, onAC: false),
        ]))

        #expect(session.isActive)
        #expect(session.duration == (24 * 60 + 29) * 60)
    }

    @Test func duplicateTimestampUsesLastSample() throws {
        let session = try #require(BatterySessionResolver.latest(in: [
            sample(0, percent: 100, onAC: true),
            sample(1, percent: 100, onAC: true),
            sample(1, percent: 100, onAC: false),
            sample(2, percent: 99, onAC: false),
        ]))

        #expect(session.isActive)
        #expect(session.start == base.addingTimeInterval(60))
    }

    @Test func noOffACSamplesMeansNoSession() {
        #expect(BatterySessionResolver.latest(in: [
            sample(0, percent: 80, onAC: true),
            sample(1, percent: 81, onAC: true),
        ]) == nil)
    }
}
