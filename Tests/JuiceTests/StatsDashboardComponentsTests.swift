import AppKit
import SwiftUI
import Testing
@testable import Juice

@MainActor
@Suite("Shared Stats dashboard components")
struct StatsDashboardComponentsTests {
    @Test("Columns start at their natural direction")
    func appTableSortNaturalDirections() {
        #expect(AppTableSort.naturalDirection(for: .app) == .ascending)
        #expect(AppTableSort.naturalDirection(for: .liveWatts) == .descending)
        #expect(AppTableSort.naturalDirection(for: .energy) == .descending)
        #expect(AppTableSort.naturalDirection(for: .detail) == .descending)
    }

    @Test("Each column cycles natural, reversed, then back to no sort")
    func appTableSortCyclesThroughNoSort() {
        for column in [
            AppTableSort.Column.app,
            .liveWatts,
            .energy,
            .detail,
        ] {
            let natural = AppTableSort.naturalDirection(for: column)
            let reversed: AppTableSort.Direction =
                natural == .ascending ? .descending : .ascending

            let first = AppTableSort.select(column, from: nil)
            #expect(first == AppTableSort(column: column, direction: natural))

            let second = AppTableSort.select(column, from: first)
            #expect(second == AppTableSort(column: column, direction: reversed))

            #expect(AppTableSort.select(column, from: second) == nil)
        }
    }

