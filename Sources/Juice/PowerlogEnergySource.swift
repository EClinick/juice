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
    enum QueryError: LocalizedError {
        case sessionRequiresWindow

        var errorDescription: String? {
            "Battery-session energy needs an exact start and end time."
        }
    }

    let client: HelperClient

    init(client: HelperClient = HelperClient()) {
        self.client = client
    }

    func topApps(range: EnergyRange) async throws -> [AppEnergy] {
        guard range != .session else { throw QueryError.sessionRequiresWindow }
        let intervals = try await client.fetchIntervals(since: Self.rangeStart(for: range))
        return Self.aggregate(intervals: intervals)
    }

    /// Per-app energy for an exact window. Only fully-contained powerlog
    /// intervals are included: a boundary bucket can straddle an unplug or
    /// reconnect, and silently assigning all of it to the battery session would
    /// count energy used on the wrong power source.
    func topApps(in window: EnergyWindow) async throws -> [AppEnergy] {
        Self.aggregate(intervals: try await intervals(in: window))
    }

    func intervals(in window: EnergyWindow) async throws -> [EnergyInterval] {
        guard window.end >= window.start else { return [] }
        let intervals = try await client.fetchIntervals(since: window.start)
        return Self.intervals(intervals, fullyContainedIn: window)
    }

    static func intervals(
        _ intervals: [EnergyInterval],
        fullyContainedIn window: EnergyWindow
    ) -> [EnergyInterval] {
        let start = window.start.timeIntervalSince1970
        let end = window.end.timeIntervalSince1970
        return intervals.filter {
            $0.start >= start && $0.end >= $0.start && $0.end <= end
        }
    }

    static func aggregate(intervals: [EnergyInterval]) -> [AppEnergy] {
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
                    cpuHours: value.cpuSeconds / 3600)
            }
            .sorted {
                if $0.energyWh == $1.energyWh { return $0.bundleId < $1.bundleId }
                return $0.energyWh > $1.energyWh
            }
    }

    /// Fetches the raw energy intervals for a single app over `range`.
    ///
    /// `appKey` follows the same keying as ``topApps(range:)``: the bundle id
    /// when present and non-empty, otherwise the launchd coalition name.
    func appIntervals(appKey: String, range: EnergyRange) async throws -> [EnergyInterval] {
        guard range != .session else { throw QueryError.sessionRequiresWindow }
        return try await appIntervals(appKey: appKey, since: Self.rangeStart(for: range))
    }

    func appIntervals(appKey: String, since: Date) async throws -> [EnergyInterval] {
        try await client.fetchIntervals(since: since)
            .filter { BreakdownBuilder.appKey(for: $0) == appKey }
    }

    func appIntervals(appKey: String, in window: EnergyWindow) async throws -> [EnergyInterval] {
        try await intervals(in: window)
            .filter { BreakdownBuilder.appKey(for: $0) == appKey }
    }

    func batteryTimeline(hours: Int, until: Date) async throws -> [BatterySample] {
        // Real timeline data arrives in M4 from the local sample store.
        // Return an empty timeline so the UI renders an empty chart.
        []
    }

    // MARK: - Helpers

    static func rangeStart(
        for range: EnergyRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        switch range {
        case .session:
            // Session callers must provide EnergyWindow. Returning `now` keeps
            // this total helper deterministic without inventing a calendar
            // interpretation; public query methods reject this case above.
            return now
        case .today:
            return calendar.startOfDay(for: now)
        case .threeDays:
            return now.addingTimeInterval(-3 * 24 * 3600)
        case .week, .allTime:
            return retainedHistoryStart(now: now, calendar: calendar)
        }
    }

    static func retainedHistoryStart(
        now: Date,
        calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: .day, value: -3, to: now) ?? now
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
