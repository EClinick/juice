import Foundation
import Testing
@testable import JuiceHelper
@testable import JuiceXPCShared

/// Stands in for the `pmset` process so the writer's validation, legacy-key
/// handling, and read-back verification are testable without root.
private final class FakePMSet {
    /// The key this fake machine exposes.
    let key: String
    /// Modes reported by `pmset -g custom`, keyed by section header.
    var battery: Int
    var ac: Int
    /// When true, writes are accepted (exit 0) but change nothing, which is how
    /// hardware that silently declines a mode behaves.
    var ignoresWrites = false
    /// Exit status and stderr for the next write.
    var writeStatus: Int32 = 0
    var writeStderr = ""
    /// Every argv the writer spawned, in order.
    private(set) var invocations: [[String]] = []

    init(key: String = "powermode", battery: Int = 0, ac: Int = 0) {
        self.key = key
        self.battery = battery
        self.ac = ac
    }

    var run: (String, [String]) throws -> PowerModeWriter.CommandResult {
        { [unowned self] executable, arguments in
            #expect(executable == PowerModeWriter.pmsetPath)
            self.invocations.append(arguments)

            if arguments == ["-g", "custom"] {
                return (0, self.customOutput, "")
            }
            guard arguments.count == 3 else {
                return (1, "", "unexpected arguments")
            }
            guard self.writeStatus == 0 else {
                return (self.writeStatus, "", self.writeStderr)
            }
            if !self.ignoresWrites, let value = Int(arguments[2]) {
                switch arguments[0] {
                case "-b": self.battery = value
                case "-c": self.ac = value
                default:
                    self.battery = value
                    self.ac = value
                }
            }
            return (0, "", "")
        }
    }

    private var customOutput: String {
        """
        Battery Power:
         Sleep On Power Button 1
         \(key)         \(battery)
         displaysleep         2
        AC Power:
         Sleep On Power Button 1
         \(key)         \(ac)
         displaysleep         10
        """
    }
}

