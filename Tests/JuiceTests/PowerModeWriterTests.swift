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
    /// The deadline the writer handed each spawn, in order.
    private(set) var deadlines: [TimeInterval] = []
    /// Seconds of wall clock each spawn burns, so a shared budget visibly shrinks.
    var secondsPerCommand: TimeInterval = 0
    /// Applied to the read-back output only, standing in for another writer that
    /// changed the mode between the write and the verification.
    var interferingValue: Int?

    init(key: String = "powermode", battery: Int = 0, ac: Int = 0) {
        self.key = key
        self.battery = battery
        self.ac = ac
    }

    var run: (String, [String], TimeInterval) throws -> PowerModeWriter.CommandResult {
        { [unowned self] executable, arguments, deadline in
            #expect(executable == PowerModeWriter.pmsetPath)
            self.invocations.append(arguments)
            self.deadlines.append(deadline)
            if self.secondsPerCommand > 0 { Thread.sleep(forTimeInterval: self.secondsPerCommand) }

            if arguments == ["-g", "custom"] {
                if let interfering = self.interferingValue, self.invocations.count > 1 {
                    self.battery = interfering
                    self.ac = interfering
                }
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

    @Test("Treats a silently ignored high-power write as hardware refusal")
    func detectsHighPowerRefusal() throws {
        let pmset = FakePMSet()
        pmset.ignoresWrites = true
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 2, rawScope: "all")
        }

        // Accepted by pmset and dropped by the machine: the only honest signal
        // that this Mac has no High Power.
        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .unsupportedPowerMode)
        #expect(thrown.localizedDescription.contains("unchanged from before the write"))
    }

    @Test("Treats a read-back changed by someone else as transient, not unsupported")
    func externalWriterIsNotHardwareRefusal() throws {
        let pmset = FakePMSet()
        pmset.ignoresWrites = true
        // Another writer - System Settings, or a second client - moves the mode
        // to Low Power between the High Power write and the read-back.
        pmset.interferingValue = 1
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 2, rawScope: "all")
        }

        // The mode moved, so the hardware never refused anything: reporting
        // this as unsupported would hide High Power for good over a race.
        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
        #expect(thrown.localizedDescription.contains("something else changed"))
    }

    @Test("Treats a silently ignored write of any other mode as transient")
    func detectsReadBackMismatch() throws {
        let pmset = FakePMSet(battery: 2, ac: 2)
        pmset.ignoresWrites = true
        let writer = PowerModeWriter(runCommand: pmset.run)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 1, rawScope: "all")
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
    }

    @Test("Detects a write that only landed on one power source")
    func detectsPartialAllWrite() throws {
        let pmset = FakePMSet()
        let writer = PowerModeWriter(runCommand: { executable, arguments, deadline in
            // Simulate pmset applying -a to AC only.
            let rewritten = arguments.first == "-a" ? ["-c"] + arguments.dropFirst() : arguments
            return try pmset.run(executable, rewritten, deadline)
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
        let writer = PowerModeWriter(runCommand: { _, _, _ in (0, "no sections here", "") })

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

    @Test("Concurrent callers never interleave a read/write/read-back transaction")
    func serializesTransactions() {
        let probe = TransactionProbe()

        // Separate writers on real threads, as separate XPC connections get:
        // the guarantee has to hold process-wide, not per instance. The lock
        // wait is generous here because this test is about ordering, not about
        // the busy timeout that ``lockWaitIsBounded`` covers.
        DispatchQueue.concurrentPerform(iterations: 4) { tag in
            let writer = PowerModeWriter(runCommand: probe.run(tag: tag), lockWait: 30)
            _ = try? writer.setPowerMode(rawMode: 1, rawScope: "battery")
        }

        let log = probe.log
        #expect(log.count == 12)
        // Each caller's three spawns must appear as one unbroken run.
        let runs = log.reduce(into: [[TransactionProbe.Entry]]()) { runs, entry in
            if var last = runs.last, last.first?.tag == entry.tag {
                last.append(entry)
                runs[runs.count - 1] = last
            } else {
                runs.append([entry])
            }
        }
        #expect(runs.count == 4)
        for run in runs {
            #expect(run.map(\.arguments) == [
                ["-g", "custom"], ["-b", "powermode", "1"], ["-g", "custom"]
            ])
        }
    }

    @Test("A queued transaction gives up instead of outlasting its client")
    func lockWaitIsBounded() throws {
        let holdingLock = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        let holder = PowerModeWriter(runCommand: { _, arguments, _ in
            guard arguments != ["-g", "custom"] else {
                return (0, "Battery Power:\n powermode 0\nAC Power:\n powermode 0\n", "")
            }
            // Inside the transaction, so the process-wide lock is held.
            holdingLock.signal()
            releaseHolder.wait()
            return (0, "", "")
        })
        DispatchQueue.global().async {
            _ = try? holder.setPowerMode(rawMode: 1, rawScope: "battery")
            holderFinished.signal()
        }
        holdingLock.wait()

        let pmset = FakePMSet()
        // A short wait proves the bound without spending the production one.
        let queued = PowerModeWriter(runCommand: pmset.run, lockWait: 0.2)
        let started = Date()
        let error = #expect(throws: NSError.self) {
            try queued.setPowerMode(rawMode: 1, rawScope: "battery")
        }
        let waited = Date().timeIntervalSince(started)
        releaseHolder.signal()
        holderFinished.wait()

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
        #expect(thrown.localizedDescription.contains("another Energy Mode change is in progress"))
        #expect(waited < 2)
        // It gave up before touching pmset, so the machine was never half-set.
        #expect(pmset.invocations.isEmpty)
    }

    @Test("One budget is shared by the transaction's three commands")
    func transactionBudgetIsShared() throws {
        let pmset = FakePMSet()
        pmset.secondsPerCommand = 0.15
        let writer = PowerModeWriter(runCommand: pmset.run)

        _ = try writer.setPowerMode(rawMode: 1, rawScope: "battery")

        #expect(pmset.deadlines.count == 3)
        // Each command is handed what is left of the transaction, never a fresh
        // deadline of its own: three fresh ones would let a wedged pmset park
        // the helper for 30 s while the client gave up at 12 s.
        #expect(pmset.deadlines[0] <= PowerModeWriter.transactionDeadline)
        #expect(pmset.deadlines[1] <= pmset.deadlines[0] - 0.1)
        #expect(pmset.deadlines[2] <= pmset.deadlines[1] - 0.1)
        #expect(pmset.deadlines[2] > 0)
    }

    @Test("An exhausted budget refuses to start the privileged write")
    func exhaustedBudgetNeverSpawnsTheWrite() throws {
        let pmset = FakePMSet()
        // The initial read burns the entire (tiny) budget, so the transaction
        // must fail BEFORE the write spawns: launching a mutation after the
        // deadline would change the machine after the client already gave up.
        pmset.secondsPerCommand = 0.15
        let writer = PowerModeWriter(runCommand: pmset.run, transactionBudget: 0.1)

        let error = #expect(throws: NSError.self) {
            try writer.setPowerMode(rawMode: 1, rawScope: "battery")
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
        #expect(thrown.localizedDescription.contains("deadline passed before the write"))
        #expect(pmset.invocations == [["-g", "custom"]])
    }
}

