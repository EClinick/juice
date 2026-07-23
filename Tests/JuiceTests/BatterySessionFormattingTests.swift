import Foundation
import Testing
@testable import Juice
import JuiceCore

@Suite struct BatterySessionFormattingTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func completedPartialSessionIsLabeledAsRecorded() {
        let session = BatterySession(
            start: start,
            end: start.addingTimeInterval(3600),
            startPercent: 80,
            endPercent: 70,
            isActive: false,
            isStartPartial: true)

        #expect(BatterySessionFormatting.title(session) == "Recorded battery session")
        #expect(BatterySessionFormatting.boundary(session).hasPrefix("Recorded battery session · "))
    }

    @Test func partialEndIsAlsoLabeledAsRecorded() {
        let session = BatterySession(
            start: start,
            end: start.addingTimeInterval(3600),
            startPercent: 80,
            endPercent: 70,
            isActive: false,
            isStartPartial: false,
            isEndPartial: true)

        #expect(BatterySessionFormatting.title(session) == "Recorded battery session")
        #expect(BatterySessionFormatting.boundary(session).hasPrefix("Recorded battery session · "))
    }
}
