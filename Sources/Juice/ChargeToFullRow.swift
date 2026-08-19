import SwiftUI

/// Compact, contextual action placed immediately beneath the battery hero.
/// It is conditional, so the rest of the popover keeps its existing density
/// whenever macOS has no authoritative one-time override to offer.
struct ChargeToFullRow: View {
    let state: ChargeToFullState
    let action: () -> Void

    private var title: String {
        switch state {
        case .ready:
            return state.reason.rowTitle
        case .starting:
            return "Starting full charge"
        case .accepted:
            return "Full charge requested"
        case .failed:
            return "Couldn’t start full charge"
        }
    }

    private var detail: String {
        switch state {
        case .ready:
            return state.reason.rowDetail
        case .starting:
            return "Waiting for macOS to confirm the change."
        case .accepted:
            return "Waiting for charging to begin."
        case .failed(let reason):
            switch reason {
            case .optimized(let percent):
                return "The Mac is still holding at \(percent)%."
            case .limit(let percent):
                return "The Mac is still at its \(percent)% limit."
            }
        }
    }

    private var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }

    private var isAccepted: Bool {
        if case .accepted = state { return true }
        return false
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    @ViewBuilder
    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(isFailure ? .orange : .secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isAccepted {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Full charge request accepted")
        } else {
            Button(action: action) {
                HStack(spacing: 4) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(isFailure ? "Try Again" : isStarting ? "Starting…" : "Charge to Full Now")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isStarting)
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                statusCopy
                    .frame(minWidth: 105, maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                trailingControl
            }

            VStack(alignment: .leading, spacing: 6) {
                statusCopy
                HStack {
                    Spacer()
                    trailingControl
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}
