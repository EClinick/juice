import Foundation
import JuiceXPCShared

/// One app's live power draw, ready for display.
public struct AppPowerReading: Identifiable, Equatable, Sendable {
    public var id: String { appKey }
    /// Bundle id when resolvable from the .app bundle path, else a stable key
    /// (executable path).
    public let appKey: String
    /// Bundle path if the process chain resolves to a .app bundle, else nil.
    public let bundlePath: String?
    /// Display name derived from the bundle or executable name.
    public let displayName: String
    /// EMA-smoothed watts.
    public let watts: Double

    public init(appKey: String, bundlePath: String?, displayName: String, watts: Double) {
        self.appKey = appKey
        self.bundlePath = bundlePath
        self.displayName = displayName
        self.watts = watts
    }
}

/// The model's per-tick output.
public struct LivePowerReading: Equatable, Sendable {
    /// Ranked apps above the idle threshold, in display order (hysteresis
    /// applied).
    public let apps: [AppPowerReading]
    /// Apps folded below the idle threshold.
    public let idleAppCount: Int
    public let idleWatts: Double
    /// Total smoothed watts across all attributed apps (idle + ranked), not
    /// including the system bucket.
    public let totalAppWatts: Double
    /// Smoothed watts for processes that could not be attributed to any .app.
    public let systemWatts: Double

    public init(
        apps: [AppPowerReading],
        idleAppCount: Int,
        idleWatts: Double,
        totalAppWatts: Double,
        systemWatts: Double
    ) {
        self.apps = apps
        self.idleAppCount = idleAppCount
        self.idleWatts = idleWatts
        self.totalAppWatts = totalAppWatts
        self.systemWatts = systemWatts
    }
}

/// Differentiates consecutive raw energy snapshots into smoothed, ranked
/// per-app power readings.
///
/// The model is pure and deterministic: it consumes only the values inside the
/// snapshots (including `timestampEpoch`) and never reads the wall clock, so
/// tests can drive it with synthetic timelines.
public final class LivePowerModel {
    // Configuration.
    private let halfLifeSeconds: Double
    private let idleThresholdWatts: Double
    private let hysteresisRatio: Double
    private let hysteresisTicks: Int

    // Per-coalition baseline from the previous snapshot: the three cumulative
    // energy counters. A coalition absent from a snapshot drops its baseline; a
    // re-appearing coalition id re-baselines with no delta that tick.
    private struct Baseline {
        let cpuEnergyNJ: UInt64
        let gpuEnergyNJ: UInt64
        let aneEnergyNJ: UInt64
    }
    private var baselines: [UInt64: Baseline] = [:]
    private var lastTimestamp: Double?

    // Smoothed watts per app key, carried across ticks so absent apps decay.
    private var smoothedWatts: [String: Double] = [:]
    // Metadata per app key, kept fresh so display survives ticks where the app
    // is momentarily absent but still smoothing down.
    private var appMeta: [String: (bundlePath: String?, displayName: String)] = [:]
    // Previous ranked display order (app keys) for hysteresis.
    private var previousOrder: [String] = []
    // Consecutive-tick counter of how long an app has beaten the neighbor
    // directly above it in the previous order by more than the ratio.
    private var beatStreak: [String: Int] = [:]

    // Bundle-identifier resolution cache: .app path -> bundle id (or nil).
    private var bundleIDCache: [String: String?] = [:]

    public init(
        halfLifeSeconds: Double = 5,
        idleThresholdWatts: Double = 0.05,
        hysteresisRatio: Double = 0.15,
        hysteresisTicks: Int = 2
    ) {
        self.halfLifeSeconds = halfLifeSeconds
        self.idleThresholdWatts = idleThresholdWatts
        self.hysteresisRatio = hysteresisRatio
        self.hysteresisTicks = hysteresisTicks
    }

    /// Forget all state (popover closed / range left).
    public func reset() {
        baselines.removeAll()
        lastTimestamp = nil
        smoothedWatts.removeAll()
        appMeta.removeAll()
        previousOrder.removeAll()
        beatStreak.removeAll()
        // Bundle-id lookups are stable for a path; keep the cache.
    }