    @Test("Selecting a different column restarts at that column's natural direction")
    func appTableSortSwitchingColumns() {
        let energy = AppTableSort.select(.energy, from: nil)
        let reversedEnergy = AppTableSort.select(.energy, from: energy)

        #expect(AppTableSort.select(.app, from: reversedEnergy)
            == AppTableSort(column: .app, direction: .ascending))
        #expect(AppTableSort.select(.liveWatts, from: reversedEnergy)
            == AppTableSort(column: .liveWatts, direction: .descending))
    }

    @Test("Live watts fall back to energy only inside the comparator")
    func appTableSortLiveWattsFallbackIsDataDriven() {
        let sort = AppTableSort(column: .liveWatts, direction: .descending)

        #expect(sort.effectiveColumn(hasLiveWatts: false) == .energy)
        #expect(sort.effectiveColumn(hasLiveWatts: true) == .liveWatts)
        // The chosen column itself never changes, so the header chevron keeps
        // pointing at the column the user clicked.
        #expect(sort.column == .liveWatts)
    }

    @Test("No sort keeps the caller's natural order while still filtering")
    func appTableNoSortPreservesInputOrder() {
        let rows = [
            SortFixture(id: "third", displayName: "Zulu", liveWatts: 1, energyWh: 1),
            SortFixture(id: "first", displayName: "Alpha", energyWh: 90),
            SortFixture(id: "second", displayName: "Alps", liveWatts: 9, energyWh: 40),
        ]

        #expect(sortedIDs(rows, by: nil) == ["third", "first", "second"])
        #expect(sortedIDs(rows, by: nil, query: "alp") == ["first", "second"])
    }

    @Test("App table sorts every column in both directions")
    func appTableSortsEveryColumn() {
        let rows = [
            SortFixture(
                id: "z-alpha", displayName: "Alpha", liveWatts: 1,
                energyWh: 30, detail: 2),
            SortFixture(
                id: "m-bravo", displayName: "Bravo", liveWatts: 3,
                energyWh: 10, detail: 1),
            SortFixture(
                id: "a-charlie", displayName: "Charlie", liveWatts: 2,
                energyWh: 20, detail: 3),
        ]

        #expect(sortedIDs(rows, by: .init(column: .app, direction: .ascending))
            == ["z-alpha", "m-bravo", "a-charlie"])
        #expect(sortedIDs(rows, by: .init(column: .app, direction: .descending))
            == ["a-charlie", "m-bravo", "z-alpha"])
        #expect(sortedIDs(rows, by: .init(column: .liveWatts, direction: .ascending))
            == ["z-alpha", "a-charlie", "m-bravo"])
        #expect(sortedIDs(rows, by: .init(column: .liveWatts, direction: .descending))
            == ["m-bravo", "a-charlie", "z-alpha"])
        #expect(sortedIDs(rows, by: .init(column: .energy, direction: .ascending))
            == ["m-bravo", "a-charlie", "z-alpha"])
        #expect(sortedIDs(rows, by: .init(column: .energy, direction: .descending))
            == ["z-alpha", "a-charlie", "m-bravo"])
        #expect(sortedIDs(rows, by: .init(column: .detail, direction: .ascending))
            == ["m-bravo", "z-alpha", "a-charlie"])
        #expect(sortedIDs(rows, by: .init(column: .detail, direction: .descending))
            == ["a-charlie", "z-alpha", "m-bravo"])
    }

    @Test("Numeric ties use display name ascending and stable ID")
    func appTableSortTieBreaksAreStable() {
        let rows = [
            SortFixture(id: "a-zulu", displayName: "Zulu", energyWh: 5),
            SortFixture(id: "same-b", displayName: "Same", energyWh: 5),
            SortFixture(id: "z-alpha", displayName: "Alpha", energyWh: 5),
            SortFixture(id: "same-a", displayName: "Same", energyWh: 5),
        ]

        let expected = ["z-alpha", "same-a", "same-b", "a-zulu"]
        #expect(sortedIDs(rows, by: .init(column: .energy, direction: .ascending))
            == expected)
        #expect(sortedIDs(rows, by: .init(column: .energy, direction: .descending))
            == expected)
    }

    @Test("Live watts quantize to the precision the row displays")
    func liveWattsQuantizeToDisplayedPrecision() {
        #expect(displayedLiveWatts(0.234) == 0.2)
        #expect(displayedLiveWatts(0.26) == 0.3)
        #expect(displayedLiveWatts(0.094) == 0.09)
        #expect(displayedLiveWatts(0.096) == 0.1)
        // Exact binary midpoints round to even, matching %.1f's display.
        #expect(displayedLiveWatts(0.25) == 0.2)
        #expect(displayedLiveWatts(1.25) == 1.2)
        // 0.35 is 0.35000000000000003 in binary - above the midpoint, so
        // both the display and the sort key round up.
        #expect(displayedLiveWatts(0.35) == 0.4)
    }

    @Test("Live watts are compared at one decimal above the display threshold")
    func liveWattsSortUsesDisplayedPrecision() {
        let sameOnScreen = [
            SortFixture(id: "a-zulu", displayName: "Zulu", liveWatts: 0.234),
            SortFixture(id: "m-same", displayName: "Same", liveWatts: 0.236),
            SortFixture(id: "z-alpha", displayName: "Alpha", liveWatts: 0.231),
        ]
        // All three render as "0.2 W", so name order decides instead of noise.
        #expect(sortedIDs(
            sameOnScreen,
            by: .init(column: .liveWatts, direction: .descending)
        ) == ["z-alpha", "m-same", "a-zulu"])

        let belowThreshold = [
            SortFixture(id: "a-zulu", displayName: "Zulu", liveWatts: 0.024),
            SortFixture(id: "m-higher", displayName: "Higher", liveWatts: 0.026),
            SortFixture(id: "z-alpha", displayName: "Alpha", liveWatts: 0.021),
        ]
        #expect(sortedIDs(
            belowThreshold,
            by: .init(column: .liveWatts, direction: .descending)
        ) == ["m-higher", "z-alpha", "a-zulu"])
    }

    @Test("App filter is case and diacritic insensitive on display names")
    func appTableFilterMatchesDisplayName() {
        let rows = [
            SortFixture(id: "cafe-app", displayName: "Café Racer", energyWh: 2),
            SortFixture(id: "cafe.bundle", displayName: "Terminal", energyWh: 1),
            SortFixture(id: "resume-app", displayName: "Résumé", energyWh: 3),
        ]
        let sort = AppTableSort(column: .energy, direction: .descending)

        #expect(sortedIDs(rows, by: sort, query: "CAFE") == ["cafe-app"])
        #expect(sortedIDs(rows, by: sort, query: "resume") == ["resume-app"])
    }

    @Test("App filter ignores surrounding whitespace")
    func appTableFilterTrimsQuery() {
        let rows = [
            SortFixture(id: "alpha", displayName: "Alpha", energyWh: 1),
            SortFixture(id: "bravo", displayName: "Bravo", energyWh: 2),
        ]

        #expect(sortedIDs(rows, by: nil, query: "  alpha \n") == ["alpha"])
        // A whitespace-only query filters nothing rather than matching nothing.
        #expect(sortedIDs(rows, by: nil, query: "   ") == ["alpha", "bravo"])
    }

    @Test("App filter returns no rows when nothing matches")
    func appTableFilterEmptyResult() {
        let rows = [
            SortFixture(id: "alpha", displayName: "Alpha", energyWh: 1),
            SortFixture(id: "bravo", displayName: "Bravo", energyWh: 2),
        ]
        let sort = AppTableSort(column: .energy, direction: .descending)

        #expect(sortedIDs(rows, by: sort, query: "Terminal").isEmpty)
        #expect(sortedIDs(rows, by: sort) == ["bravo", "alpha"])
    }

    @Test("Live watts sort falls back to energy when a section has no watts")
    func liveWattsSortFallsBackToEnergy() {
        let rows = [
            SortFixture(id: "alpha", displayName: "Alpha", energyWh: 20),
            SortFixture(id: "bravo", displayName: "Bravo", energyWh: 10),
            SortFixture(id: "charlie", displayName: "Charlie", energyWh: 30),
        ]

        #expect(sortedIDs(
            rows,
            by: .init(column: .liveWatts, direction: .ascending)
        ) == ["bravo", "alpha", "charlie"])
        #expect(sortedIDs(
            rows,
            by: .init(column: .liveWatts, direction: .descending)
        ) == ["charlie", "alpha", "bravo"])
    }

    @Test("Battery columns add live watts only for live ranges")
    func batteryColumnsFollowLiveState() {
        let historical = StatsAppTableColumns.battery(showsLiveWatts: false)
        let live = StatsAppTableColumns.battery(showsLiveWatts: true)

        #expect(!historical.showsLiveWatts)
        #expect(live.showsLiveWatts)
        #expect(historical.detailTitle == "CPU TIME")
        #expect(live.detailTitle == historical.detailTitle)
    }

    @Test("Server columns always expose live watts and peak power")
    func serverColumnsExposeServerMetrics() {
        #expect(StatsAppTableColumns.server.showsLiveWatts)
        #expect(StatsAppTableColumns.server.detailTitle == "PEAK W")
    }

    @Test("Unified Stats root retains mode-specific minimum sizes")
    func unifiedStatsMinimumSizes() {
        #expect(StatsView.batteryMinimumContentWidth >= 743)
        #expect(StatsView.batteryMinimumContentHeight >= 420)
        #expect(StatsView.serverMinimumContentWidth >= 860)
        #expect(StatsView.serverMinimumContentHeight >= 560)
    }

    @Test("Shared battery and server tables render with one row component")
    func sharedTablePreviewRenders() throws {
        let size = NSSize(width: 1040, height: 190)
        let controller = NSHostingController(
            rootView: StatsAppTablePreview()
                .environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height)
        )
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()

        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(
            in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))

        if let outputPath = ProcessInfo.processInfo.environment["JUICE_STATS_PREVIEW_PATH"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}
