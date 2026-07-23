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

    @Test("only Session and Today keep shared live power attached")
    func livePowerRanges() {
        #expect(EnergyRange.session.usesLivePower)
        #expect(EnergyRange.today.usesLivePower)
        #expect(!EnergyRange.threeDays.usesLivePower)
        #expect(!EnergyRange.week.usesLivePower)
        #expect(!EnergyRange.allTime.usesLivePower)
    }
}