    /// Feed one snapshot; returns nil until two snapshots establish a delta.
    public func ingest(_ snapshot: LiveEnergySnapshot) -> LivePowerReading? {
        defer { updateBaselines(from: snapshot) }

        guard let previousTimestamp = lastTimestamp else {
            // First snapshot: only establishes a baseline.
            return nil
        }
        let dt = snapshot.timestampEpoch - previousTimestamp
        // A non-positive or absurd dt cannot produce meaningful watts. Reset the
        // baseline (done by the defer) and emit nothing this tick.
        guard dt > 0 else { return nil }

        // 1. Per-coalition instantaneous watts from the energy delta, summing
        // the CPU, GPU, and ANE domains.
        var wattsByCoalition: [UInt64: Double] = [:]
        for sample in snapshot.samples {
            let watts: Double
            if let base = baselines[sample.coalitionID] {
                // Sum the three domains; clamp each negative delta (a counter
                // reset when a coalition id is recycled) to 0 independently.
                let dCPU = deltaNJ(sample.cpuEnergyNJ, base.cpuEnergyNJ)
                let dGPU = deltaNJ(sample.gpuEnergyNJ, base.gpuEnergyNJ)
                let dANE = deltaNJ(sample.aneEnergyNJ, base.aneEnergyNJ)
                watts = (dCPU + dGPU + dANE) / dt / 1e9
            } else {
                // New (or re-appearing) coalition id: no delta this tick.
                watts = 0
            }
            wattsByCoalition[sample.coalitionID] = watts
        }

        // 2. Attribute each coalition's watts to an app, or to the system bucket.
        let attribution = attribute(snapshot: snapshot)
        var instantaneousByApp: [String: Double] = [:]
        var systemInstantaneous = 0.0
        for sample in snapshot.samples {
            let watts = wattsByCoalition[sample.coalitionID] ?? 0
            if let app = attribution.appKeyByCoalition[sample.coalitionID] {
                instantaneousByApp[app, default: 0] += watts
            } else {
                systemInstantaneous += watts
            }
        }

        // 3. EMA smoothing. Every known app (present or not) decays toward its
        // instantaneous value; absent apps see 0 and decay downward.
        let alpha = emaAlpha(dt: dt)
        let systemKey = Self.systemKey
        var allKeys = Set(smoothedWatts.keys)
        allKeys.formUnion(instantaneousByApp.keys)
        allKeys.insert(systemKey)

        for key in allKeys {
            let target = key == systemKey ? systemInstantaneous : (instantaneousByApp[key] ?? 0)
            let prior = smoothedWatts[key] ?? 0
            let smoothed = prior + alpha * (target - prior)
            // Prune apps that have decayed to nothing and are drawing nothing,
            // so a long session with app churn does not grow state without
            // bound. A pruned app re-enters cleanly the tick it draws again.
            if key != systemKey, smoothed < Self.pruneFloorWatts, target < Self.pruneFloorWatts {
                smoothedWatts[key] = nil
                appMeta[key] = nil
            } else {
                smoothedWatts[key] = smoothed
            }
        }

        // Refresh metadata for apps seen this tick.
        for (key, meta) in attribution.metaByAppKey {
            appMeta[key] = meta
        }

        // 4. Build ranked apps with hysteresis, idle fold, and system bucket.
        return buildReading()
    }

    /// Cumulative counters only increase; a decrease means the coalition id was
    /// recycled, so clamp the delta to 0.
    private func deltaNJ(_ current: UInt64, _ base: UInt64) -> Double {
        current >= base ? Double(current - base) : 0
    }

    // MARK: - Attribution

    private struct Attribution {
        var appKeyByCoalition: [UInt64: String]
        var metaByAppKey: [String: (bundlePath: String?, displayName: String)]
    }

    /// Maps each coalition to an app key from its leader's executable path via
    /// the outermost .app ancestor. Coalitions sharing one .app (e.g. a
    /// browser's per-renderer coalitions, all under the same app bundle) map to
    /// the same key and so sum downstream. Coalitions whose leader path has no
    /// enclosing .app (or is empty) are left unattributed (system bucket).
    private func attribute(snapshot: LiveEnergySnapshot) -> Attribution {
        var resolved: [UInt64: String] = [:]
        var meta: [String: (bundlePath: String?, displayName: String)] = [:]

        for sample in snapshot.samples {
            guard let bundlePath = Self.outermostAppBundlePath(sample.leaderPath) else { continue }
            let key = appKey(forBundlePath: bundlePath)
            resolved[sample.coalitionID] = key
            if meta[key] == nil {
                meta[key] = (bundlePath: bundlePath, displayName: Self.displayName(bundlePath: bundlePath, executablePath: sample.leaderPath))
            }
        }

        return Attribution(appKeyByCoalition: resolved, metaByAppKey: meta)
    }

