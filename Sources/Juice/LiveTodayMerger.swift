import Foundation
import JuiceCore

/// The hybrid Today list: apps drawing power right now, plus the rest of today's
/// history with the live apps removed.
struct HybridTodayList: Equatable {
    /// One app currently drawing power, with its live watts and (when known)
    /// its accumulated energy for today.
    struct ActiveApp: Equatable, Identifiable {
        var id: String { appKey }
        let appKey: String
        let displayName: String
        let watts: Double
        /// nil when today's history has nothing yet for this app.
        let todayWh: Double?
        /// nil when today's history has nothing yet for this app.
        let todayCpuHours: Double?
    }

    let active: [ActiveApp]
    /// Today's ranking minus the apps shown in `active`.
    let earlier: [AppEnergy]
}

/// Merges a live power reading with today's per-app energy history into the two
/// sections of the hybrid Today view.
///
/// An app enters the active section once its live watts reach the threshold and
/// stays there - even if it briefly drops below - until it has been below the
/// threshold continuously for `idleGraceSeconds`. This grace period stops rows
/// from bouncing between the two sections on brief pauses.
///
/// The merger is pure with respect to the wall clock: `now` is injected so tests
/// can drive a synthetic timeline. Callers must pass `Date()` from the view or
/// controller layer; the merger never reads the clock itself.
struct LiveTodayMerger {
    private let activeThresholdWatts: Double
    private let idleGraceSeconds: Double

    /// The last time an app was seen at or above the threshold. An app is a
    /// grace-period holdover while it is currently below the threshold but was
    /// above it within `idleGraceSeconds`.
    private var lastAboveThreshold: [String: Date] = [:]
    /// The most recent live watts for an app, carried so holdovers keep showing
    /// their decaying value while below the threshold.
    private var lastWatts: [String: Double] = [:]
    /// The most recent display name for an app.
    private var lastDisplayName: [String: String] = [:]
    /// The active display order from the previous merge, so holdovers keep their
    /// relative position after the still-live apps.
    private var previousActiveOrder: [String] = []

    init(activeThresholdWatts: Double = 0.05, idleGraceSeconds: Double = 30) {
        self.activeThresholdWatts = activeThresholdWatts
        self.idleGraceSeconds = idleGraceSeconds
    }

    mutating func merge(live: LivePowerReading?, today: [AppEnergy], now: Date) -> HybridTodayList {
        // Refresh per-app watts and metadata from this tick's live reading.
        if let live {
            for app in live.apps {
                lastWatts[app.appKey] = app.watts
                lastDisplayName[app.appKey] = app.displayName
                if app.watts >= activeThresholdWatts {
                    lastAboveThreshold[app.appKey] = now
                }
            }
        }

        // The live reading's order is hysteresis-stable; keep it for the apps
        // still present this tick.
        let liveOrder = live?.apps.map(\.appKey) ?? []
        let liveKeys = Set(liveOrder)

        // An app is active if it is above the threshold this tick, or if it was
        // above it within the grace window (a holdover still decaying down).
        var activeKeys: [String] = []
        var seen = Set<String>()

        // Still-live apps first, in live order.
        for key in liveOrder where isActive(key, now: now) {
            if seen.insert(key).inserted { activeKeys.append(key) }
        }

        // Grace-period holdovers next, preserving their previous relative order.
        for key in previousActiveOrder where !liveKeys.contains(key) && isActive(key, now: now) {
            if seen.insert(key).inserted { activeKeys.append(key) }
        }

        // Drop bookkeeping for apps that have fully aged out of the grace window
        // so the maps do not grow without bound.
        pruneStaleEntries(now: now, keepAlive: seen)

        previousActiveOrder = activeKeys

        // Index today's history by bundle id so active rows can borrow the Wh
        // value and earlier rows can exclude the active apps.
        let todayByKey = Dictionary(today.map { ($0.bundleId, $0) }, uniquingKeysWith: { a, _ in a })

        let active: [HybridTodayList.ActiveApp] = activeKeys.map { key in
            HybridTodayList.ActiveApp(
                appKey: key,
                displayName: lastDisplayName[key] ?? key,
                watts: lastWatts[key] ?? 0,
                todayWh: todayByKey[key]?.energyWh,
                todayCpuHours: todayByKey[key]?.cpuHours
            )
        }

        let activeSet = Set(activeKeys)
        let earlier = today.filter { !activeSet.contains($0.bundleId) }

        return HybridTodayList(active: active, earlier: earlier)
    }

    mutating func reset() {
        lastAboveThreshold.removeAll()
        lastWatts.removeAll()
        lastDisplayName.removeAll()
        previousActiveOrder.removeAll()
    }

    /// An app counts as active while it has been at or above the threshold
    /// within the last `idleGraceSeconds`.
    private func isActive(_ key: String, now: Date) -> Bool {
        guard let last = lastAboveThreshold[key] else { return false }
        return now.timeIntervalSince(last) < idleGraceSeconds
    }

    private mutating func pruneStaleEntries(now: Date, keepAlive: Set<String>) {
        for key in lastAboveThreshold.keys where !keepAlive.contains(key) {
            lastAboveThreshold[key] = nil
            lastWatts[key] = nil
            lastDisplayName[key] = nil
        }
    }
}