@Suite("Power mode writer")
struct PowerModeWriterTests {
    @Test("Writes low power to battery only and returns the read-back state")
    func writesBatteryScope() throws {
        let pmset = FakePMSet()
        let writer = PowerModeWriter(runCommand: pmset.run)

        let state = try writer.setPowerMode(rawMode: 1, rawScope: "battery")

        #expect(state == PowerModeState(
            battery: .lowPower, ac: .automatic, usesLegacyLowPowerKey: false))
        // Read, write, read back: the read-back is what the reply reports.
        #expect(pmset.invocations == [
            ["-g", "custom"], ["-b", "powermode", "1"], ["-g", "custom"]
        ])
    }

    @Test("Scope maps to the matching pmset flag", arguments: [
        ("battery", "-b"), ("ac", "-c"), ("all", "-a")
    ])
    func writesEachScope(scope: String, flag: String) throws {
        let pmset = FakePMSet()
        let writer = PowerModeWriter(runCommand: pmset.run)

        _ = try writer.setPowerMode(rawMode: 2, rawScope: scope)

        #expect(pmset.invocations.contains([flag, "powermode", "2"]))
    }

    @Test("Writing .all verifies both power sources")
    func writesAllScope() throws {
        let pmset = FakePMSet(battery: 1, ac: 2)
        let writer = PowerModeWriter(runCommand: pmset.run)

        let state = try writer.setPowerMode(rawMode: 0, rawScope: "all")

        #expect(state == PowerModeState(
            battery: .automatic, ac: .automatic, usesLegacyLowPowerKey: false))
    }

    @Test("Uses the legacy lowpowermode key on machines that expose it")
    func writesLegacyKey() throws {
        let pmset = FakePMSet(key: "lowpowermode")
        let writer = PowerModeWriter(runCommand: pmset.run)

        let state = try writer.setPowerMode(rawMode: 1, rawScope: "all")

        #expect(pmset.invocations.contains(["-a", "lowpowermode", "1"]))
        #expect(state.usesLegacyLowPowerKey)
    }

    @Test("Rejects high power on legacy machines without writing")
    func rejectsHighPowerOnLegacy() throws {
        let pmset = FakePMSet(key: "lowpowermode")
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 2, rawScope: "all")
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .unsupportedPowerMode)
        #expect(pmset.invocations == [["-g", "custom"]])
    }

    @Test("Maps a non-zero pmset exit to powerSettingFailed with its stderr")
    func mapsNonZeroExit() throws {
        let pmset = FakePMSet()
        pmset.writeStatus = 1
        pmset.writeStderr = "pmset: must be run as root"
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 1, rawScope: "all")
        }
        let nsError = try #require(error)

        #expect(HelperError.code(of: nsError) == .powerSettingFailed)
        #expect(nsError.localizedDescription.contains("must be run as root"))
    }

    @Test("Treats a silently ignored write as powerSettingFailed")
    func detectsReadBackMismatch() throws {
        let pmset = FakePMSet()
        pmset.ignoresWrites = true
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 2, rawScope: "all")
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
    }

    @Test("Detects a write that only landed on one power source")
    func detectsPartialAllWrite() throws {
        let pmset = FakePMSet()
        let writer = PowerModeWriter(runCommand: { executable, arguments in
            // Simulate pmset applying -a to AC only.
            let rewritten = arguments.first == "-a" ? ["-c"] + arguments.dropFirst() : arguments
            return try pmset.run(executable, rewritten)
        })

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 1, rawScope: "all")
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
    }

    @Test("Rejects unknown modes and scopes before spawning anything", arguments: [
        (-1, "all"), (3, "all"), (0, "everything"), (0, "")
    ])
    func rejectsInvalidInput(mode: Int, scope: String) throws {
        let pmset = FakePMSet()
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: mode, rawScope: scope)
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .unsupportedPowerMode)
        #expect(pmset.invocations.isEmpty)
    }

    @Test("Surfaces unparsable pmset output as an internal error")
    func mapsUnparsableOutput() throws {
        let writer = PowerModeWriter(runCommand: { _, _ in (0, "no sections here", "") })

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 1, rawScope: "all")
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .internalError)
    }

    @Test("Reads the live machine's state through the real pmset")
    func readsRealState() throws {
        // pmset -g custom needs no privilege, so this must work in CI.
        let state = try PowerModeWriter().readState()
        #expect([PowerMode.automatic, .lowPower, .highPower].contains(state.battery))
    }
}

@Suite("Helper service power mode")
struct HelperServicePowerModeTests {
    @Test("Replies with the encoded read-back state")
    func repliesWithState() throws {
        let pmset = FakePMSet()
        let service = HelperService(powerModeWriter: PowerModeWriter(runCommand: pmset.run))

        var payload: Data?
        var failure: NSError?
        service.setPowerMode(1, scope: "battery") { data, error in
            payload = data
            failure = error
        }

        #expect(failure == nil)
        let state = try JSONDecoder().decode(PowerModeState.self, from: try #require(payload))
        #expect(state.battery == .lowPower)
    }

    @Test("Passes helper-domain errors through unchanged")
    func passesHelperErrorsThrough() throws {
        let pmset = FakePMSet(key: "lowpowermode")
        let service = HelperService(powerModeWriter: PowerModeWriter(runCommand: pmset.run))

        var failure: NSError?
        service.setPowerMode(2, scope: "all") { _, error in failure = error }

        let error = try #require(failure)
        #expect(error.domain == HelperError.domain)
        #expect(HelperError.code(of: error) == .unsupportedPowerMode)
    }

    @Test("Maps a spawn failure to internalError")
    func mapsSpawnFailure() throws {
        struct Boom: Error {}
        let service = HelperService(
            powerModeWriter: PowerModeWriter(runCommand: { _, _ in throw Boom() }))

        var failure: NSError?
        service.setPowerMode(0, scope: "all") { _, error in failure = error }

        let thrown = try #require(failure)
        #expect(HelperError.code(of: thrown) == .internalError)
    }

    @Test("Handshake reports the current protocol version")
    func handshakeVersion() {
        #expect(JuiceXPC.protocolVersion == 4)
    }
}
