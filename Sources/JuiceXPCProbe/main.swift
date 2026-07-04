import Foundation
import JuiceXPCShared

// Dev-only CLI: connects to the helper daemon over XPC, runs a handshake,
// fetches the last 24h of energy intervals, and prints a summary.
// The binary must be signed with the app's identifier for the helper's
// client check to accept it (see `make dev-probe`).

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

proxy.handshake { version, helperVersion in
    print("handshake ok: protocol v\(version), helper \(helperVersion)")
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
        var wh: [String: Double] = [:]
        for i in intervals {
            let key = (i.bundleID?.isEmpty == false ? i.bundleID : i.launchdName) ?? "unknown"
            wh[key, default: 0] += (i.energyNJ + i.gpuEnergyNJ + i.aneEnergyNJ) / 3.6e12
        }
        print("intervals (24h): \(intervals.count)")
        for (app, energy) in wh.sorted(by: { $0.value > $1.value }).prefix(5) {
            print(String(format: "  %@: %.2f Wh", app, energy))
        }
        exitCode = 0
    }
}

if done.wait(timeout: .now() + 15) == .timedOut {
    FileHandle.standardError.write(Data("timed out waiting for helper\n".utf8))
}
exit(exitCode)
