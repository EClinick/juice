import Foundation
import JuiceXPCShared

// Self-test mode: run the powerlog reader against an arbitrary database
// path and print summary statistics. Used by `make` / CI to validate the
// reader without installing the helper.
//
//   JuiceHelper --selftest /path/to/powerlog.sqlite
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--selftest" {
    let path = CommandLine.arguments[2]
    do {
        let reader = PowerlogReader(databasePath: path)
        let intervals = try reader.fetchIntervals(sinceEpoch: 0)
        print("intervals: \(intervals.count)")

        var totalsByApp: [String: Double] = [:]
        for interval in intervals {
            guard let key = interval.bundleID ?? interval.launchdName else { continue }
            let joules = interval.energyNJ + interval.gpuEnergyNJ + interval.aneEnergyNJ
            totalsByApp[key, default: 0] += joules
        }

        let vsCodeWh = (totalsByApp["com.microsoft.VSCode"] ?? 0) / 3.6e12
        print(String(format: "com.microsoft.VSCode: %.3f Wh", vsCodeWh))

        let topFive = totalsByApp.sorted { $0.value > $1.value }.prefix(5)
        for (app, nanojoules) in topFive {
            print(String(format: "  %@: %.3f Wh", app, nanojoules / 3.6e12))
        }

        let levels = try reader.fetchBatteryLevels(sinceEpoch: 0)
        print("battery levels: \(levels.count)")
        if let firstLevel = levels.first, let lastLevel = levels.last {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone.current
            print("  first: \(formatter.string(from: Date(timeIntervalSince1970: firstLevel.ts))) (\(firstLevel.ts))")
            print("  last:  \(formatter.string(from: Date(timeIntervalSince1970: lastLevel.ts))) (\(lastLevel.ts))")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("selftest failed: \(error)\n".utf8))
        exit(1)
    }
}

// Normal mode: serve the privileged XPC Mach service.
NSLog("JuiceHelper: \(ListenerDelegate.securityMode)")
HelperService.prepareRuntimeIdentity()
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: JuiceXPC.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
