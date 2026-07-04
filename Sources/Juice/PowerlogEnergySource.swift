import AppKit
import Foundation
import JuiceCore
import JuiceXPCShared

/// An ``EnergySource`` backed by real powerlog data from the privileged
/// helper.
///
/// Not yet wired into the UI; integration happens once the helper is
/// installed (M3+). ``batteryTimeline(hours:until:)`` returns an empty array
/// until M4 introduces the local sample store.
struct PowerlogEnergySource: EnergySource {
    let client: HelperClient

    init(client: HelperClient = HelperClient()) {
        self.client = client
    }

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        let intervals = try await client.fetchIntervals(since: Self.rangeStart(for: range))

        struct Totals {
            var joules: Double = 0
            var cpuSeconds: Double = 0
        }
        var totals: [String: Totals] = [:]
        for interval in intervals {
            // powerlog stores empty-string (not NULL) BundleIds for system
            // coalitions like WindowServer; fall back to LaunchdName for those.
            let bundleID = interval.bundleID.flatMap { $0.isEmpty ? nil : $0 }
            let launchdName = interval.launchdName.flatMap { $0.isEmpty ? nil : $0 }
            guard let key = bundleID ?? launchdName else { continue }
            totals[key, default: Totals()].joules +=
                interval.energyNJ + interval.gpuEnergyNJ + interval.aneEnergyNJ
            totals[key, default: Totals()].cpuSeconds += interval.cpuTime
        }

        return totals
            .map { key, value in
                AppEnergy(
                    bundleId: key,
                    displayName: Self.displayName(for: key),
                    energyWh: value.joules / 3.6e12,
                    cpuHours: value.cpuSeconds / 3600
                )
            }
            .sorted { $0.energyWh > $1.energyWh }
            .prefix(8)
            .map { $0 }
    }

    /// Fetches the raw energy intervals for a single app over `range`.
    ///
    /// `appKey` follows the same keying as ``topApps(range:)``: the bundle id
    /// when present and non-empty, otherwise the launchd coalition name.
    func appIntervals(appKey: String, range: EnergyRange) async throws -> [EnergyInterval] {
        try await client.fetchIntervals(since: Self.rangeStart(for: range))
            .filter { BreakdownBuilder.appKey(for: $0) == appKey }
    }

    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample] {
        // Real timeline data arrives in M4 from the local sample store.
        // Return an empty timeline so the UI renders an empty chart.
        []
    }

    // MARK: - Helpers

    static func rangeStart(for range: EnergyRange, now: Date = Date()) -> Date {
        switch range {
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .threeDays:
            return now.addingTimeInterval(-3 * 24 * 3600)
        case .week:
            return now.addingTimeInterval(-7 * 24 * 3600)
        }
    }

    /// Curated names for identifiers that resolve poorly (or not at all)
    /// through NSWorkspace. Keys are matched case-insensitively.
    private static let curatedNames: [String: String] = [
        "com.apple.windowserver": "WindowServer",
        "com.apple.kernel_task": "macOS Kernel",
        "kernel_task": "macOS Kernel",
        "com.apple.spotlight": "Spotlight",
        // ToDesktop-wrapped apps ship opaque bundle ids; the NSWorkspace
        // lookup below usually resolves them too, but keep the override
        // as belt-and-braces.
        "com.todesktop.230313mzl4w4u92": "Cursor",
    ]

    private static let nameCacheLock = NSLock()
    private static var nameCache: [String: String] = [:]

    /// Human-readable name for a bundle identifier or launchd coalition name:
    /// curated overrides first, then the installed bundle's display name via
    /// NSWorkspace, then a last-dot-component heuristic. Results are cached;
    /// this is called per row per refresh.
    static func displayName(for identifier: String) -> String {
        nameCacheLock.lock()
        if let cached = nameCache[identifier] {
            nameCacheLock.unlock()
            return cached
        }
        nameCacheLock.unlock()

        let name = resolveDisplayName(for: identifier)

        nameCacheLock.lock()
        nameCache[identifier] = name
        nameCacheLock.unlock()
        return name
    }

    private static func resolveDisplayName(for identifier: String) -> String {
        if let curated = curatedNames[identifier.lowercased()] {
            return curated
        }
        if let bundleName = bundleDisplayName(for: identifier) {
            return bundleName
        }
        // Fallback heuristic: last dot-component, capitalized.
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return last.capitalized
    }

    /// Resolves the installed application's display name for a bundle id.
    private static func bundleDisplayName(for identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return nil
        }
        if let bundle = Bundle(url: url),
           let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String),
           !name.isEmpty {
            return name
        }
        var fileName = FileManager.default.displayName(atPath: url.path)
        if fileName.hasSuffix(".app") {
            fileName = String(fileName.dropLast(4))
        }
        return fileName.isEmpty ? nil : fileName
    }
}
