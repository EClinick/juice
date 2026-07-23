import SwiftUI
import AppKit
import JuiceCore
import JuiceXPCShared

/// Opens and manages the per-app energy detail window.
///
/// Mirrors ``StatsWindowPresenter``: a single window is reused across
/// invocations, with its content (and title) swapped to the requested app.
final class AppDetailPresenter {
    static let shared = AppDetailPresenter()

    private var window: NSWindow?

    private init() {}

    func show(
        appKey: String,
        displayName: String,
        range: EnergyRange,
        origin: DataOrigin,
        session: BatterySession? = nil
    ) {
        NSApp.activate(ignoringOtherApps: true)

        // One captured window end anchors the interval query, the chart's
        // x-domain, and the explanation's hour count.
        let windowEnd = session?.end ?? Date()
        let store = Self.usesStoredHistory(range: range, origin: origin)
            ? JuiceApp.sampler?.store : nil
        let formatter = RollupBuilder.dayFormatter()
        let earliestStoredStart = store
            .flatMap { try? $0.earliestRollupDay() }
            .flatMap { formatter.date(from: $0) }
        let windowStart = session?.start ?? Self.windowStart(
            range: range, usesStoredHistory: store != nil,
            earliestStoredStart: earliestStoredStart, now: windowEnd)
        let windowHours = max(1, Int((windowEnd.timeIntervalSince(windowStart) / 3600)
            .rounded(.up)))
        let storedSinceDay = store.map { _ in
            Self.storedQueryStartDay(range: range, now: windowEnd)
        }

        let source = PowerlogEnergySource()
        let root = AppDetailView(
            displayName: displayName,
            bundleId: appKey,
            rangeLabel: session.map(BatterySessionFormatting.title)
                ?? ((range == .week || range == .allTime) && store == nil
                    ? "Available PowerLog history" : range.rawValue),
            windowStart: windowStart,
            windowEnd: windowEnd,
            windowHours: windowHours,
            resolution: store == nil ? .hourlyComponents : .dailyTotals,
            provider: {
                if let store {
                    return try await Task.detached {
                        let formatter = RollupBuilder.dayFormatter()
                        let rollups = try store.rollups(
                            appKey: appKey,
                            sinceDay: storedSinceDay ?? "0000-00-00")
                        return AppEnergyBreakdown(
                            totalWh: rollups.reduce(0) { $0 + $1.wh },
                            cpuWh: 0,
                            gpuWh: 0,
                            aneWh: 0,
                            cpuHours: rollups.reduce(0) { $0 + $1.cpuHours },
                            activeHours: 0,
                            hourlyWh: rollups.compactMap { rollup in
                                formatter.date(from: rollup.day).map {
                                    (bucketStart: $0, wh: rollup.wh)
                                }
                            }
                        )
                    }.value
                }
                let intervals: [EnergyInterval]
                if session != nil {
                    intervals = try await source.appIntervals(
                        appKey: appKey,
                        in: EnergyWindow(start: windowStart, end: windowEnd))
                } else {
                    intervals = try await source.appIntervals(
                        appKey: appKey, since: windowStart)
                }
                return BreakdownBuilder.build(intervals: intervals, appKey: appKey)
            }
        )

        let title = "Juice - \(displayName)"

        if let window {
            // Refresh the content so the reopened window shows the requested app.
            window.contentViewController = NSHostingController(rootView: root)
            window.title = title
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 560))
        window.setFrameAutosaveName("JuiceAppDetailWindow")
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    static func usesStoredHistory(range: EnergyRange, origin: DataOrigin) -> Bool {
        range != .today && range != .session && origin == .store
    }

    static func windowStart(
        range: EnergyRange,
        usesStoredHistory: Bool,
        earliestStoredStart: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Date {
        if usesStoredHistory {
            if range == .allTime {
                return earliestStoredStart ?? now
            }
            let day = StoreEnergySource.sinceDay(
                for: range, now: now, calendar: calendar)
            return RollupBuilder.dayFormatter(calendar: calendar).date(from: day) ?? now
        }
        if range == .session { return now }
        if range == .week || range == .allTime {
            return PowerlogEnergySource.retainedHistoryStart(
                now: now, calendar: calendar)
        }
        return PowerlogEnergySource.rangeStart(
            for: range, now: now, calendar: calendar)
    }

    static func storedQueryStartDay(
        range: EnergyRange,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        StoreEnergySource.sinceDay(for: range, now: now, calendar: calendar)
    }
}
