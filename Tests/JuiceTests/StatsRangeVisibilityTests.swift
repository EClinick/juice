import Testing
@testable import Juice

@Suite("Stats range visibility")
struct StatsRangeVisibilityTests {
    @Test("compact tabs are visible by default")
    func defaultVisibility() {
        #expect(
            StatsRangeVisibility.visibleRanges(
                from: StatsRangeVisibility.defaultStorageValue
            ) == [.session, .today, .week, .allTime])
    }

    @Test("show-all storage includes every tab")
    func allVisibility() {
        #expect(
            StatsRangeVisibility.visibleRanges(
                from: StatsRangeVisibility.allStorageValue
            ) == EnergyRange.allCases)
    }

    @Test("hidden tabs stay hidden in their original order")
    func customVisibility() {
        var storage = StatsRangeVisibility.allStorageValue
        storage = StatsRangeVisibility.updating(
            .threeDays,
            isVisible: false,
            in: storage)
        storage = StatsRangeVisibility.updating(
            .week,
            isVisible: false,
            in: storage)

        #expect(
            StatsRangeVisibility.visibleRanges(from: storage)
                == [.session, .today, .allTime])
    }

    @Test("at least one tab always remains visible")
    func cannotHideLastTab() {
        let todayOnly = StatsRangeVisibility.storageValue(for: [EnergyRange.today])
        let updated = StatsRangeVisibility.updating(
            .today,
            isVisible: false,
            in: todayOnly)

        #expect(StatsRangeVisibility.visibleRanges(from: updated) == [.today])
    }

    @Test("invalid stored settings recover to compact defaults")
    func invalidStorageFallsBack() {
        #expect(
            StatsRangeVisibility.visibleRanges(from: "removed-range")
                == [.session, .today, .week, .allTime])
    }

    @Test("a hidden preferred tab falls back to the first visible tab")
    func hiddenPreferredRangeFallsBack() {
        let storage = StatsRangeVisibility.storageValue(
            for: [EnergyRange.threeDays, .week])

        #expect(
            StatsRangeVisibility.preferredRange(.today, from: storage)
                == .threeDays)
        #expect(
            StatsRangeVisibility.preferredRange(.week, from: storage)
                == .week)
    }
}
