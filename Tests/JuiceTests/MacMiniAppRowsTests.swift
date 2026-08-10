import Foundation
import Testing
@testable import Juice
@testable import JuiceCore

@Suite("Mac mini app rows")
struct MacMiniAppRowsTests {
    private func total(
        _ appKey: String,
        displayName: String,
        energyWh: Double,
        peakWatts: Double = 0
    ) -> StoredSystemAppEnergyTotal {
        StoredSystemAppEnergyTotal(
            appKey: appKey,
            displayName: displayName,
            energyWh: energyWh,
            activeDuration: 60,
            peakWatts: peakWatts)
    }

    private func liveApp(
        _ appKey: String,
        displayName: String,
        watts: Double
    ) -> AppPowerReading {
        AppPowerReading(
            appKey: appKey,
            bundlePath: nil,
            displayName: displayName,
            watts: watts)
    }

    @Test("Natural order leads with live watts and ranks the rest by energy")
    func naturalOrderPutsLiveFirst() {
        let rows = MacMiniAppRows.make(
            totals: [
                total("quiet.high", displayName: "Quiet High", energyWh: 30),
                total("quiet.low", displayName: "Quiet Low", energyWh: 10),
                total("live.low", displayName: "Live Low", energyWh: 90),
            ],
            liveApps: [
                liveApp("live.low", displayName: "Live Low", watts: 2),
                liveApp("live.high", displayName: "Live High", watts: 5),
            ])

        #expect(rows.map(\.id) == ["live.high", "live.low", "quiet.high", "quiet.low"])
    }

    @Test("Ties fall back to energy and then to display name")
    func naturalOrderTieBreaks() {
        let rows = MacMiniAppRows.make(
            totals: [
                total("b", displayName: "Bravo", energyWh: 5),
                total("a", displayName: "Alpha", energyWh: 5),
                total("c", displayName: "Charlie", energyWh: 9),
            ],
            liveApps: [
                liveApp("live.b", displayName: "Bravo Live", watts: 3),
                liveApp("live.a", displayName: "Alpha Live", watts: 3),
            ])

        #expect(rows.map(\.id) == ["live.a", "live.b", "c", "a", "b"])
    }

    @Test("Live readings supply names and watts for apps with no stored total")
    func liveOnlyAppsJoinIn() {
        let rows = MacMiniAppRows.make(
            totals: [total("stored", displayName: "Stored", energyWh: 4)],
            liveApps: [liveApp("fresh", displayName: "Fresh", watts: 1)])

        let fresh = rows.first { $0.id == "fresh" }
        #expect(fresh?.displayName == "Fresh")
        #expect(fresh?.liveWatts == 1)
        #expect(fresh?.energyWh == nil)
    }

    @Test("Peak watts stay unavailable until the range query lands")
    func peakWattsFollowLoadedData() {
        let liveApps = [liveApp("app", displayName: "App", watts: 7)]

        let loading = MacMiniAppRows.make(totals: nil, liveApps: liveApps)
        #expect(loading.first?.peakWatts == nil)

        let loaded = MacMiniAppRows.make(
            totals: [total("app", displayName: "App", energyWh: 2, peakWatts: 4)],
            liveApps: liveApps)
        // A live sample above the stored peak is itself the peak so far.
        #expect(loaded.first?.peakWatts == 7)
    }

    @Test("Sections split live rows from the rest without reordering either")
    func sectionsPreserveNaturalOrder() {
        let rows = MacMiniAppRows.make(
            totals: [
                total("quiet.high", displayName: "Quiet High", energyWh: 30),
                total("quiet.low", displayName: "Quiet Low", energyWh: 10),
            ],
            liveApps: [
                liveApp("live.low", displayName: "Live Low", watts: 2),
                liveApp("live.high", displayName: "Live High", watts: 5),
            ])
        let sections = MacMiniAppRows.sections(rows)

        #expect(sections.live.map(\.id) == ["live.high", "live.low"])
        #expect(sections.earlier.map(\.id) == ["quiet.high", "quiet.low"])
    }

    @Test("A table with no live apps keeps every row in one earlier section")
    func sectionsWithoutLiveApps() {
        let rows = MacMiniAppRows.make(
            totals: [
                total("a", displayName: "Alpha", energyWh: 3),
                total("b", displayName: "Bravo", energyWh: 8),
            ],
            liveApps: [])
        let sections = MacMiniAppRows.sections(rows)

        #expect(sections.live.isEmpty)
        #expect(sections.earlier.map(\.id) == ["b", "a"])
    }

    @Test("Sorting and filtering apply inside each section independently")
    func sectionsSortAndFilterSeparately() {
        let rows = MacMiniAppRows.make(
            totals: [
                total("quiet.alpha", displayName: "Alpha Quiet", energyWh: 30),
                total("quiet.bravo", displayName: "Bravo Quiet", energyWh: 10),
                total("live.alpha", displayName: "Alpha Live", energyWh: 1),
                total("live.bravo", displayName: "Bravo Live", energyWh: 90),
            ],
            liveApps: [
                liveApp("live.alpha", displayName: "Alpha Live", watts: 5),
                liveApp("live.bravo", displayName: "Bravo Live", watts: 2),
            ])
        let sections = MacMiniAppRows.sections(rows)

        let byEnergy = AppTableSort(column: .energy, direction: .ascending)
        #expect(sortedIDs(sections.live, by: byEnergy) == ["live.alpha", "live.bravo"])
        #expect(sortedIDs(sections.earlier, by: byEnergy) == ["quiet.bravo", "quiet.alpha"])

        // A query narrows each section on its own; either one can empty out.
        #expect(sortedIDs(sections.live, by: nil, query: "alpha") == ["live.alpha"])
        #expect(sortedIDs(sections.earlier, by: nil, query: "live").isEmpty)
    }

    private func sortedIDs(
        _ rows: [MacMiniAppRow],
        by sort: AppTableSort?,
        query: String = ""
    ) -> [String] {
        AppTableSort.apply(sort, to: rows, query: query) { app in
            AppTableSortValues(
                stableID: app.appKey,
                displayName: app.displayName,
                liveWatts: app.liveWatts,
                energyWh: app.energyWh,
                detail: app.peakWatts)
        }
        .map(\.id)
    }
}
