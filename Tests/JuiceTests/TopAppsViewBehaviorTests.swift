import Testing
@testable import Juice

@Suite("Top apps view behavior")
struct TopAppsViewBehaviorTests {
    @Test("expanded live view keeps cumulative app rows visible")
    func expandedLiveKeepsHistory() {
        let plan = TopAppsView.cumulativeRowCounts(
            activeCount: 4,
            appCount: 20,
            liveExpanded: true)

        #expect(plan.visible == 3)
        #expect(plan.folded == 17)
    }

    @Test("collapsing Live restores the full cumulative row budget")
    func collapsedLiveExpandsHistory() {
        let plan = TopAppsView.cumulativeRowCounts(
            activeCount: 4,
            appCount: 20,
            liveExpanded: false)

        #expect(plan.visible == 7)
        #expect(plan.folded == 13)
    }

    @Test("expanded live view never removes cumulative history entirely")
    func crowdedLiveSectionKeepsHistory() {
        let plan = TopAppsView.cumulativeRowCounts(
            activeCount: 12,
            appCount: 20,
            liveExpanded: true)

        #expect(plan.visible == 1)
        #expect(plan.folded == 19)
    }
}
