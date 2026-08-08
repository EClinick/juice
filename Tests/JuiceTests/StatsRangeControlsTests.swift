import AppKit
import SwiftUI
import Testing
@testable import Juice

@MainActor
@Suite("Stats range controls")
struct StatsRangeControlsTests {
    @Test("shared range picker is pinned to the leading edge")
    func rangePickerLeadingAlignment() throws {
        let controller = NSHostingController(
            rootView: StatsRangePickerRow(
                title: "Range",
                selection: .constant(.today),
                ranges: StatsRangeVisibility.defaultRanges,
                pickerWidth: 380,
                label: \.pickerLabel)
                .frame(width: 720, height: 50, alignment: .leading)
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 50)
        controller.view.layoutSubtreeIfNeeded()

        let picker = try #require(segmentedControl(in: controller.view))
        let pickerFrame = picker.convert(picker.bounds, to: controller.view)
        #expect(pickerFrame.minX < 1)
        #expect(picker.segmentCount == StatsRangeVisibility.defaultRanges.count)
    }

    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl {
            return control
        }
        return view.subviews.lazy.compactMap(segmentedControl(in:)).first
    }
}
