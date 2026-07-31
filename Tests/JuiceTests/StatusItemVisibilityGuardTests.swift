import Testing
@testable import Juice

@MainActor
@Suite struct StatusItemVisibilityGuardTests {
    @MainActor
    private final class ManualScheduler {
        private(set) var pending: [@MainActor () -> Void] = []

        func schedule(_ action: @escaping @MainActor () -> Void) {
            pending.append(action)
        }

        func runNext() {
            pending.removeFirst()()
        }
    }

    @Test("A later reading restarts one coalesced search after delayed materialization")
    func delayedMaterializationRetriesWithoutTimerFanout() {
        let scheduler = ManualScheduler()
        var lookupCount = 0
        var item: String?
        var found: [String] = []
        var exhaustionCount = 0
        let locator = CoalescingRetryLocator<String>(
            lookup: {
                lookupCount += 1
                return item
            },
            schedule: { scheduler.schedule($0) })

        let launchRequest = {
            locator.request(
                retries: 1,
                onFound: { found.append($0) },
                onExhausted: { exhaustionCount += 1 })
        }
        let readingRequest = {
            locator.request(
                retries: 0,
                onFound: { found.append($0) },
                onExhausted: { exhaustionCount += 1 })
        }

        // Launch starts one immediate lookup and one bounded retry.
        launchRequest()
        #expect(lookupCount == 1)
        #expect(scheduler.pending.count == 1)

        // A watt reading arriving during that search must be absorbed rather
        // than scheduling a parallel retry chain.
        readingRequest()
        #expect(lookupCount == 1)
        #expect(scheduler.pending.count == 1)

        // The initial window expires before MenuBarExtra exists.
        scheduler.runNext()
        #expect(lookupCount == 2)
        #expect(exhaustionCount == 1)
        #expect(!locator.isLocating)
        #expect(scheduler.pending.isEmpty)

        // A reading before materialization performs only its immediate lookup;
        // it does not start another timer chain.
        readingRequest()
        #expect(lookupCount == 3)
        #expect(exhaustionCount == 2)
        #expect(scheduler.pending.isEmpty)

        // MenuBarExtra appears later. The next watt reading starts a fresh
        // search, finds it synchronously, and can apply the pending label.
        item = "12.3 W"
        readingRequest()
        #expect(lookupCount == 4)
        #expect(found == ["12.3 W"])
        #expect(!locator.isLocating)
        #expect(scheduler.pending.isEmpty)
    }
}