    // MARK: - Path / bundle helpers

    /// Returns the path of the OUTERMOST .app bundle enclosing `executablePath`,
    /// or nil if the path is not inside any .app. Outermost so helper bundles
    /// nested inside a parent .app (e.g. Electron/browser GPU helpers) roll up
    /// under the parent app.
    static func outermostAppBundlePath(_ executablePath: String) -> String? {
        guard !executablePath.isEmpty else { return nil }
        let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        // Find the first component ending in ".app" (outermost, scanning from
        // the filesystem root downward).
        for (index, component) in components.enumerated() where component.hasSuffix(".app") {
            let prefix = components[0...index].joined(separator: "/")
            return prefix
        }
        return nil
    }

    /// A stable identity for an app: its resolved bundle id, else the .app path.
    private func appKey(forBundlePath bundlePath: String) -> String {
        if let bundleID = resolveBundleID(bundlePath: bundlePath) {
            return bundleID
        }
        return bundlePath
    }

    /// Resolves the bundle identifier from a .app path, caching the (possibly
    /// nil) result since it is stable for a given path.
    private func resolveBundleID(bundlePath: String) -> String? {
        if let cached = bundleIDCache[bundlePath] { return cached }
        let url = URL(fileURLWithPath: bundlePath)
        let bundleID = Bundle(url: url)?.bundleIdentifier
        bundleIDCache[bundlePath] = bundleID
        return bundleID
    }

    /// Display name: the .app directory name without extension, else the
    /// executable basename.
    static func displayName(bundlePath: String, executablePath: String) -> String {
        let appName = (bundlePath as NSString).lastPathComponent
        if appName.hasSuffix(".app") {
            return String(appName.dropLast(4))
        }
        return (executablePath as NSString).lastPathComponent
    }

    // MARK: - EMA

    /// Converts the half-life and wall-clock spacing to a per-tick EMA weight.
    /// alpha = 1 - 2^(-dt / halfLife), so one half-life of elapsed time halves
    /// the distance to the target regardless of tick spacing.
    private func emaAlpha(dt: Double) -> Double {
        guard halfLifeSeconds > 0 else { return 1 }
        return 1 - pow(2.0, -dt / halfLifeSeconds)
    }

    // MARK: - Ranking / assembly

    private static let systemKey = "\u{0}system"

    /// Below a tenth of a milliwatt an app is indistinguishable from silence;
    /// entries this small are dropped rather than smoothed forever.
    private static let pruneFloorWatts = 0.0001

    private func buildReading() -> LivePowerReading {
        let systemWatts = max(0, smoothedWatts[Self.systemKey] ?? 0)

        // Candidate app entries (everything except the system bucket).
        var entries: [(key: String, watts: Double)] = []
        for (key, watts) in smoothedWatts where key != Self.systemKey {
            entries.append((key, max(0, watts)))
        }

        // Split idle from active.
        let active = entries.filter { $0.watts >= idleThresholdWatts }
        let idle = entries.filter { $0.watts < idleThresholdWatts }

        let idleWatts = idle.reduce(0) { $0 + $1.watts }
        let totalAppWatts = entries.reduce(0) { $0 + $1.watts }

        // Rank active apps with hysteresis against the previous order.
        let orderedKeys = rankWithHysteresis(active: active)

        let wattsByKey = Dictionary(active.map { ($0.key, $0.watts) }, uniquingKeysWith: { a, _ in a })
        let apps: [AppPowerReading] = orderedKeys.compactMap { key in
            guard let watts = wattsByKey[key] else { return nil }
            let meta = appMeta[key]
            return AppPowerReading(
                appKey: key,
                bundlePath: meta?.bundlePath,
                displayName: meta?.displayName ?? key,
                watts: watts
            )
        }

        return LivePowerReading(
            apps: apps,
            idleAppCount: idle.count,
            idleWatts: idleWatts,
            totalAppWatts: totalAppWatts,
            systemWatts: systemWatts
        )
    }

