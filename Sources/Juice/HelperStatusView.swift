import SwiftUI

/// Honest, actionable replacement for the former sample-data fallback.
struct HelperStatusView: View {
    @ObservedObject var controller = HelperRegistrationController.shared
    var queryError: String?
    var onRetryQuery: (() -> Void)?
    /// User-facing capability supplied by the helper. The default preserves
    /// the historical per-app messages; Mac mini mode calls it current power.
    var purpose = "per-app energy"

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
        case .checking: return "Checking \(purpose) access…"
        case .registering: return "Preparing the \(purpose) helper…"
        case .enabled:
            return queryError.map { "\(capitalizedPurpose) could not be read: \($0)" }
                ?? "\(capitalizedPurpose) is temporarily unavailable."
        case .requiresApproval:
            return "Approve Juice in Login Items to read \(purpose) from macOS."
        case .needsApplicationInstall:
            return "Move Juice to Applications and reopen it to enable \(purpose)."
        case .notRegistered:
            return "Enable Juice's read-only helper to show \(purpose)."
        case .bundleMissing(let detail):
            return "This copy of Juice is missing its \(purpose) helper: \(detail)"
        case .failed(let detail):
            return "The \(purpose) helper could not be prepared: \(detail)"
        }
    }

    private var capitalizedPurpose: String {
        purpose.prefix(1).uppercased() + purpose.dropFirst()
    }

    private var actionTitle: String? {
        switch controller.state {
        case .requiresApproval: return "Open System Settings"
        case .enabled where queryError != nil && onRetryQuery != nil: return "Try Again"
        case .notRegistered, .bundleMissing, .failed: return "Retry"
        case .needsApplicationInstall: return nil
        default: return nil
        }
    }

    private func action() {
        switch controller.state {
        case .requiresApproval: controller.openApprovalSettings()
        case .enabled: onRetryQuery?()
        case .notRegistered, .bundleMissing, .failed: controller.retry()
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
