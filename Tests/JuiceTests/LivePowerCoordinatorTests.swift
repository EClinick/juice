import Testing
import Combine
import Foundation
import JuiceCore
import JuiceXPCShared
@testable import Juice

@MainActor
@Suite struct LivePowerCoordinatorTests {
    /// A deterministic ``LivePowerSource`` double: it never runs a real loop,
    /// only counts start/stop calls and exposes empty update streams (the tests
    /// drive readings through the coordinator's synchronous `apply` seam).
    private final class FakeSource: LivePowerSource {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var cadenceUpdates: [LivePowerSamplingCadence] = []
        var isRunning: Bool { startCount - stopCount > 0 }

        var reading: LivePowerReading?
        var status: LivePowerController.Status = .warmingUp

        var readingUpdates: AsyncStream<LivePowerReading?> {
            AsyncStream { $0.finish() }
        }
        var statusUpdates: AsyncStream<LivePowerController.Status> {
            AsyncStream { $0.finish() }
        }

        func setSamplingCadence(_ cadence: LivePowerSamplingCadence) {
            guard cadenceUpdates.last != cadence else { return }
            cadenceUpdates.append(cadence)
        }
        func start() { startCount += 1 }
        func stop() { stopCount += 1 }
    }

    /// Stream-backed source for verifying that status updates remain private
    /// while only the menu-bar consumer is attached, then synchronize on open.
    private final class StreamingSource: LivePowerSource {
        private let readingStream: AsyncStream<LivePowerReading?>
        private let statusStream: AsyncStream<LivePowerController.Status>
        private let readingContinuation: AsyncStream<LivePowerReading?>.Continuation
        private let statusContinuation: AsyncStream<LivePowerController.Status>.Continuation

        var reading: LivePowerReading?
        var status: LivePowerController.Status = .warmingUp
        var readingUpdates: AsyncStream<LivePowerReading?> { readingStream }
        var statusUpdates: AsyncStream<LivePowerController.Status> { statusStream }

        init() {
            (readingStream, readingContinuation) = AsyncStream.makeStream()
            (statusStream, statusContinuation) = AsyncStream.makeStream()
        }

        func emit(status: LivePowerController.Status) {
            self.status = status
            statusContinuation.yield(status)
        }

        func setSamplingCadence(_ cadence: LivePowerSamplingCadence) {}
        func start() {}
        func stop() {
            reading = nil
            status = .warmingUp
        }
    }