    /// Applies rank hysteresis. An app may only move up past the neighbor
    /// directly above it in the previous order once it has exceeded that
    /// neighbor's watts by more than `hysteresisRatio` for `hysteresisTicks`
    /// consecutive ingests. New apps enter at their sorted position.
    private func rankWithHysteresis(active: [(key: String, watts: Double)]) -> [String] {
        let wattsByKey = Dictionary(active.map { ($0.key, $0.watts) }, uniquingKeysWith: { a, _ in a })
        let activeKeys = Set(wattsByKey.keys)

        // Sorted-by-watts order is the reference the hysteresis nudges toward.
        // Ties break on key for determinism.
        let sortedKeys = active.sorted {
            if $0.watts != $1.watts { return $0.watts > $1.watts }
            return $0.key < $1.key
        }.map(\.key)

        // Start from the previous order, keeping only still-active apps, then
        // append newcomers at their sorted position.
        var order = previousOrder.filter { activeKeys.contains($0) }
        let known = Set(order)
        for key in sortedKeys where !known.contains(key) {
            // Insert the newcomer at its sorted position relative to current
            // order.
            let watts = wattsByKey[key] ?? 0
            var insertAt = order.count
            for (index, existing) in order.enumerated() {
                let existingWatts = wattsByKey[existing] ?? 0
                if watts > existingWatts || (watts == existingWatts && key < existing) {
                    insertAt = index
                    break
                }
            }
            order.insert(key, at: insertAt)
        }

        // Bubble each app up past its immediate predecessor when it has
        // sustained a large-enough lead for enough ticks. One adjacent swap per
        // pass, repeated, so streaks are evaluated pairwise and deterministically.
        updateBeatStreaks(order: order, wattsByKey: wattsByKey)

        var changed = true
        var guardCounter = 0
        let maxPasses = order.count * order.count + 1
        while changed && guardCounter < maxPasses {
            changed = false
            guardCounter += 1
            var index = 1
            while index < order.count {
                let upper = order[index - 1]
                let lower = order[index]
                let upperWatts = wattsByKey[upper] ?? 0
                let lowerWatts = wattsByKey[lower] ?? 0
                if lowerWatts > upperWatts * (1 + hysteresisRatio),
                   (beatStreak[lower] ?? 0) >= hysteresisTicks {
                    order.swapAt(index - 1, index)
                    changed = true
                }
                index += 1
            }
        }

        previousOrder = order
        return order
    }

    /// Increments the beat streak for an app that currently exceeds the app
    /// directly above it (in the pre-swap order) by more than the ratio, and
    /// resets it otherwise. Evaluated on the order after newcomer insertion but
    /// before swapping, so a sustained lead accumulates over consecutive ticks.
    private func updateBeatStreaks(order: [String], wattsByKey: [String: Double]) {
        let activeKeys = Set(order)
        // Drop streaks for apps no longer active.
        for key in beatStreak.keys where !activeKeys.contains(key) {
            beatStreak[key] = nil
        }
        var index = 1
        while index < order.count {
            let upper = order[index - 1]
            let lower = order[index]
            let upperWatts = wattsByKey[upper] ?? 0
            let lowerWatts = wattsByKey[lower] ?? 0
            if lowerWatts > upperWatts * (1 + hysteresisRatio) {
                beatStreak[lower, default: 0] += 1
            } else {
                beatStreak[lower] = 0
            }
            index += 1
        }
    }

    // MARK: - Baseline bookkeeping

    private func updateBaselines(from snapshot: LiveEnergySnapshot) {
        // Replace (not merge) so a coalition absent this tick drops its
        // baseline; if its id reappears later it re-baselines with no delta.
        var next: [UInt64: Baseline] = [:]
        next.reserveCapacity(snapshot.samples.count)
        for sample in snapshot.samples {
            next[sample.coalitionID] = Baseline(
                cpuEnergyNJ: sample.cpuEnergyNJ,
                gpuEnergyNJ: sample.gpuEnergyNJ,
                aneEnergyNJ: sample.aneEnergyNJ
            )
        }
        baselines = next
        lastTimestamp = snapshot.timestampEpoch
    }
}
