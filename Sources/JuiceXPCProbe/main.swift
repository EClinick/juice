import Foundation
import JuiceCore
import JuiceXPCShared

// Dev-only CLI: connects to the helper daemon over XPC, runs a handshake,
// fetches the last 24h of energy intervals, and prints a summary.
// With `--app <key>` it instead prints the per-app energy breakdown for that
// key (bundle id, or launchd name for empty-bundle-id coalitions) - exactly
// what the in-app detail window computes and displays.
// With `set-powermode <0|1|2> [battery|ac|all]` it exercises the helper's
// mutating Energy Mode operation and prints the state read back after the write.
// The binary must be signed with the app's identifier for the helper's
// client check to accept it (see `make dev-probe`).

let usage = "usage: JuiceXPCProbe [--app <key>] | set-powermode <0|1|2> [battery|ac|all]\n"
let arguments = CommandLine.arguments
var appKey: String?
/// Set when invoked in `set-powermode` mode; the probe then skips the fetch.
var powerModeRequest: (mode: Int, scope: String)?

if arguments.count >= 2, arguments[1] == "set-powermode" {
    guard arguments.count >= 3, let mode = Int(arguments[2]) else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    powerModeRequest = (mode, arguments.count >= 4 ? arguments[3] : "all")
} else if let flagIndex = arguments.firstIndex(of: "--app") {
    guard flagIndex + 1 < arguments.count else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    appKey = arguments[flagIndex + 1]
}

let conn = NSXPCConnection(machServiceName: JuiceXPC.machServiceName, options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
conn.invalidationHandler = {
    FileHandle.standardError.write(Data("connection invalidated (helper missing or client rejected)\n".utf8))
}
conn.resume()

let done = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1

guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
    FileHandle.standardError.write(Data("proxy error: \(err)\n".utf8))
    done.signal()
}) as? HelperProtocol else {
    fatalError("could not create proxy")
}

/// The default probe output: interval count and top-5 apps by energy.
func printSummary(_ intervals: [EnergyInterval]) {
    var wh: [String: Double] = [:]
    for i in intervals {
        let key = (i.bundleID?.isEmpty == false ? i.bundleID : i.launchdName) ?? "unknown"
        wh[key, default: 0] += (i.energyNJ + i.gpuEnergyNJ + i.aneEnergyNJ) / 3.6e12
    }
    print("intervals (24h): \(intervals.count)")
    for (app, energy) in wh.sorted(by: { $0.value > $1.value }).prefix(5) {
        print(String(format: "  %@: %.2f Wh", app, energy))
    }
}

/// The `--app` output: the breakdown and explanation the detail window shows.
func printBreakdown(_ intervals: [EnergyInterval], appKey: String) {
    let windowHours = 24
    let breakdown = BreakdownBuilder.build(intervals: intervals, appKey: appKey)
    print("breakdown for \(appKey) (last \(windowHours)h):")
    print(String(format: "  totalWh: %.3f", breakdown.totalWh))
    print(String(format: "  cpuWh: %.3f", breakdown.cpuWh))
    print(String(format: "  gpuWh: %.3f", breakdown.gpuWh))
    print(String(format: "  aneWh: %.3f", breakdown.aneWh))
    print(String(format: "  cpuHours: %.2f", breakdown.cpuHours))
    print(String(format: "  activeHours: %.2f", breakdown.activeHours))
    print("  non-empty hours: \(breakdown.hourlyWh.count)")
    print("explanation:")
    for line in BreakdownBuilder.explanation(for: breakdown, windowHours: windowHours) {
        print("  - \(line)")
    }
}

/// Prints an Energy Mode state, tagging machines limited to Automatic/Low Power.
func printPowerModeState(_ label: String, _ state: PowerModeState) {
    print("\(label): battery=\(state.battery) ac=\(state.ac) key=\(state.pmsetKey)")
}

/// Reads and parses `pmset -g custom` locally; needs no privilege, so it works
/// as a baseline even when the helper is missing.
func localPowerModeState() -> PowerModeState? {
    // Same bounded spawn the app and helper use: a wedged pmset must not park
    // the probe either.
    guard
        let result = try? BoundedProcess.run("/usr/bin/pmset", ["-g", "custom"], deadline: 5),
        result.status == 0
    else {
        return nil
    }
    return try? PowerModeParser.parse(pmsetCustomOutput: result.stdout)
}

proxy.handshake { version, helperVersion in
    print("handshake ok: protocol v\(version), helper \(helperVersion)")

    if let request = powerModeRequest {
        if let current = localPowerModeState() {
            printPowerModeState("current", current)
        }
        guard version >= 4 else {
            FileHandle.standardError.write(
                Data("installed helper is protocol v\(version); set-powermode needs v4\n".utf8))
            done.signal()
            return
        }
        proxy.setPowerMode(request.mode, scope: request.scope) { data, error in
            defer { done.signal() }
            if let error {
                FileHandle.standardError.write(
                    Data("set-powermode error: \(error.localizedDescription)\n".utf8))
                return
            }
            guard let data,
                  let state = try? JSONDecoder().decode(PowerModeState.self, from: data) else {
                FileHandle.standardError.write(Data("set-powermode returned undecodable payload\n".utf8))
                return
            }
            printPowerModeState("after write", state)
            exitCode = 0
        }
        return
    }

    let since = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
    proxy.fetchEnergyIntervals(sinceEpoch: since) { data, error in
        defer { done.signal() }
        if let error {
            FileHandle.standardError.write(Data("fetch error: \(error.localizedDescription)\n".utf8))
            return
        }
        guard let data,
              let intervals = try? JSONDecoder().decode([EnergyInterval].self, from: data) else {
            FileHandle.standardError.write(Data("fetch returned undecodable payload\n".utf8))
            return
        }
        if let appKey {
            printBreakdown(intervals, appKey: appKey)
        } else {
            printSummary(intervals)
        }
        exitCode = 0
    }
}

if done.wait(timeout: .now() + 15) == .timedOut {
    FileHandle.standardError.write(Data("timed out waiting for helper\n".utf8))
}
exit(exitCode)
