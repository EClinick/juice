import AppKit
import SwiftUI
import Testing
@testable import Juice

private final class TwoTickSettingsRefreshSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var callCountStorage = 0
    private var durationsStorage: [Duration] = []

    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in
            let shouldStop = self.lock.withLock {
                self.callCountStorage += 1
                self.durationsStorage.append(duration)
                return self.callCountStorage >= 2
            }
            if shouldStop {
                throw CancellationError()
            }
        }
    }

    var callCount: Int {
        lock.withLock { callCountStorage }
    }

    var durations: [Duration] {
        lock.withLock { durationsStorage }
    }

}

private final class SettingsRefreshSequence<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]
    private(set) var readCount = 0

    init(_ values: [Value]) {
        self.values = values
    }

    var read: @Sendable () async throws -> Value? {
        {
            self.lock.withLock {
                self.readCount += 1
                return self.values.count == 1
                    ? self.values[0]
                    : self.values.removeFirst()
            }
        }
    }
}

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

    @Test("Active Settings periodically refreshes temporary charging modes")
    func temporaryModesRefreshOnCadence() async {
        let transactions = SmartChargingTransactionCoordinator()
        let limits = SettingsRefreshSequence([
            Self.configuration(100, temporarilyOverridden: true),
            Self.configuration(90),
        ])
        let optimizedModes = SettingsRefreshSequence([
            OptimizedChargingMode.disabledUntilTomorrow,
            .enabled,
        ])
        let chargeLimit = ChargeLimitController(
            readConfiguration: limits.read,
            writeLimit: { _ in },
            transactionCoordinator: transactions)
        let optimizedCharging = OptimizedChargingController(
            readConfiguration: optimizedModes.read,
            writeAction: { _ in },
            transactionCoordinator: transactions)
        let sleeper = TwoTickSettingsRefreshSleeper()
        var limitStatuses: [ChargeLimitStatus] = []
        var optimizedStatuses: [OptimizedChargingStatus] = []

        await SmartChargingSettingsRefreshLoop.run(sleep: sleeper.sleep) {
            async let limit: Void = chargeLimit.refresh()
            async let optimized: Void = optimizedCharging.refresh()
            _ = await (limit, optimized)
            limitStatuses.append(chargeLimit.status)
            optimizedStatuses.append(optimizedCharging.status)
        }

        #expect(limitStatuses == [
            .available(Self.configuration(
                100,
                temporarilyOverridden: true)),
            .available(Self.configuration(90)),
        ])
        #expect(optimizedStatuses == [
            .available(.disabledUntilTomorrow),
            .available(.enabled),
        ])
        #expect(chargeLimit.status == .available(Self.configuration(90)))
        #expect(optimizedCharging.status == .available(.enabled))
        #expect(limits.readCount == 2)
        #expect(optimizedModes.readCount == 2)
        #expect(sleeper.callCount == 2)
        #expect(sleeper.durations == [.seconds(60), .seconds(60)])
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