    /// A cancellable delay whose first invocation deliberately remains
    /// suspended after cancellation. This lets a replacement loop install its
    /// delay before the stale loop resumes its cleanup.
    private actor ControlledDelay {
        private var invocationCount = 0
        private var cancellations: Set<Int> = []
        private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
        private var releasedBeforeRegistration: Set<Int> = []

        func sleep(_ duration: Duration) async {
            invocationCount += 1
            let invocation = invocationCount
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if releasedBeforeRegistration.remove(invocation) != nil {
                        continuation.resume()
                    } else {
                        pending[invocation] = continuation
                    }
                }
            } onCancel: {
                Task { await self.markCancelled(invocation) }
            }
        }

        private func markCancelled(_ invocation: Int) {
            cancellations.insert(invocation)
            // Hold the first cancelled delay until the replacement delay is
            // known to be installed. Later delays complete on cancellation.
            if invocation != 1 {
                release(invocation)
            }
        }

        func release(_ invocation: Int) {
            if let continuation = pending.removeValue(forKey: invocation) {
                continuation.resume()
            } else {
                releasedBeforeRegistration.insert(invocation)
            }
        }

        func calls() -> Int { invocationCount }
        func wasCancelled(_ invocation: Int) -> Bool {
            cancellations.contains(invocation)
        }
    }

    private func liveApp(_ key: String, watts: Double) -> AppPowerReading {
        AppPowerReading(appKey: key, bundlePath: nil, displayName: key, watts: watts)
    }

    private func reading(_ apps: [AppPowerReading]) -> LivePowerReading {
        LivePowerReading(
            apps: apps,
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: apps.reduce(0) { $0 + $1.watts },
            systemWatts: 0)
    }

    private func todayResult(_ apps: [(String, Double)]) -> EnergySourceSelector.TopAppsResult {
        EnergySourceSelector.TopAppsResult(
            apps: apps.map { AppEnergy(bundleId: $0.0, displayName: $0.0, energyWh: $0.1, cpuHours: 0) },
            origin: .live,
            coverageDayCount: nil,
            errorDescription: nil)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // Stable per-instance identities for the tests. Distinct ids model distinct
    // view instances (e.g. two Stats windows across a reopen).
    private let popoverID = UUID()
    private let statsID = UUID()

    /// Counts today-fetches and returns a caller-controlled result, so tests can
    /// assert an immediate refresh fired on attach.
    private final class TodayLoader {
        private(set) var callCount = 0
        var result: EnergySourceSelector.TopAppsResult

        init(result: EnergySourceSelector.TopAppsResult) { self.result = result }

        func load() async -> EnergySourceSelector.TopAppsResult {
            callCount += 1
            return result
        }
    }

    /// A loader whose individual calls suspend until the test explicitly
    /// resolves them, so completion ordering (older vs newer retry) is fully
    /// controllable. Each `load()` parks its continuation keyed by call index.
    private final class GatedLoader {
        private(set) var callCount = 0
        private var pending: [Int: CheckedContinuation<EnergySourceSelector.TopAppsResult, Never>] = [:]
        private var results: [Int: EnergySourceSelector.TopAppsResult] = [:]

        func load() async -> EnergySourceSelector.TopAppsResult {
            callCount += 1
            let index = callCount
            return await withCheckedContinuation { continuation in
                if let result = results[index] {
                    results[index] = nil
                    continuation.resume(returning: result)
                } else {
                    pending[index] = continuation
                }
            }
        }

        /// Completes the `index`-th `load()` call with `result` (1-based).
        func resolve(call index: Int, with result: EnergySourceSelector.TopAppsResult) {
            if let continuation = pending[index] {
                pending[index] = nil
                continuation.resume(returning: result)
            } else {
                results[index] = result
            }
        }
    }

    /// A coordinator wired to a fake source, a controllable clock, and a
    /// counting today loader. The refresh interval is set huge so only the
    /// on-attach immediate refresh fires during a test.
    private func makeCoordinator(
        clock: @escaping () -> Date,
        loader: TodayLoader
    ) -> (LivePowerCoordinator, FakeSource) {
        let source = FakeSource()
        let coordinator = LivePowerCoordinator(
            source: source,
            loadToday: { await loader.load() },
            loadSystemLoad: { nil },
            now: clock,
            todayRefreshInterval: .seconds(3600))
        return (coordinator, source)
    }

    private func makeCoordinator(
        clock: @escaping () -> Date,
        gated: GatedLoader,
        interval: Duration = .seconds(3600)
    ) -> (LivePowerCoordinator, FakeSource) {
        let source = FakeSource()
        let coordinator = LivePowerCoordinator(
            source: source,
            loadToday: { await gated.load() },
            loadSystemLoad: { nil },
            now: clock,
            todayRefreshInterval: interval)
        return (coordinator, source)
    }

    /// Waits until the gated loader has received exactly `calls` load() calls,
    /// so zero-interval loop scheduling cannot race the assertions.
    private func waitFor(_ gated: GatedLoader, calls: Int) async {
        for _ in 0..<200 where gated.callCount < calls {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(gated.callCount == calls)
    }

    /// Yields the main actor so the coordinator's attach-triggered refresh Task
    /// runs to completion before assertions.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("System load is captured with each live app reading")
    func systemLoadTracksLiveReadingCadence() {
        var loads = [24.0, 31.0]
        let coordinator = LivePowerCoordinator(
            source: FakeSource(),
            loadToday: { self.todayResult([]) },
            loadSystemLoad: { loads.removeFirst() })

        coordinator.apply(reading: reading([liveApp("editor", watts: 4)]))
        #expect(coordinator.systemLoadWatts == 24)

        coordinator.apply(reading: reading([liveApp("editor", watts: 7)]))
        #expect(coordinator.systemLoadWatts == 31)

        coordinator.apply(reading: nil)
        #expect(coordinator.systemLoadWatts == nil)
    }

    @Test("Termination drains queued reading deliveries in source order")
    func terminationDrainsReadingDeliveries() async {
        actor Recorder {
            var watts: [Double] = []

            func append(_ value: Double) async {
                if watts.isEmpty {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                watts.append(value)
            }
        }

        let recorder = Recorder()
        let coordinator = LivePowerCoordinator(
            source: FakeSource(),
            loadToday: { self.todayResult([]) },
            loadSystemLoad: { nil })
        coordinator.onReading = { reading in
            await recorder.append(reading.totalMeteredWatts)
        }

        coordinator.apply(reading: LivePowerReading(
            apps: [],
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: 3,
            systemWatts: 4))
        coordinator.apply(reading: LivePowerReading(
            apps: [],
            idleAppCount: 0,
            idleWatts: 0,
            totalAppWatts: 5,
            systemWatts: 6))

        await coordinator.prepareForTermination()

        #expect(await recorder.watts == [7, 11])
    }

    @Test("Reference counting: the loop starts once and stops only on the last detach")
    func referenceCountedStartStop() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        coordinator.setAttached(true, for: .popover(popoverID))
        #expect(source.startCount == 1)
        #expect(source.isRunning)

        // A second consumer attaching must not restart the already-running loop.
        coordinator.setAttached(true, for: .stats(statsID))
        #expect(source.startCount == 1)
        #expect(coordinator.attachedConsumerCount == 2)

        // The first detach leaves one consumer, so sampling continues.
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(source.stopCount == 0)
        #expect(source.isRunning)

        // The last detach stops the loop.
        coordinator.setAttached(false, for: .stats(statsID))
        #expect(source.stopCount == 1)
        #expect(!source.isRunning)
    }

    @Test("Menu-bar-only sampling is background; visible demand is responsive")
    func demandAwareSamplingCadence() {
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { self.t0 }, loader: loader)
        let menuBarID = UUID()

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .menuBar(menuBarID))
        #expect(source.cadenceUpdates == [.background])
        #expect(source.startCount == 1)

        // Opening either visible surface changes the existing loop's cadence;
        // it must not start a second source or disturb the menu-bar token.
        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        #expect(source.cadenceUpdates == [.background, .responsive])
        #expect(source.startCount == 1)
        #expect(coordinator.attachedConsumerCount == 2)

        // Closing the last visible surface leaves the always-on menu-bar
        // consumer attached and returns that same loop to background cadence.
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(source.cadenceUpdates == [.background, .responsive, .background])
        #expect(source.stopCount == 0)
        #expect(source.isRunning)
    }

    @Test("Stats demand remains responsive until the last visible token detaches")
    func multipleVisibleConsumersKeepResponsiveCadence() {
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { self.t0 }, loader: loader)
        let menuBarID = UUID()

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .menuBar(menuBarID))
        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .stats(statsID))

        // Adding Stats while the popover is already visible is idempotent at
        // the cadence layer and does not restart the shared source.
        #expect(source.cadenceUpdates == [.background, .responsive])
        #expect(source.startCount == 1)

        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(source.cadenceUpdates == [.background, .responsive])
        #expect(source.stopCount == 0)

        coordinator.detachAll(kind: .stats)
        #expect(source.cadenceUpdates == [.background, .responsive, .background])
        #expect(source.stopCount == 0)
    }

    @Test("Changing cadence preserves the controller's cumulative baseline")
    func controllerCadenceChangePreservesBaseline() async {
        let path = "/Applications/Test.app/Contents/MacOS/Test"
        var snapshots = [
            LiveEnergySnapshot(timestampEpoch: 0, samples: [
                LiveEnergySample(
                    coalitionID: 1,
                    leaderPID: 1,
                    leaderPath: path,
                    cpuEnergyNJ: 0,
                    gpuEnergyNJ: 0,
                    aneEnergyNJ: 0),
            ]),
            LiveEnergySnapshot(timestampEpoch: 5, samples: [
                LiveEnergySample(
                    coalitionID: 1,
                    leaderPID: 1,
                    leaderPath: path,
                    cpuEnergyNJ: 5_000_000_000,
                    gpuEnergyNJ: 0,
                    aneEnergyNJ: 0),
            ]),
        ]
        let controller = LivePowerController(
            fetchSnapshot: { snapshots.removeFirst() })

        await controller.sampleOnce()
        #expect(controller.status == .warmingUp)
        #expect(controller.reading == nil)

        // This is the key lifecycle distinction from stop/start: cadence
        // changes leave the model intact, so the next snapshot can delta
        // against the baseline captured before the change.
        controller.setSamplingCadence(.background)
        await controller.sampleOnce()

        #expect(controller.samplingCadence == .background)
        #expect(controller.status == .sampling)
        #expect((controller.reading?.totalMeteredWatts ?? 0) > 0)
    }

    @Test("Background-only ticks do not invalidate hidden coordinator UI")
    func backgroundTicksSuppressUIPublication() {
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, _) = makeCoordinator(clock: { self.t0 }, loader: loader)
        let menuBarID = UUID()

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .menuBar(menuBarID))

        var statusReadings: [LivePowerReading] = []
        coordinator.onStatusReading = { statusReadings.append($0) }
        var invalidations = 0
        let observation = coordinator.objectWillChange.sink {
            invalidations += 1
        }
        let backgroundReading = reading([liveApp("server", watts: 3)])
        coordinator.apply(reading: backgroundReading)

        #expect(invalidations == 0)
        #expect(coordinator.reading == nil)
        #expect(statusReadings == [backgroundReading])

        // Opening the popover publishes the retained tick immediately, before
        // waiting for another helper round trip.
        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        #expect(invalidations > 0)
        #expect(coordinator.reading == backgroundReading)

        withExtendedLifetime(observation) {}
    }

    @Test("A hidden status update synchronizes only when a visible consumer attaches")
    func backgroundStatusSynchronizesOnVisibleAttach() async {
        let source = StreamingSource()
        let coordinator = LivePowerCoordinator(
            source: source,
            loadToday: { self.todayResult([]) },
            loadSystemLoad: { nil })
        let menuBarID = UUID()

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .menuBar(menuBarID))
        await settle()

        var invalidations = 0
        let observation = coordinator.objectWillChange.sink {
            invalidations += 1
        }
        source.emit(status: .helperOutdated)
        await settle()

        #expect(invalidations == 0)
        #expect(coordinator.status == .warmingUp)

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        #expect(invalidations > 0)
        #expect(coordinator.status == .helperOutdated)

        withExtendedLifetime(observation) {}
    }

    @Test("Background-only readings preserve grace without publishing a hybrid")
    func backgroundReadingsPreserveGraceWithoutPublishing() {
        let source = FakeSource()
        var now = t0
        let coordinator = LivePowerCoordinator(
            source: source,
            loadToday: { self.todayResult([]) },
            loadSystemLoad: { nil },
            now: { now })
        let menuBarID = UUID()

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .menuBar(menuBarID))
        coordinator.apply(reading: reading([liveApp("server", watts: 3)]))
        #expect(coordinator.hybrid == nil)

        // The latest background tick is below the display threshold, but the
        // prior hidden crossing remains inside the 30-second grace window.
        now = t0.addingTimeInterval(10)
        coordinator.apply(reading: reading([liveApp("server", watts: 0.01)]))
        #expect(coordinator.hybrid == nil)

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        #expect(coordinator.hybrid?.active.map(\.appKey) == ["server"])
    }

    @Test("A stopped loop cannot clear the replacement loop's delay handle")
    func staleLoopCannotOrphanReplacementDelay() async {
        let delay = ControlledDelay()
        let controller = LivePowerController(
            fetchSnapshot: {
                LiveEnergySnapshot(timestampEpoch: 0, samples: [])
            },
            sleep: { duration in await delay.sleep(duration) })

        controller.start()
        await waitUntil { await delay.calls() == 1 }
        #expect(await delay.calls() == 1)

        // Keep the first cancelled delay suspended, then let the replacement
        // loop install delay 2 before the stale loop's cleanup resumes.
        controller.stop()
        await waitUntil { await delay.wasCancelled(1) }
        controller.start()
        await waitUntil { await delay.calls() == 2 }
        #expect(await delay.calls() == 2)
        await delay.release(1)
        await settle()

        // A cadence transition must still own and cancel delay 2. Without
        // generation-guarded cleanup, the old loop could nil out this handle.
        controller.setSamplingCadence(.background)
        await waitUntil { await delay.wasCancelled(2) }
        #expect(await delay.wasCancelled(2))

        // Ensure no controlled delay is left parked if an assertion fails.
        await delay.release(2)
        controller.stop()
    }

    @Test("Idempotent tokens: repeated attach from one consumer counts once")
    func idempotentConsumerTokens() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        // SwiftUI can fire onAppear/onChange multiple times; a consumer that
        // attaches twice must still count once and not unbalance the loop.
        coordinator.setAttached(true, for: .popover(popoverID))
        coordinator.setAttached(true, for: .popover(popoverID))
        #expect(coordinator.attachedConsumerCount == 1)
        #expect(source.startCount == 1)

        // A single detach from that consumer fully releases it.
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(coordinator.attachedConsumerCount == 0)
        #expect(source.stopCount == 1)

        // A redundant detach is absorbed - no double stop.
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(source.stopCount == 1)
    }

    @Test("Range gating: switching off Today detaches, switching back reattaches")
    func rangeGatedAttachDetach() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        // On Today the consumer wants live data (visible && range == .today).
        coordinator.setAttached(true, for: .popover(popoverID))
        #expect(source.isRunning)
        #expect(source.startCount == 1)

        // Switching to a historical range gates attachment off - the loop stops.
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(!source.isRunning)
        #expect(source.stopCount == 1)

        // Switching back to Today reattaches and restarts sampling.
        coordinator.setAttached(true, for: .popover(popoverID))
        #expect(source.isRunning)
        #expect(source.startCount == 2)
    }

    @Test("An immediate Today refresh fires on attach")
    func immediateTodayRefreshOnAttach() async {
        let now = t0
        let loader = TodayLoader(result: todayResult([("slack", 3.0)]))
        let (coordinator, _) = makeCoordinator(clock: { now }, loader: loader)

        #expect(loader.callCount == 0)
        coordinator.setAttached(true, for: .popover(popoverID))
        await settle()

        // The attach kicked off one refresh without waiting for the 30 s cadence.
        #expect(loader.callCount == 1)
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["slack"])
    }

    @Test("Session samples live power without querying Today history")
    func sessionAttachmentSkipsTodayHistory() async {
        let now = t0
        let loader = TodayLoader(result: todayResult([("slack", 3.0)]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        await settle()

        #expect(source.isRunning)
        #expect(loader.callCount == 0)
        coordinator.refreshTodayNow()
        await settle()
        #expect(loader.callCount == 0)
    }

    @Test("Switching between Session and Today toggles only history refresh")
    func sessionTodayHistoryGating() async {
        let now = t0
        let loader = TodayLoader(result: todayResult([("slack", 3.0)]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        await settle()
        #expect(source.startCount == 1)
        #expect(loader.callCount == 0)

        coordinator.setAttached(
            true,
            includesTodayHistory: true,
            for: .popover(popoverID))
        await settle()
        #expect(source.startCount == 1)
        #expect(loader.callCount == 1)

        coordinator.setAttached(
            true,
            includesTodayHistory: false,
            for: .popover(popoverID))
        await settle()
        #expect(source.stopCount == 0)
    }

    @Test("Both consumers read the same published hybrid verbatim")
    func sharedStateIsConsistent() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, _) = makeCoordinator(clock: { now }, loader: loader)

        coordinator.setAttached(true, for: .popover(popoverID))
        coordinator.setAttached(true, for: .stats(statsID))

        coordinator.apply(reading: reading([
            liveApp("slack", watts: 0.2),
            liveApp("discord", watts: 0.06),
        ]))

        // There is exactly one published hybrid, so any two readers of the
        // coordinator observe identical active membership - the divergence the
        // per-view mergers used to produce is impossible.
        let hybrid = coordinator.hybrid
        #expect(hybrid?.active.map(\.appKey) == ["slack", "discord"])
        #expect(coordinator.hybrid?.active.map(\.appKey) == ["slack", "discord"])
    }

    @Test("Grace state persists across a detach/reattach cycle within the window")
    func gracePersistsAcrossReattach() {
        var now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        // A consumer attaches and an app is seen drawing power.
        coordinator.setAttached(true, for: .popover(popoverID))
        coordinator.apply(reading: reading([liveApp("claude", watts: 4.0)]))
        #expect(coordinator.hybrid?.active.map(\.appKey) == ["claude"])

        // The consumer detaches (popover closed) 5 s later. Sampling pauses but
        // the 30 s grace timeline must NOT be wiped.
        now = t0.addingTimeInterval(5)
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(!source.isRunning)

        // 10 s after the last reading the consumer reattaches and the app is now
        // below the threshold. Because grace state survived the detach, the app
        // is still within its 30 s window and remains active. (The attach's own
        // re-age uses the cleared reading, then the fresh sub-threshold reading
        // keeps the holdover.)
        now = t0.addingTimeInterval(10)
        coordinator.setAttached(true, for: .popover(popoverID))
        coordinator.apply(reading: reading([liveApp("claude", watts: 0.01)]))
        #expect(coordinator.hybrid?.active.map(\.appKey) == ["claude"])
    }

    @Test("Grace is re-aged synchronously on attach after the window elapses")
    func graceReAgedOnAttachAfterWindow() {
        var now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, _) = makeCoordinator(clock: { now }, loader: loader)

        // Establish "claude" as active, then detach.
        coordinator.setAttached(true, for: .popover(popoverID))
        coordinator.apply(reading: reading([liveApp("claude", watts: 4.0)]))
        #expect(coordinator.hybrid?.active.map(\.appKey) == ["claude"])
        coordinator.setAttached(false, for: .popover(popoverID))

        // Reattach 40 s later - well past the 30 s grace window. The attach must
        // re-age grace immediately (with the cleared reading), so the stale
        // active row is gone before any fresh tick arrives, not lingering in the
        // cached hybrid.
        now = t0.addingTimeInterval(40)
        coordinator.setAttached(true, for: .popover(popoverID))
        #expect(coordinator.hybrid?.active.isEmpty == true)
    }

    @Test("Per-instance tokens: a stale instance's teardown cannot detach the fresh one")
    func staleInstanceDetachLeavesFreshAttached() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        // A rapid Stats-window reopen: the fresh instance attaches its own token
        // before the stale instance finishes tearing down (SwiftUI does not
        // guarantee onDisappear precedes the new onAppear).
        let staleStats = UUID()
        let freshStats = UUID()
        coordinator.setAttached(true, for: .stats(staleStats))
        coordinator.setAttached(true, for: .stats(freshStats))
        #expect(coordinator.attachedConsumerCount == 2)

        // The stale instance's late onDisappear removes ONLY its own token.
        coordinator.setAttached(false, for: .stats(staleStats))

        // The fresh, visible instance stays attached and sampling continues -
        // the shared-token race that silently stopped live sampling is gone.
        #expect(coordinator.attachedConsumerCount == 1)
        #expect(source.isRunning)
        #expect(source.stopCount == 0)
    }

    @Test("Presenter-level detachAll releases the window's token even if onDisappear never fires")
    func detachAllKindForcesDetach() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        // The popover and a Stats window are both attached.
        coordinator.setAttached(true, for: .popover(popoverID))
        coordinator.setAttached(true, for: .stats(statsID))
        #expect(coordinator.attachedConsumerCount == 2)

        // windowWillClose calls detachAll(kind: .stats). Because the retained
        // window's .onDisappear is unreliable, this must release the Stats
        // token(s) regardless - but leave the popover untouched.
        coordinator.detachAll(kind: .stats)
        #expect(coordinator.attachedConsumerCount == 1)
        #expect(source.isRunning) // popover still holds the loop open
        #expect(source.stopCount == 0)

        // With no Stats window, closing the popover stops the loop.
        coordinator.setAttached(false, for: .popover(popoverID))
        #expect(!source.isRunning)
        #expect(source.stopCount == 1)
    }

    @Test("detachAll stops the loop when it removes the last consumer")
    func detachAllStopsLoopWhenLast() {
        let now = t0
        let loader = TodayLoader(result: todayResult([]))
        let (coordinator, source) = makeCoordinator(clock: { now }, loader: loader)

        // Two Stats instances (a reopen mid-flight), no other consumers.
        coordinator.setAttached(true, for: .stats(UUID()))
        coordinator.setAttached(true, for: .stats(UUID()))
        #expect(source.isRunning)

        // Closing the window detaches every Stats token at once and stops the
        // loop exactly once.
        coordinator.detachAll(kind: .stats)
        #expect(coordinator.attachedConsumerCount == 0)
        #expect(!source.isRunning)
        #expect(source.stopCount == 1)
    }

    @Test("A retry that completes after detach does not publish a stale result")
    func staleRetryAfterDetachDoesNotPublish() async {
        let now = t0
        let gated = GatedLoader()
        let (coordinator, _) = makeCoordinator(clock: { now }, gated: gated)

        // Attach: the periodic refresh issues call 1. Resolve it with a known
        // baseline so the periodic loop settles into its long sleep.
        coordinator.setAttached(true, for: .popover(popoverID))
        await settle()
        gated.resolve(call: 1, with: todayResult([("baseline", 1.0)]))
        await settle()
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["baseline"])

        // A manual retry issues call 2, which parks (query in flight).
        coordinator.refreshTodayNow()
        await settle()
        #expect(gated.callCount == 2)

        // The user leaves Today / the window closes before the retry returns.
        coordinator.setAttached(false, for: .popover(popoverID))

        // The retry finally completes - it must NOT publish after detach.
        gated.resolve(call: 2, with: todayResult([("stale", 9.0)]))
        await settle()
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["baseline"])
    }

    @Test("A newer retry result is not overwritten by an older one completing late")
    func newerRetryResultWinsOverOlder() async {
        let now = t0
        let gated = GatedLoader()
        let (coordinator, _) = makeCoordinator(clock: { now }, gated: gated)

        // Attach and settle the periodic call 1 to a baseline.
        coordinator.setAttached(true, for: .popover(popoverID))
        await settle()
        gated.resolve(call: 1, with: todayResult([("baseline", 1.0)]))
        await settle()

        // First manual retry (call 2) parks.
        coordinator.refreshTodayNow()
        await settle()
        // Second manual retry (call 3) supersedes the first and parks.
        coordinator.refreshTodayNow()
        await settle()
        #expect(gated.callCount == 3)

        // The NEWER retry (call 3) completes first and publishes.
        gated.resolve(call: 3, with: todayResult([("newer", 3.0)]))
        await settle()
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["newer"])

        // The OLDER retry (call 2) completes late - it must be discarded, not
        // clobber the newer result already on screen.
        gated.resolve(call: 2, with: todayResult([("older", 2.0)]))
        await settle()
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["newer"])
    }

    @Test("A periodic refresh mints its own generation, so an older in-flight fetch never publishes over it")
    func periodicRefreshSupersedesOlderInFlightFetches() async {
        let now = t0
        let gated = GatedLoader()
        let (coordinator, _) = makeCoordinator(clock: { now }, gated: gated, interval: .zero)

        // Attach: periodic call 1 parks; resolve it to a baseline. With a zero
        // interval the loop immediately issues periodic call 2, which parks.
        coordinator.setAttached(true, for: .popover(popoverID))
        await waitFor(gated, calls: 1)
        gated.resolve(call: 1, with: todayResult([("baseline", 1.0)]))
        await waitFor(gated, calls: 2)
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["baseline"])

        // A manual retry (call 3) starts while periodic call 2 is in flight.
        coordinator.refreshTodayNow()
        await waitFor(gated, calls: 3)

        // The superseded periodic fetch completes late - discarded. Its
        // completion frees the loop to start periodic call 4, which is newer
        // than the still-parked manual call 3.
        gated.resolve(call: 2, with: todayResult([("periodicStale", 9.0)]))
        await waitFor(gated, calls: 4)
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["baseline"])

        // The newest fetch (periodic call 4) publishes...
        gated.resolve(call: 4, with: todayResult([("periodicNew", 3.0)]))
        await settle()
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["periodicNew"])

        // ...and the older manual fetch completing afterward must be rejected,
        // not clobber the newer periodic result.
        gated.resolve(call: 3, with: todayResult([("manualStale", 2.0)]))
        await settle()
        #expect(coordinator.todayResult?.apps.map(\.bundleId) == ["periodicNew"])
    }
}
