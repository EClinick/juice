import Testing
import SwiftUI
import AppKit
import JuiceCore
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

    @Test("live attribution uses whole-system load while charging")
    func chargingAttributionUsesSystemLoad() {
        let attribution = TopAppsView.attribution(
            appWatts: 5,
            batteryWatts: 14,
            systemLoadWatts: 24,
            onAC: true)

        #expect(attribution?.appWatts == 5)
        #expect(attribution?.systemWatts == 19)
    }

    @Test("live attribution continues using battery draw while unplugged")
    func batteryAttributionUsesBatteryDraw() {
        let attribution = TopAppsView.attribution(
            appWatts: 5,
            batteryWatts: 20,
            systemLoadWatts: 100,
            onAC: false)

        #expect(attribution?.appWatts == 5)
        #expect(attribution?.systemWatts == 15)
    }

    @Test("server live watts remain visible for every history range")
    func serverLiveAcrossRanges() {
        for range in [EnergyRange.today, .week, .allTime] {
            #expect(TopAppsView.shouldShowLiveSection(
                range: range,
                showsLiveAcrossRanges: true,
                activeCount: 2))
        }
        #expect(!TopAppsView.shouldShowLiveSection(
            range: .allTime,
            showsLiveAcrossRanges: true,
            activeCount: 0))
    }

    @Test("live watt formatting always includes the unit")
    func liveWattFormatting() {
        #expect(liveWattsText(12.34) == "12.3 W")
        #expect(liveWattsText(0.08) == "0.08 W")
        #expect(liveWattsText(0.004) == "<0.01 W")
        #expect(liveWattsText(0) == "0.00 W")
    }

    @Test("sub-centiwatt chart ticks remain distinguishable")
    func chartWattFormatting() {
        #expect(chartWattsText(0) == "0.00 W")
        #expect(chartWattsText(0.001) == "1.0 mW")
        #expect(chartWattsText(0.002) == "2.0 mW")
        #expect(chartWattsText(0.01) == "0.01 W")
    }

    @Test("positive server energy never rounds to zero")
    func serverEnergyFormatting() {
        #expect(serverEnergyText(0) == "0 Wh")
        #expect(serverEnergyText(0.000_066) == "0.07 mWh")
        #expect(serverEnergyText(0.004_585) == "4.6 mWh")
        #expect(serverEnergyText(0.334) == "0.3 Wh")
        #expect(serverEnergyText(1_250) == "1.25 kWh")
    }

    @Test("server activity duration never rounds a positive value to zero")
    func serverActivityDurationFormatting() {
        #expect(serverActiveDurationText(0) == "0 seconds")
        #expect(serverActiveDurationText(30.0 / 3600) == "30 seconds")
        #expect(serverActiveDurationText(2.0 / 60) == "2 minutes")
        #expect(serverActiveDurationText(1) == "1.0 hour")
        #expect(serverActiveDurationText(1.49) == "1.5 hours")
        #expect(serverActiveDurationText(2) == "2.0 hours")
    }

    @Test("popover and Stats breakdown use one live snapshot formatter")
    func sharedServerPowerBreakdown() {
        let reading = LivePowerReading(
            apps: [],
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: 0.004,
            systemWatts: 1.196)

        #expect(
            serverPowerBreakdownText(reading, includesMeteredTotal: false)
                == "Apps <0.01 W · System processes 1.2 W")
        #expect(
            serverPowerBreakdownText(reading, includesMeteredTotal: true)
                == "Apps <0.01 W · System processes 1.2 W · Metered 1.2 W")
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
                systemLoadWatts: nil,
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