/// Records which caller spawned what, and lingers inside the write so an
/// unserialized transaction would visibly interleave.
private final class TransactionProbe: @unchecked Sendable {
    struct Entry {
        let tag: Int
        let arguments: [String]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var log: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func run(tag: Int) -> (String, [String], TimeInterval) throws -> PowerModeWriter.CommandResult {
        { [self] _, arguments, _ in
            lock.lock()
            entries.append(Entry(tag: tag, arguments: arguments))
            lock.unlock()

            guard arguments == ["-g", "custom"] else {
                Thread.sleep(forTimeInterval: 0.02)
                return (0, "", "")
            }
            return (0, "Battery Power:\n powermode 1\nAC Power:\n powermode 0\n", "")
        }
    }
}

@Suite("Bounded process")
struct BoundedProcessTests {
    @Test("Returns status and output for a command that exits")
    func capturesOutput() throws {
        let result = try BoundedProcess.run("/bin/echo", ["hello"], deadline: 5)
        #expect(result.status == 0)
        #expect(result.stdout == "hello\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("Drains both pipes past a single pipe buffer without deadlocking")
    func drainsBothPipes() throws {
        // dd writes 256 KB to stdout and its summary to stderr, so reading
        // either one to EOF before the other would wedge.
        let result = try BoundedProcess.run(
            "/bin/dd", ["if=/dev/zero", "bs=1024", "count=256"], deadline: 20)
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == 256 * 1024)
        #expect(!result.stderr.isEmpty)
    }

    @Test("Terminates a command that outstays its deadline")
    func enforcesDeadline() throws {
        let started = Date()
        let failure = #expect(throws: BoundedProcess.Failure.self) {
            try BoundedProcess.run("/bin/sleep", ["30"], deadline: 0.2)
        }

        #expect(failure == .timedOut(seconds: 0.2))
        // The wait is the deadline plus the kill grace, never the sleep.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A descendant holding the pipes open cannot outlast the deadline")
    func boundsDrainByDeadline() throws {
        let started = Date()
        // sh exits at once and leaves a background sleep holding the write ends
        // of both pipes, so draining them to EOF would take 30 s.
        let result = try BoundedProcess.run(
            "/bin/sh", ["-c", "echo hi; sleep 30 &"], deadline: 0.3)
        let elapsed = Date().timeIntervalSince(started)

        // The child exited cleanly, so what it managed to write is returned -
        // the deadline is a promise about wall clock, not about EOF.
        #expect(result.status == 0)
        #expect(result.stdout.contains("hi"))
        #expect(elapsed < 5)
    }

    @Test("A wedged pmset surfaces as a power setting failure mentioning the timeout")
    func spawnMapsTimeout() throws {
        let error = #expect(throws: NSError.self) {
            try PowerModeWriter.spawn("/bin/sleep", ["30"], deadline: 0.2)
        }

        let thrown = try #require(error)
        #expect(HelperError.code(of: thrown) == .powerSettingFailed)
        #expect(thrown.localizedDescription.contains("timed out"))
    }

    @Test("The production budgets are short enough to keep the helper responsive")
    func productionDeadline() {
        // Both together stay inside the client's own timeout, so a queued
        // transaction can never still be writing after the caller gave up.
        #expect(PowerModeWriter.transactionDeadline == 10)
        #expect(PowerModeWriter.lockTimeout == 2)
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
            powerModeWriter: PowerModeWriter(runCommand: { _, _, _ in throw Boom() }))

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
