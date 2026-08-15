import AppKit
import SwiftUI

enum JuiceSettingsMetrics {
    static let contentSize = NSSize(width: 760, height: 520)
    static let sidebarWidth: CGFloat = 200
}

private enum JuiceSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case updates
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .updates: .blue
        case .about: .indigo
        }
    }
}

struct JuiceApplicationInfo: Equatable, Sendable {
    let name: String
    let shortVersion: String?
    let build: String?

    init(infoDictionary: [String: Any]) {
        name = Self.stringValue(infoDictionary["CFBundleDisplayName"])
            ?? Self.stringValue(infoDictionary["CFBundleName"])
            ?? "Juice"
        shortVersion = Self.stringValue(
            infoDictionary["CFBundleShortVersionString"])
        build = Self.stringValue(infoDictionary["CFBundleVersion"])
    }

    static var current: Self {
        Self(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    var versionText: String {
        switch (shortVersion, build) {
        case let (.some(version), .some(build)):
            "Version \(version) (\(build))"
        case let (.some(version), .none):
            "Version \(version)"
        case let (.none, .some(build)):
            "Build \(build)"
        case (.none, .none):
            "Version unavailable"
        }
    }

    var accessibilityVersionText: String {
        switch (shortVersion, build) {
        case let (.some(version), .some(build)):
            "Version \(version), build \(build)"
        default:
            versionText
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The app-wide preferences hosted by ``SettingsWindowPresenter``.
struct JuiceSettingsView: View {
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @ObservedObject private var updater = UpdateController.shared
    @State private var selection: JuiceSettingsCategory? = .general
    private let applicationInfo = JuiceApplicationInfo.current

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(
            width: JuiceSettingsMetrics.contentSize.width,
            height: JuiceSettingsMetrics.contentSize.height)
        .onAppear {
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            launchAtLogin.refresh()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    // The icon artwork is inset inside its image canvas. Render
                    // it larger in the same 24-point column as sidebar tiles.
                    .frame(width: 36, height: 36)
                    .frame(width: 24, height: 36, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(applicationInfo.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 36)
            .padding(.bottom, 18)

            List(selection: $selection) {
                ForEach(JuiceSettingsCategory.allCases) { category in
                    SettingsSidebarLabel(
                        category: category,
                        isSelected: selection == category)
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: JuiceSettingsMetrics.sidebarWidth)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsPage(launchAtLogin: launchAtLogin)
        case .updates:
            UpdateSettingsPage(
                updater: updater,
                applicationInfo: applicationInfo)
        case .about:
            AboutSettingsPage(applicationInfo: applicationInfo)
        }
    }
}

private struct SettingsSidebarLabel: View {
    let category: JuiceSettingsCategory
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? category.tint : .white)
                .frame(width: 24, height: 24)
                .background(
                    isSelected ? Color.white.opacity(0.9) : category.tint,
                    in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

            Text(category.title)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        SettingsPage(title: "General") {
            SettingsSection(title: "Startup") {
                VStack(spacing: 12) {
                    SettingsCard {
                        SettingsPreferenceRow(
                            systemImage: "arrow.up.forward.app",
                            title: "Open Juice at Login",
                            detail: loginItemDetail
                        ) {
                            HStack(spacing: 8) {
                                if launchAtLogin.isChanging {
                                    ProgressView()
                                        .controlSize(.small)
                                }

                                Toggle(
                                    "Open Juice at Login",
                                    isOn: Binding(
                                        get: { launchAtLogin.isRegistered },
                                        set: { launchAtLogin.setEnabled($0) }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(launchAtLogin.isChanging)
                            }
                        }
                    }

                    if launchAtLogin.requiresApproval {
                        SettingsNotice(
                            systemImage: "exclamationmark.circle.fill",
                            message: "Approval is required in System Settings before Juice can open after sign-in.",
                            tint: .orange
                        ) {
                            Button("Open Login Items…") {
                                launchAtLogin.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                    }

                    if let errorMessage = launchAtLogin.errorMessage {
                        SettingsNotice(
                            systemImage: "exclamationmark.triangle.fill",
                            message: errorMessage,
                            tint: .red
                        ) {
                            Button("Refresh Status") {
                                launchAtLogin.refresh()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var loginItemDetail: String {
        if launchAtLogin.requiresApproval {
            return "Juice is waiting for macOS approval to appear in the menu bar after you sign in."
        }
        if launchAtLogin.isEnabled {
            return "Juice will appear in the menu bar automatically the next time you sign in."
        }
        return "Juice opens only when you launch it manually."
    }
}

private struct UpdateSettingsPage: View {
    @ObservedObject var updater: UpdateController
    let applicationInfo: JuiceApplicationInfo

    var body: some View {
        SettingsPage(title: "Updates") {
            SettingsSection(title: "Software Updates") {
                if updater.isAvailable {
                    SettingsCard {
                        SettingsPreferenceRow(
                            systemImage: "arrow.triangle.2.circlepath",
                            title: "Check for updates automatically",
                            detail: automaticUpdateDetail
                        ) {
                            Toggle(
                                "Check for updates automatically",
                                isOn: Binding(
                                    get: { updater.automaticallyUpdates },
                                    set: { updater.automaticallyUpdates = $0 }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }

                        SettingsCardDivider()

                        if let readyUpdate = updater.readyUpdate {
                            SettingsPreferenceRow(
                                systemImage: "arrow.down.circle.fill",
                                iconTint: .blue,
                                title: "Juice \(readyUpdate.version) is ready",
                                detail: "Install the prepared update now, or it will install when you quit."
                            ) {
                                Button("Update & Relaunch") {
                                    updater.installReadyUpdate()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        } else {
                            SettingsPreferenceRow(
                                systemImage: "shippingbox",
                                title: applicationInfo.versionText,
                                detail: "Signed updates from Juice's release feed."
                            ) {
                                Button("Check for Updates…") {
                                    updater.checkForUpdates()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                } else {
                    SettingsNotice(
                        systemImage: "info.circle.fill",
                        message: "Updates aren't available in this build of Juice. Signed release builds can check for updates automatically or manually.",
                        tint: .secondary
                    )
                }
            }
        }
    }

    private var automaticUpdateDetail: String {
        if updater.automaticallyUpdates {
            return "Juice checks for and downloads updates automatically, then prepares them to install when you quit."
        }
        return "Automatic checks are off. You can still check for updates manually."
    }
}

private struct AboutSettingsPage: View {
    let applicationInfo: JuiceApplicationInfo

    private static let projectURL = URL(
        string: "https://github.com/EClinick/juice")!

    var body: some View {
        SettingsPage(title: "About") {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                Text(applicationInfo.name)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(applicationInfo.name)
                Text(applicationInfo.versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(applicationInfo.accessibilityVersionText)
                Text("A macOS menu bar app for understanding which apps use energy and how much power your Mac draws.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .settingsCardSurface()

            SettingsSection(title: "Information") {
                SettingsCard {
                    SettingsPreferenceRow(
                        systemImage: "hand.raised",
                        title: "Privacy",
                        detail: "Energy history stays on this Mac. Juice has no accounts or telemetry."
                    ) {
                        EmptyView()
                    }

                    SettingsCardDivider()

                    SettingsPreferenceRow(
                        systemImage: "desktopcomputer",
                        title: "Compatibility",
                        detail: "Requires macOS 14 or later. Supports Apple silicon and Intel Macs."
                    ) {
                        EmptyView()
                    }
                }
            }

            SettingsSection(title: "Links") {
                SettingsCard {
                    Link(destination: Self.projectURL) {
                        SettingsLinkRow(
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            title: "GitHub",
                            detail: "Source code · MIT License")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("GitHub, source code, MIT License")
                }
            }
        }
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .settingsCardSurface()
    }
}

private struct SettingsPreferenceRow<Accessory: View>: View {
    let systemImage: String
    var iconTint: Color = .secondary
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 48)
    }
}

private struct SettingsLinkRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)
            Image(systemName: "arrow.up.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

private extension View {
    func settingsCardSurface() -> some View {
        background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.55),
                    lineWidth: 1)
        }
    }
}

private struct SettingsNotice<Action: View>: View {
    let systemImage: String
    let message: String
    let tint: Color
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            action
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension SettingsNotice where Action == EmptyView {
    init(systemImage: String, message: String, tint: Color) {
        self.init(
            systemImage: systemImage,
            message: message,
            tint: tint,
            action: { EmptyView() }
        )
    }
}
