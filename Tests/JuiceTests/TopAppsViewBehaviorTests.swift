import Testing
import SwiftUI
import AppKit
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

    @MainActor
    @Test("range picker renders only the configured tabs")
    func rangePickerUsesConfiguredTabs() {
        let controller = NSHostingController(
            rootView: TopAppsView(
                apps: [],
                range: .constant(.today),
                origin: .store,
                ranges: [.session, .today, .week, .allTime],
                hybrid: nil,
                batteryWatts: nil,
                totalAppWatts: nil,
                session: nil)
                .frame(width: 320, height: 100)
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        controller.view.layoutSubtreeIfNeeded()

        let picker = segmentedControl(in: controller.view)
        #expect(picker != nil)
        #expect(picker?.segmentCount == 4)
        #expect(
            (0..<(picker?.segmentCount ?? 0)).map { picker?.label(forSegment: $0) }
                == ["Session", "Today", "Week", "All"])
    }

    @MainActor
    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl {
            return control
        }
        return view.subviews.lazy.compactMap(segmentedControl(in:)).first
    }
}
