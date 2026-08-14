import AppKit
import SwiftUI

private enum JuiceSettingsCategory: String, CaseIterable, Identifiable {
    case general
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .updates: "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// The app-wide preferences hosted by ``SettingsWindowPresenter``.
struct JuiceSettingsView: View {
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared
    @ObservedObject private var updater = UpdateController.shared
    @State private var selection: JuiceSettingsCategory? = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 660, height: 420)
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
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)

                Text("Juice")
                    .font(.headline)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(selection: $selection) {
                ForEach(JuiceSettingsCategory.allCases) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 178)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsPage(launchAtLogin: launchAtLogin)
        case .updates:
            UpdateSettingsPage(updater: updater)
        }
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Control how Juice behaves on this Mac."
        ) {
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
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(
                        launchAtLogin.isChanging
                            || launchAtLogin.requiresApproval)
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

    var body: some View {
        SettingsPage(
            title: "Updates",
            subtitle: "Choose how Juice receives signed app updates."
        ) {
            if updater.isAvailable {
                SettingsPreferenceRow(
                    systemImage: "arrow.down.circle",
                    title: "Automatic updates",
                    detail: automaticUpdateDetail
                ) {
                    Toggle(
                        "Automatic updates",
                        isOn: Binding(
                            get: { updater.automaticallyUpdates },
                            set: { updater.automaticallyUpdates = $0 }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                Divider()
                    .padding(.vertical, 2)

                if let readyUpdate = updater.readyUpdate {
                    SettingsPreferenceRow(
                        systemImage: "arrow.down.circle.fill",
                        iconTint: .blue,
                        title: "Juice \(readyUpdate.version) is ready",
                        detail: "The update will install when you quit, or you can install it now and relaunch Juice."
                    ) {
                        Button("Update & Relaunch") {
                            updater.installReadyUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    SettingsPreferenceRow(
                        systemImage: "magnifyingglass.circle",
                        title: "Check manually",
                        detail: "Ask Juice to check now. The update window will show whether a newer version is available."
                    ) {
                        Button("Check for Updates…") {
                            updater.checkForUpdates()
                        }
                        .controlSize(.small)
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

    private var automaticUpdateDetail: String {
        if updater.automaticallyUpdates {
            return "Juice checks for and downloads updates automatically, then prepares them to install when you quit."
        }
        return "Automatic checks are off. You can still check for updates manually."
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.top, 24)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SettingsPreferenceRow<Accessory: View>: View {
    let systemImage: String
    var iconTint: Color = .accentColor
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 24, height: 24)
                .background(iconTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            accessory
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
