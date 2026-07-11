import Testing
import JuiceXPCShared
@testable import JuiceCore

@Suite struct LivePowerModelTests {
    // Bundle-id lookups will fail for these synthetic paths, so app keys fall
    // back to the .app bundle path - deterministic and independent of any
    // installed app.
    private func sample(
        coalition: UInt64,
        leaderPID: Int32 = 0,
        path: String,
        cpuNJ: UInt64 = 0,
        gpuNJ: UInt64 = 0,
        aneNJ: UInt64 = 0
    ) -> LiveEnergySample {
        LiveEnergySample(
            coalitionID: coalition,
            leaderPID: leaderPID == 0 ? Int32(coalition) : leaderPID,
            leaderPath: path,
            cpuEnergyNJ: cpuNJ,
            gpuEnergyNJ: gpuNJ,
            aneEnergyNJ: aneNJ
        )
    }

    private func snapshot(at t: Double, _ samples: [LiveEnergySample]) -> LiveEnergySnapshot {
        LiveEnergySnapshot(timestampEpoch: t, samples: samples)
    }

    private let appAPath = "/Applications/AppA.app/Contents/MacOS/AppA"
    private let appAKey = "/Applications/AppA.app"

    // MARK: - Delta math and first-snapshot behavior

    @Test func firstSnapshotReturnsNil() {
        let model = LivePowerModel()
        let first = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 0)]))
        #expect(first == nil)
    }

    @Test func wattsFromDelta() {
        let model = LivePowerModel(halfLifeSeconds: 0.0001) // near-instant EMA: smoothed ~= instantaneous
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 0)]))
        // 2e9 nJ over 2 s = 1 W.
        let reading = model.ingest(snapshot(at: 2, [sample(coalition: 10, path: appAPath, cpuNJ: 2_000_000_000)]))
        let app = reading?.apps.first
        #expect(app != nil)
        #expect(app?.appKey == appAKey)
        #expect(abs((app?.watts ?? 0) - 1.0) < 1e-6)
    }

    @Test func wattsSumCPUGPUAndANE() {
        // The per-app total must include all three SoC energy domains.
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0)
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 10, path: appAPath, cpuNJ: 0, gpuNJ: 0, aneNJ: 0)
        ]))
        // Over 2 s: CPU 2e9 (1 W) + GPU 4e9 (2 W) + ANE 6e9 (3 W) = 6 W total.
        let reading = model.ingest(snapshot(at: 2, [
            sample(coalition: 10, path: appAPath, cpuNJ: 2_000_000_000, gpuNJ: 4_000_000_000, aneNJ: 6_000_000_000)
        ]))
        #expect(abs((reading?.apps.first?.watts ?? 0) - 6.0) < 1e-6)
    }

    @Test func negativeDeltaClampsToZero() {
        let model = LivePowerModel(halfLifeSeconds: 0.0001)
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 5_000_000_000)]))
        // Counter reset (coalition id recycled): lower value than before.
        let reading = model.ingest(snapshot(at: 2, [sample(coalition: 10, path: appAPath, cpuNJ: 1_000_000_000)]))
        // Zero watts -> below idle threshold -> folded, not in apps.
        #expect(reading?.apps.isEmpty == true)
        #expect(reading?.totalAppWatts == 0)
    }

    @Test func perDomainNegativeDeltaClampsIndependently() {
        // A GPU counter reset must not cancel a real CPU delta.
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0)
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 10, path: appAPath, cpuNJ: 0, gpuNJ: 5_000_000_000)
        ]))
        // CPU rises by 2e9 (1 W); GPU drops (reset) -> clamped to 0, not negative.
        let reading = model.ingest(snapshot(at: 2, [
            sample(coalition: 10, path: appAPath, cpuNJ: 2_000_000_000, gpuNJ: 1_000_000_000)
        ]))
        #expect(abs((reading?.apps.first?.watts ?? 0) - 1.0) < 1e-6)
    }

    @Test func reappearingCoalitionReBaselines() {
        let model = LivePowerModel(halfLifeSeconds: 0.0001)
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 5_000_000_000)]))
        // Coalition 10 vanishes this tick: its baseline is dropped.
        let gone = model.ingest(snapshot(at: 2, []))
        #expect(gone?.totalAppWatts == 0)
        // It reappears with a high counter. Because the baseline was dropped,
        // this tick must NOT produce a delta against the stale baseline.
        let back = model.ingest(snapshot(at: 4, [sample(coalition: 10, path: appAPath, cpuNJ: 20_000_000_000)]))
        #expect(back?.totalAppWatts == 0)
        // The following tick computes a delta from the re-established baseline.
        let next = model.ingest(snapshot(at: 6, [sample(coalition: 10, path: appAPath, cpuNJ: 22_000_000_000)]))
        // 2e9 nJ / 2 s = 1 W.
        #expect(abs((next?.apps.first?.watts ?? 0) - 1.0) < 1e-6)
    }

    // MARK: - EMA smoothing

    @Test func emaConvergesTowardSteadyState() {
        // Half-life 5 s, ticks every 2 s, constant 1 W input. Smoothed value
        // should rise monotonically toward 1 W but stay below it for a while.
        let model = LivePowerModel(halfLifeSeconds: 5, idleThresholdWatts: 0)
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 0)]))
        var last = 0.0
        var t = 2.0
        var energy: UInt64 = 2_000_000_000 // 1 W over 2 s
        for _ in 0..<20 {
            let reading = model.ingest(snapshot(at: t, [sample(coalition: 10, path: appAPath, cpuNJ: energy)]))
            let w = reading?.apps.first?.watts ?? 0
            #expect(w >= last - 1e-9) // monotonic non-decreasing
            #expect(w <= 1.0 + 1e-9)  // never overshoots the steady input
            last = w
            t += 2
            energy += 2_000_000_000
        }
        #expect(last > 0.9) // converged close to 1 W after ~40 s
    }

    @Test func absentAppDecaysTowardZero() {
        let model = LivePowerModel(halfLifeSeconds: 2, idleThresholdWatts: 0)
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 0)]))
        // Drive it up.
        _ = model.ingest(snapshot(at: 2, [sample(coalition: 10, path: appAPath, cpuNJ: 10_000_000_000)])) // 5 W
        let high = model.ingest(snapshot(at: 4, [sample(coalition: 10, path: appAPath, cpuNJ: 20_000_000_000)]))
        let highWatts = high?.apps.first?.watts ?? 0
        #expect(highWatts > 0)
        // Now the app disappears from snapshots; it should decay, not freeze.
        let decay1 = model.ingest(snapshot(at: 6, []))
        let decay2 = model.ingest(snapshot(at: 8, []))
        let w1 = decay1?.totalAppWatts ?? 0
        let w2 = decay2?.totalAppWatts ?? 0
        #expect(w1 < highWatts)
        #expect(w2 < w1)
    }

    // MARK: - Hysteresis

    @Test func hysteresisPreventsImmediateSwapThenAllowsIt() {
        // A starts higher; B overtakes. With hysteresisTicks=2, the display
        // order must hold [A,B] until B has led for 2 consecutive ticks.
        let bPath = "/Applications/AppB.app/Contents/MacOS/AppB"
        let bKey = "/Applications/AppB.app"
        let model = LivePowerModel(
            halfLifeSeconds: 0.0001, idleThresholdWatts: 0,
            hysteresisRatio: 0.15, hysteresisTicks: 2
        )
        // Baseline tick.
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 10, path: appAPath, cpuNJ: 0),
            sample(coalition: 20, path: bPath, cpuNJ: 0)
        ]))
        // Tick 1: A high (2 W), B low (1 W) -> order [A, B].
        var t = 2.0
        var eA: UInt64 = 4_000_000_000, eB: UInt64 = 2_000_000_000
        let r1 = model.ingest(snapshot(at: t, [
            sample(coalition: 10, path: appAPath, cpuNJ: eA),
            sample(coalition: 20, path: bPath, cpuNJ: eB)
        ]))
        #expect(r1?.apps.map(\.appKey) == [appAKey, bKey])

        // Now B leads by a wide margin. First leading tick: no swap yet.
        t += 2; eA += 2_000_000_000 /* 1 W */; eB += 10_000_000_000 /* 5 W */
        let r2 = model.ingest(snapshot(at: t, [
            sample(coalition: 10, path: appAPath, cpuNJ: eA),
            sample(coalition: 20, path: bPath, cpuNJ: eB)
        ]))
        #expect(r2?.apps.map(\.appKey) == [appAKey, bKey]) // held by hysteresis

        // Second consecutive leading tick: swap allowed now.
        t += 2; eA += 2_000_000_000; eB += 10_000_000_000
        let r3 = model.ingest(snapshot(at: t, [
            sample(coalition: 10, path: appAPath, cpuNJ: eA),
            sample(coalition: 20, path: bPath, cpuNJ: eB)
        ]))
        #expect(r3?.apps.map(\.appKey) == [bKey, appAKey])
    }

    // MARK: - Idle fold

    @Test func idleAppsAreFolded() {
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0.05)
        let bPath = "/Applications/AppB.app/Contents/MacOS/AppB"
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 10, path: appAPath, cpuNJ: 0),
            sample(coalition: 20, path: bPath, cpuNJ: 0)
        ]))
        // A draws 1 W; B draws 0.01 W (below the 0.05 W threshold).
        let reading = model.ingest(snapshot(at: 2, [
            sample(coalition: 10, path: appAPath, cpuNJ: 2_000_000_000),
            sample(coalition: 20, path: bPath, cpuNJ: 20_000_000)
        ]))
        #expect(reading?.apps.count == 1)
        #expect(reading?.apps.first?.appKey == appAKey)
        #expect(reading?.idleAppCount == 1)
        #expect((reading?.idleWatts ?? 0) > 0)
        #expect((reading?.idleWatts ?? 0) < 0.05)
    }

    // MARK: - Attribution

    @Test func nestedHelperRollsUpToOutermostApp() {
        // A helper nested inside the parent .app must attribute to the OUTERMOST
        // .app, not the inner helper bundle.
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0)
        let parentPath = "/Applications/Electron.app/Contents/MacOS/Electron"
        let helperPath = "/Applications/Electron.app/Contents/Frameworks/Electron Helper (GPU).app/Contents/MacOS/Electron Helper (GPU)"
        let outerKey = "/Applications/Electron.app"
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 10, path: parentPath, cpuNJ: 0),
            sample(coalition: 20, path: helperPath, cpuNJ: 0)
        ]))
        let reading = model.ingest(snapshot(at: 2, [
            sample(coalition: 10, path: parentPath, cpuNJ: 2_000_000_000),   // 1 W
            sample(coalition: 20, path: helperPath, cpuNJ: 2_000_000_000)    // 1 W
        ]))
        // Both roll into one app key, 2 W total.
        #expect(reading?.apps.count == 1)
        #expect(reading?.apps.first?.appKey == outerKey)
        #expect(abs((reading?.apps.first?.watts ?? 0) - 2.0) < 1e-6)
    }

    @Test func multipleCoalitionsSameAppSum() {
        // A browser spawns each renderer as its own resource coalition, all
        // sharing one .app bundle; their watts must sum under that app.
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0)
        let leader = "/Applications/Browser.app/Contents/MacOS/Browser"
        let renderer = "/Applications/Browser.app/Contents/Frameworks/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)"
        let browserKey = "/Applications/Browser.app"
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 100, path: leader, cpuNJ: 0),
            sample(coalition: 101, path: renderer, cpuNJ: 0),
            sample(coalition: 102, path: renderer, cpuNJ: 0)
        ]))
        let reading = model.ingest(snapshot(at: 2, [
            sample(coalition: 100, path: leader, cpuNJ: 2_000_000_000),    // 1 W
            sample(coalition: 101, path: renderer, cpuNJ: 4_000_000_000),  // 2 W
            sample(coalition: 102, path: renderer, cpuNJ: 6_000_000_000)   // 3 W
        ]))
        #expect(reading?.apps.count == 1)
        #expect(reading?.apps.first?.appKey == browserKey)
        #expect(abs((reading?.apps.first?.watts ?? 0) - 6.0) < 1e-6)
    }

    @Test func unattributedCoalitionLandsInSystemBucket() {
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0)
        // A daemon coalition with no .app in its leader path.
        _ = model.ingest(snapshot(at: 0, [
            sample(coalition: 30, path: "/usr/sbin/somedaemon", cpuNJ: 0)
        ]))
        let reading = model.ingest(snapshot(at: 2, [
            sample(coalition: 30, path: "/usr/sbin/somedaemon", cpuNJ: 2_000_000_000) // 1 W
        ]))
        #expect(reading?.apps.isEmpty == true)
        #expect(reading?.totalAppWatts == 0)
        #expect(abs((reading?.systemWatts ?? 0) - 1.0) < 1e-6)
    }

    @Test func emptyLeaderPathLandsInSystemBucket() {
        // A coalition whose leader path could not be resolved (empty) is not
        // attributable and must fall into the system bucket, not crash.
        let model = LivePowerModel(halfLifeSeconds: 0.0001, idleThresholdWatts: 0)
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 40, path: "", cpuNJ: 0)]))
        let reading = model.ingest(snapshot(at: 2, [sample(coalition: 40, path: "", cpuNJ: 2_000_000_000)]))
        #expect(reading?.apps.isEmpty == true)
        #expect(abs((reading?.systemWatts ?? 0) - 1.0) < 1e-6)
    }

    // MARK: - Reset

    @Test func resetForgetsBaselines() {
        let model = LivePowerModel(halfLifeSeconds: 0.0001)
        _ = model.ingest(snapshot(at: 0, [sample(coalition: 10, path: appAPath, cpuNJ: 0)]))
        model.reset()
        // After reset the next snapshot is again a first snapshot -> nil.
        let after = model.ingest(snapshot(at: 2, [sample(coalition: 10, path: appAPath, cpuNJ: 2_000_000_000)]))
        #expect(after == nil)
    }
}
