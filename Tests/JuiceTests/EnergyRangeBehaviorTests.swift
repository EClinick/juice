import Testing
@testable import Juice

@Suite("Energy range behavior")
struct EnergyRangeBehaviorTests {
    @Test("new surfaces focus Session only when unplugged")
    func initialRangeTracksPowerSource() {
        #expect(EnergyRange.initialRange(onAC: false) == .session)
        #expect(EnergyRange.initialRange(onAC: true) == .today)
        #expect(EnergyRange.initialRange(onAC: nil) == .today)
    }

    @Test("Session uses live power only while unplugged; Today always does")
    func livePowerRanges() {
        #expect(EnergyRange.session.usesLivePower(onAC: false))
        #expect(!EnergyRange.session.usesLivePower(onAC: true))
        #expect(!EnergyRange.session.usesLivePower(onAC: nil))
        #expect(EnergyRange.today.usesLivePower(onAC: false))
        #expect(EnergyRange.today.usesLivePower(onAC: true))
        #expect(EnergyRange.today.usesLivePower(onAC: nil))
        #expect(!EnergyRange.threeDays.usesLivePower(onAC: false))
        #expect(!EnergyRange.week.usesLivePower(onAC: false))
        #expect(!EnergyRange.allTime.usesLivePower(onAC: false))
    }
}
