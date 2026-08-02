import AppKit
import SwiftUI
import Testing
@testable import Juice

@MainActor
@Suite("Shared Stats dashboard components")
struct StatsDashboardComponentsTests {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            StatsAppTableHeader(columns: columns)
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
        }
        .frame(maxWidth: .infinity)
    }
}
