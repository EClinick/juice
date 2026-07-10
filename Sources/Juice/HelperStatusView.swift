import SwiftUI

/// Honest, actionable replacement for the former sample-data fallback.
struct HelperStatusView: View {
    @ObservedObject var controller = HelperRegistrationController.shared
    var queryError: String?
    var onRetryQuery: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
        }
    }

    private var message: String {
        switch controller.state {
        case .checking: return "Checking per-app energy access…"
        case .registering: return "Preparing the per-app energy helper…"
        case .enabled:
            return queryError.map { "Per-app energy could not be read: \($0)" }
                ?? "Per-app energy is temporarily unavailable."
        case .requiresApproval:
            return "Approve Juice in Login Items to read per-app energy from macOS."
        case .needsApplicationInstall:
            return "Move Juice to Applications and reopen it to enable per-app energy."
        case .notRegistered:
            return "Enable Juice's read-only helper to show per-app energy."
        case .notFound:
            return "This copy of Juice is missing its per-app energy helper."
        case .failed(let detail):
            return "The per-app energy helper could not be prepared: \(detail)"
        }
    }

    private var actionTitle: String? {
        switch controller.state {
        case .requiresApproval: return "Open System Settings"
        case .enabled where queryError != nil && onRetryQuery != nil: return "Try Again"
        case .notRegistered, .notFound, .failed: return "Retry"
        case .needsApplicationInstall: return nil
        default: return nil
        }
    }

    private func action() {
        switch controller.state {
        case .requiresApproval: controller.openApprovalSettings()
        case .enabled: onRetryQuery?()
        case .notRegistered, .notFound, .failed: controller.retry()
        default: break
        }
    }

    private var iconName: String {
        switch controller.state {
        case .checking, .registering: return "hourglass"
        case .requiresApproval: return "lock.open"
        case .enabled: return "exclamationmark.triangle"
        default: return "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch controller.state {
        case .checking, .registering: return .secondary
        case .requiresApproval: return .orange
        case .enabled: return .orange
        default: return .red
        }
    }
}