private struct StatsAppTablePreview: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            table(
                title: "Battery",
                columns: .battery(showsLiveWatts: true),
                liveWattsText: "4.8 W",
                energyText: "1.3 Wh",
                detailText: "0.7 h")
            table(
                title: "Mac mini",
                columns: .server,
                liveWattsText: "2.5 W",
                energyText: "23 Wh",
                detailText: "17.2 W")
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func table(
        title: String,
        columns: StatsAppTableColumns,
        liveWattsText: String,
        energyText: String,
        detailText: String
    ) -> some View {
        StatsAppTablePane(
            title: title,
            showsLiveActivity: false,
            columns: columns,
            sort: .constant(AppTableSort(column: .energy, direction: .descending)),
            query: .constant(""),
            content: {
                StatsAppTableRow(
                    appKey: "preview.app",
                    displayName: "Example App",
                    share: 0.72,
                    columns: columns,
                    liveWattsText: liveWattsText,
                    energyText: energyText,
                    costText: "$0.01",
                    detailText: detailText,
                    accessibilityValue: "Preview",
                    onTap: {})
            },
            summary: { EmptyView() })
    }
}

private struct SortFixture {
    let id: String
    let displayName: String
    var liveWatts: Double?
    var energyWh: Double?
    var detail: Double?

    init(
        id: String,
        displayName: String,
        liveWatts: Double? = nil,
        energyWh: Double? = nil,
        detail: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.liveWatts = liveWatts
        self.energyWh = energyWh
        self.detail = detail
    }
}

private func sortedIDs(
    _ rows: [SortFixture],
    by sort: AppTableSort?,
    query: String = ""
) -> [String] {
    AppTableSort.apply(sort, to: rows, query: query) { row in
        AppTableSortValues(
            stableID: row.id,
            displayName: row.displayName,
            liveWatts: row.liveWatts,
            energyWh: row.energyWh,
            detail: row.detail)
    }
    .map(\.id)
}
