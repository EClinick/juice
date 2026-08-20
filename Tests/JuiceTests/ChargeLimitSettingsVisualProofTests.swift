import AppKit
import SwiftUI
import Testing
@testable import Juice

@MainActor
struct ChargeLimitSettingsVisualProofTests {
    private struct PreviewCase {
        let filename: String
        let configuration: ChargeLimitConfiguration
        let optimizedMode: OptimizedChargingMode
    }

    @Test("Battery Charging Settings states render at the production detail width")
    func settingsStatesRender() async throws {
        let previews = [
            PreviewCase(
                filename: "charge-limit-settings-90.png",
                configuration: Self.configuration(90),
                optimizedMode: .enabled),
            PreviewCase(
                filename: "charge-limit-settings-100.png",
                configuration: Self.configuration(100),
                optimizedMode: .enabled),
            PreviewCase(
                filename: "charge-limit-settings-charging-to-full.png",
                configuration: Self.configuration(
                    100,
                    temporarilyOverridden: true),
                optimizedMode: .chargingToFull),
            PreviewCase(
                filename: "optimized-charging-settings-off.png",
                configuration: Self.configuration(100),
                optimizedMode: .disabled),
            PreviewCase(
                filename: "optimized-charging-settings-off-until-tomorrow.png",
                configuration: Self.configuration(100),
                optimizedMode: .disabledUntilTomorrow),
        ]

        let outputDirectory = try previewOutputDirectory()
        for preview in previews {
            let transactions = SmartChargingTransactionCoordinator()
            let controller = ChargeLimitController(
                readConfiguration: { preview.configuration },
                writeLimit: { _ in },
                transactionCoordinator: transactions)
            let optimizedCharging = OptimizedChargingController(
                readConfiguration: { preview.optimizedMode },
                writeAction: { _ in },
                transactionCoordinator: transactions)
            await controller.refresh()
            await optimizedCharging.refresh()

            let hostingController = NSHostingController(
                rootView: content(
                    controller: controller,
                    optimizedCharging: optimizedCharging,
                    transactions: transactions))
            let size = hostingController.view.fittingSize
            hostingController.view.frame = NSRect(origin: .zero, size: size)
            hostingController.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * 2),
                pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0))
            bitmap.size = size
            hostingController.view.cacheDisplay(
                in: hostingController.view.bounds,
                to: bitmap)

            // 760-point window - 200-point sidebar - 1-point divider, with
            // 24 points of detail padding on each side.
            #expect(abs(size.width - 511) < 1)
            #expect(size.height > 130)
            #expect(size.height < 250)
            #expect(bitmap.pixelsWide == 1022)
            #expect(bitmap.pixelsHigh >= 150)

            if let outputDirectory {
                let png = try #require(bitmap.representation(
                    using: .png,
                    properties: [:]))
                try png.write(
                    to: outputDirectory.appendingPathComponent(preview.filename),
                    options: .atomic)
            }
        }
    }

    @Test("Battery Charging rows stay compact at the production detail width")
    func productionWidthLayout() async {
        let configuration = Self.configuration(100)
        let transactions = SmartChargingTransactionCoordinator()
        let controller = ChargeLimitController(
            readConfiguration: { configuration },
            writeLimit: { _ in },
            transactionCoordinator: transactions)
        let optimizedCharging = OptimizedChargingController(
            readConfiguration: { .enabled },
            writeAction: { _ in },
            transactionCoordinator: transactions)
        await controller.refresh()
        await optimizedCharging.refresh()

        let hostingController = NSHostingController(
            rootView: content(
                controller: controller,
                optimizedCharging: optimizedCharging,
                transactions: transactions))
        hostingController.view.frame = NSRect(
            origin: .zero,
            size: hostingController.view.fittingSize)
        hostingController.view.layoutSubtreeIfNeeded()

        #expect(abs(hostingController.view.fittingSize.width - 511) < 1)
        #expect(hostingController.view.fittingSize.height < 250)
    }

    private func content(
        controller: ChargeLimitController,
        optimizedCharging: OptimizedChargingController,
        transactions: SmartChargingTransactionCoordinator
    ) -> some View {
        BatteryChargingSettingsSection(
            chargeLimit: controller,
            optimizedCharging: optimizedCharging,
            transactions: transactions)
            .padding(.vertical, 12)
            .frame(width: 511)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
    }

    private func previewOutputDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment[
            "JUICE_CHARGE_TO_FULL_PREVIEW_DIR"
        ], !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        return url
    }

    private static func configuration(
        _ currentLimit: Int,
        temporarilyOverridden: Bool = false
    )
        -> ChargeLimitConfiguration
    {
        ChargeLimitConfiguration(
            selection: temporarilyOverridden
                ? .chargingToFull
                : .persistent(currentLimit),
            availableLimits: [80, 85, 90, 95, 100])
    }
}
