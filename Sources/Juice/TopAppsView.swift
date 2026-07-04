import SwiftUI
import AppKit

/// Ranked list of per-app energy usage with a range picker.
struct TopAppsView: View {
    let apps: [AppEnergy]
    @Binding var range: EnergyRange

    private var maxEnergy: Double {
        max(apps.map(\.energyWh).max() ?? 0, 0.001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $range) {
                ForEach(EnergyRange.allCases, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 6) {
                ForEach(apps) { app in
                    AppEnergyRow(app: app, fraction: app.energyWh / maxEnergy) {
                        AppDetailPresenter.shared.show(
                            appKey: app.bundleId,
                            displayName: app.displayName,
                            range: range
                        )
                    }
                }
            }
        }
    }
}

/// One tappable row; tapping opens the per-app detail window. A chevron
/// appears on hover to hint at the interaction.
private struct AppEnergyRow: View {
    let app: AppEnergy
    let fraction: Double
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(bundleId: app.bundleId, displayName: app.displayName)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.caption)
                    .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
                    }
                }
                .frame(height: 5)
            }

            Text(String(format: "%.1f Wh", app.energyWh))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

/// The app's real icon when the bundle id resolves, otherwise a lettered placeholder.
private struct AppIconView: View {
    let bundleId: String
    let displayName: String

    var body: some View {
        if let icon = Self.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.25))
                .overlay(
                    Text(String(displayName.prefix(1)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    private static func icon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
