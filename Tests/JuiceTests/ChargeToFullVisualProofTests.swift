import AppKit
import SwiftUI
import Testing
@testable import Juice
@testable import JuiceXPCShared

@MainActor
struct ChargeToFullVisualProofTests {
    private struct PreviewCase {
        let filename: String
        let reading: BatteryReading
        let state: ChargeToFullState
    }

    @Test("Charge to Full mocked states render at the popover width")
    func mockedStatesRender() async throws {
        let suite = "ChargeToFullVisualProofTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let energyMode = EnergyModeController(
            defaults: defaults,
            readState: {
                PowerModeState(
                    battery: .automatic,
                    ac: .automatic,
                    keyLayout: .unified)
            },
            writeState: { _, _ in
                PowerModeState(
                    battery: .automatic,
                    ac: .automatic,
                    keyLayout: .unified)
            })
        await energyMode.refresh()

        let previews = [
            PreviewCase(
                filename: "charge-to-full-optimized.png",
                reading: Self.reading(percent: 80),
                state: .ready(.optimized(currentPercent: 80))),
            PreviewCase(
                filename: "charge-to-full-limit.png",
                reading: Self.reading(percent: 85),
                state: .ready(.limit(percent: 85)))
        ]

        let outputDirectory = try previewOutputDirectory()
        for preview in previews {
            let renderer = ImageRenderer(content: content(
                reading: preview.reading,
                state: preview.state,
                energyMode: energyMode))
            renderer.scale = 2

            let image = try #require(renderer.cgImage)
            #expect(image.width == 640)
            #expect(image.height > 300)

            if let outputDirectory {
                let representation = NSBitmapImageRep(cgImage: image)
                let png = try #require(representation.representation(
                    using: .png,
                    properties: [:]))
                try png.write(
                    to: outputDirectory.appendingPathComponent(preview.filename),
                    options: .atomic)
            }
        }
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

    private func content(
        reading: BatteryReading,
        state: ChargeToFullState,
        energyMode: EnergyModeController
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                BatteryHeroRow(
                    reading: reading,
                    timeRemainingText: "On AC power",
                    controller: energyMode,
                    isLowPowerModeEnabled: false,
                    headlineOverride: state.headline)
                EnergyModeCaptions(controller: energyMode, onAC: true)
            }

            ChargeToFullRow(state: state, action: {})

            HStack {
                Text("Top energy users")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }

    private static func reading(percent: Int) -> BatteryReading {
        BatteryReading(
            percent: percent,
            watts: 0,
            isCharging: false,
            onAC: true,
            timeRemainingMinutes: nil,
            cycleCount: 25,
            healthPercent: 100,
            hasBattery: true)
    }
}
