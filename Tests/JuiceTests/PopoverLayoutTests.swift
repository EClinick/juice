import AppKit
import SwiftUI
import Testing
@testable import Juice
@testable import JuiceXPCShared

@MainActor
@Suite("Popover layout")
struct PopoverLayoutTests {
    @Test("scroll hint appears only while content remains below")
    func scrollHintVisibility() {
        let documentBounds = CGRect(x: 0, y: 0, width: 320, height: 900)

        #expect(
            PopoverScrollHintVisibility.shouldShow(
                documentBounds: documentBounds,
                visibleRect: CGRect(x: 0, y: 0, width: 320, height: 600),
                isFlipped: true))
        #expect(
            !PopoverScrollHintVisibility.shouldShow(
                documentBounds: documentBounds,
                visibleRect: CGRect(x: 0, y: 300, width: 320, height: 600),
                isFlipped: true))
        #expect(
            PopoverScrollHintVisibility.shouldShow(
                documentBounds: documentBounds,
                visibleRect: CGRect(x: 0, y: 300, width: 320, height: 600),
                isFlipped: false))
        #expect(
            !PopoverScrollHintVisibility.shouldShow(
                documentBounds: documentBounds,
                visibleRect: CGRect(x: 0, y: 0, width: 320, height: 600),
                isFlipped: false))
        #expect(
            !PopoverScrollHintVisibility.shouldShow(
                documentBounds: CGRect(x: 0, y: 0, width: 320, height: 600),
                visibleRect: CGRect(x: 0, y: 0, width: 320, height: 600),
                isFlipped: true))
    }

    @Test("dashboard scrolling keeps actions outside the viewport")
    func dashboardScrollingKeepsActionsVisible() throws {
        let controller = NSHostingController(
            rootView: VStack(alignment: .leading, spacing: 10) {
                PopoverDashboardViewport(height: 120) {
                    VStack {
                        ForEach(0..<20, id: \.self) { index in
                            Text("Dashboard row \(index)")
                        }
                    }
                }

                Divider()
                FooterMarker()
                    .frame(height: 20)
            }
            .frame(width: 320)
        )
        controller.view.frame = NSRect(
            origin: .zero,
            size: controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: controller.view))
        let footer = try #require(firstSubview(of: FooterMarkerView.self, in: controller.view))
        let scrollFrame = scrollView.convert(scrollView.bounds, to: controller.view)
        let footerFrame = footer.convert(footer.bounds, to: controller.view)

        #expect(abs(scrollFrame.height - 120) < 1)
        #expect(!footer.isDescendant(of: scrollView))
        #expect(!scrollFrame.intersects(footerFrame))
        #expect(controller.view.bounds.contains(footerFrame))
    }

    @Test("short dashboard shrinks instead of leaving space above actions")
    func shortDashboardShrinksToContent() async throws {
        let controller = NSHostingController(
            rootView: VStack(alignment: .leading, spacing: 10) {
                PopoverDashboardViewport(height: 120) {
                    Color.clear.frame(height: 40)
                }

                Divider()
                FooterMarker()
                    .frame(height: 20)
            }
            .frame(width: 320)
        )
        controller.view.frame = NSRect(
            origin: .zero,
            size: controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: controller.view))
        let scrollFrame = scrollView.convert(scrollView.bounds, to: controller.view)

        // The one-point bottom scroll target is part of the measured document.
        #expect(abs(scrollFrame.height - 41) < 1)
    }

    @Test("release updater scrolls with the dashboard while actions stay fixed")
    func releaseUpdaterStaysInsideViewport() throws {
        let controller = NSHostingController(
            rootView: VStack(alignment: .leading, spacing: 10) {
                PopoverDashboardViewport(height: 120) {
                    VStack(spacing: 10) {
                        Color.clear.frame(height: 180)
                        ReleaseUpdaterMarker()
                            .frame(height: 80)
                    }
                }

                Divider()
                FooterMarker()
                    .frame(height: 20)
            }
            .frame(width: 320)
        )
        controller.view.frame = NSRect(
            origin: .zero,
            size: controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: controller.view))
        let updater = try #require(firstSubview(
            of: ReleaseUpdaterMarkerView.self,
            in: controller.view))
        let footer = try #require(firstSubview(of: FooterMarkerView.self, in: controller.view))

        #expect(updater.isDescendant(of: scrollView))
        #expect(!footer.isDescendant(of: scrollView))
        #expect(controller.view.bounds.contains(footer.convert(footer.bounds, to: controller.view)))
    }

    @Test("scroll cue button jumps the viewport to the bottom")
    func scrollCueButtonJumpsToBottom() async throws {
        let controller = NSHostingController(
            rootView: PopoverDashboardViewport(height: 120) {
                VStack {
                    ForEach(0..<20, id: \.self) { index in
                        Text("Dashboard row \(index)")
                    }
                }
            }
            .frame(width: 320)
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 320, height: 120))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: controller.view))
        let buttonY = controller.view.isFlipped
            ? controller.view.bounds.maxY - 18
            : controller.view.bounds.minY + 18
        let clickPoint = controller.view.convert(
            NSPoint(x: controller.view.bounds.midX, y: buttonY),
            to: nil)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: eventType,
                location: clickPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1))
            NSApplication.shared.sendEvent(event)
        }

        let documentView = try #require(scrollView.documentView)
        for _ in 0..<100 {
            controller.view.layoutSubtreeIfNeeded()
            let visibleRect = documentView.convert(
                scrollView.contentView.bounds,
                from: scrollView.contentView)
            if !PopoverScrollHintVisibility.shouldShow(
                documentBounds: documentView.bounds,
                visibleRect: visibleRect,
                isFlipped: documentView.isFlipped
            ) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let visibleRect = documentView.convert(
            scrollView.contentView.bounds,
            from: scrollView.contentView)
        #expect(
            !PopoverScrollHintVisibility.shouldShow(
                documentBounds: documentView.bounds,
                visibleRect: visibleRect,
                isFlipped: documentView.isFlipped))
    }

    @Test("hero headline and detail lines describe each power source")
    func heroLines() {
        let onBattery = reading(percent: 62, watts: 8.42, onAC: false)
        #expect(
            EnergyModePresentation.headline(onBattery, timeRemainingText: "3h 10m remaining")
                == "3h 10m remaining")
        #expect(
            EnergyModePresentation.detail(onBattery)
                == "Drawing 8.4 W · Health 91% · 120 cycles")

        let charging = reading(
            percent: 62, watts: -21.5, onAC: true, isCharging: true)
        #expect(
            EnergyModePresentation.headline(charging, timeRemainingText: "ignored")
                == "Charging at 21.5 W")
        #expect(EnergyModePresentation.detail(charging) == "Health 91% · 120 cycles")

        let held = reading(percent: 100, watts: 0, onAC: true)
        #expect(
            EnergyModePresentation.headline(held, timeRemainingText: "ignored")
                == "Plugged in, not charging")

        var unknownHealth = onBattery
        unknownHealth.healthPercent = nil
        #expect(EnergyModePresentation.detail(unknownHealth) == "Drawing 8.4 W · 120 cycles")
    }

    @Test("selection and the cross-source footnote follow the active source")
    func modeSelectionFollowsPowerSource() {
        let mixed = PowerModeState(
            battery: .lowPower, ac: .highPower, usesLegacyLowPowerKey: false)

        #expect(EnergyModePresentation.currentMode(mixed, onAC: false) == .lowPower)
        #expect(EnergyModePresentation.currentMode(mixed, onAC: true) == .highPower)
        #expect(
            EnergyModePresentation.otherSourceFootnote(mixed, onAC: false)
                == "Plugged in: High Power")
        #expect(
            EnergyModePresentation.otherSourceFootnote(mixed, onAC: true)
                == "On battery: Low Power")

        let matched = PowerModeState(
            battery: .automatic, ac: .automatic, usesLegacyLowPowerKey: false)
        #expect(EnergyModePresentation.otherSourceFootnote(matched, onAC: false) == nil)
        #expect(EnergyModePresentation.otherSourceFootnote(nil, onAC: false) == nil)
        #expect(EnergyModePresentation.currentMode(nil, onAC: false) == nil)
    }

    @Test("the picker drops High Power when it is unsupported")
    func pickerHidesHighPower() {
        #expect(
            EnergyModePresentation.modes(showsHighPower: true)
                == [.lowPower, .automatic, .highPower])
        #expect(
            EnergyModePresentation.modes(showsHighPower: false)
                == [.lowPower, .automatic])
    }

    @Test("the gauge falls back to charge-level colour without mode state")
    func gaugeTintFallback() {
        #expect(
            EnergyModePresentation.gaugeTint(
                mode: .lowPower, percent: 12, onAC: false, isLowPowerModeEnabled: false)
                == .yellow)
        #expect(
            EnergyModePresentation.gaugeTint(
                mode: .highPower, percent: 90, onAC: true, isLowPowerModeEnabled: false)
                == .cyan)
        #expect(
            EnergyModePresentation.gaugeTint(
                mode: nil, percent: 12, onAC: false, isLowPowerModeEnabled: false)
                == .red)
        #expect(
            EnergyModePresentation.gaugeTint(
                mode: nil, percent: 80, onAC: false, isLowPowerModeEnabled: true)
                == .yellow)
        #expect(
            EnergyModePresentation.gaugeTint(
                mode: nil, percent: 80, onAC: false, isLowPowerModeEnabled: false)
                == .gray)
    }

    @Test("the hero block stays compact enough for the popover's top zone")
    func heroBlockFitsTopZone() {
        let controller = NSHostingController(
            rootView: VStack(alignment: .leading, spacing: 8) {
                BatteryHeroRow(
                    reading: reading(percent: 62, watts: 8.42, onAC: false),
                    timeRemainingText: "3h 10m remaining",
                    mode: .lowPower,
                    isLowPowerModeEnabled: true)
                EnergyModePicker(controller: energyModeController(), onAC: false)
            }
            .frame(width: 292)
        )
        controller.view.frame = NSRect(
            origin: .zero,
            size: controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()

        // Gauge row plus one button row: the replaced header, dividers, and
        // health caption used more vertical space than this.
        #expect(controller.view.fittingSize.height > 58)
        #expect(controller.view.fittingSize.height < 130)
    }

    private func energyModeController() -> EnergyModeController {
        let suiteName = "PopoverLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let controller = EnergyModeController(
            defaults: defaults,
            readState: {
                PowerModeState(
                    battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: false)
            },
            writeState: { _, _ in
                PowerModeState(
                    battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: false)
            })
        return controller
    }

    private func reading(
        percent: Int,
        watts: Double,
        onAC: Bool,
        isCharging: Bool = false
    ) -> BatteryReading {
        BatteryReading(
            percent: percent,
            watts: watts,
            isCharging: isCharging,
            onAC: onAC,
            timeRemainingMinutes: 190,
            cycleCount: 120,
            healthPercent: 91,
            hasBattery: true)
    }

    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in view: NSView,
        matching predicate: @escaping (ViewType) -> Bool = { _ in true }
    ) -> ViewType? {
        if let match = view as? ViewType, predicate(match) {
            return match
        }
        return view.subviews.lazy.compactMap {
            firstSubview(of: type, in: $0, matching: predicate)
        }.first
    }

}

private final class FooterMarkerView: NSView {}
private final class ReleaseUpdaterMarkerView: NSView {}

private struct FooterMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> FooterMarkerView {
        FooterMarkerView()
    }

    func updateNSView(_ nsView: FooterMarkerView, context: Context) {}
}

private struct ReleaseUpdaterMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> ReleaseUpdaterMarkerView {
        ReleaseUpdaterMarkerView()
    }

    func updateNSView(_ nsView: ReleaseUpdaterMarkerView, context: Context) {}
}
