import Foundation
import Testing
@testable import Juice

@MainActor
@Suite struct BatterySessionCoordinatorTests {
    private final class GatedLoader {
        private(set) var callCount = 0
        private var pending: [Int: CheckedContinuation<BatterySessionUsageResult, Never>] = [:]
        private var results: [Int: BatterySessionUsageResult] = [:]

        func load() async -> BatterySessionUsageResult {
            callCount += 1
            let index = callCount
            return await withCheckedContinuation { continuation in
                if let result = results.removeValue(forKey: index) {
                    continuation.resume(returning: result)
                } else {
                    pending[index] = continuation
                }
            }
        }

        func resolve(call index: Int, with result: BatterySessionUsageResult) {
            if let continuation = pending.removeValue(forKey: index) {
                continuation.resume(returning: result)
            } else {
                results[index] = result
            }
        }
    }

    private func result(_ app: String) -> BatterySessionUsageResult {
        BatterySessionUsageResult(
            session: nil,
            apps: [AppEnergy(bundleId: app, displayName: app, energyWh: 1, cpuHours: 0)],
            origin: .live,
            errorDescription: nil,
            energyCoverageIsPartial: false)
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test func consumersAreReferenceCountedAndIdempotent() async {
        let loader = GatedLoader()
        let coordinator = BatterySessionCoordinator(
            load: { await loader.load() }, refreshInterval: .seconds(3600))
        let popover = UUID()
        let stats = UUID()

        coordinator.setAttached(true, for: .popover(popover))
        coordinator.setAttached(true, for: .popover(popover))
        coordinator.setAttached(true, for: .stats(stats))
        await settle()

        #expect(coordinator.attachedConsumerCount == 2)
        #expect(loader.callCount == 1)

        coordinator.setAttached(false, for: .popover(popover))
        #expect(coordinator.attachedConsumerCount == 1)
        coordinator.detachAll(kind: .stats)
        #expect(coordinator.attachedConsumerCount == 0)

        loader.resolve(call: 1, with: result("discarded"))
        await settle()
        #expect(coordinator.result == nil)
    }

    @Test func newerManualRefreshWinsWhenOlderOneCompletesLate() async {
        let loader = GatedLoader()
        let coordinator = BatterySessionCoordinator(
            load: { await loader.load() }, refreshInterval: .seconds(3600))
        let consumer = UUID()

        coordinator.setAttached(true, for: .popover(consumer))
        await settle()
        loader.resolve(call: 1, with: result("baseline"))
        await settle()

        coordinator.refreshNow()
        await settle()
        coordinator.refreshNow()
        await settle()
        #expect(loader.callCount == 3)

        loader.resolve(call: 3, with: result("newer"))
        await settle()
        #expect(coordinator.result?.apps.map(\.bundleId) == ["newer"])

        loader.resolve(call: 2, with: result("older"))
        await settle()
        #expect(coordinator.result?.apps.map(\.bundleId) == ["newer"])

        coordinator.setAttached(false, for: .popover(consumer))
    }
}
