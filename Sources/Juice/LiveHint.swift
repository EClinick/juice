import SwiftUI

/// A quiet "LIVE" indicator: a subtly pulsing green dot beside a caption label,
/// shown while a live view is sampling.
struct LiveHint: View {
    var body: some View {
        HStack(spacing: 4) {
            LiveDot()
            Text("LIVE")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .help("Updates every 2 s")
    }
}

/// A subtly pulsing green dot, reused wherever a live indicator is needed.
struct LiveDot: View {
    @Environment(\.juiceSurfaceIsActive) private var surfaceIsActive
    @State private var pulsing = false

    var body: some View {
        Group {
            if surfaceIsActive {
                dot
                    .opacity(pulsing ? 0.35 : 1)
                    .animation(
                        .easeInOut(duration: 1).repeatForever(autoreverses: true),
                        value: pulsing)
                    .onAppear { pulsing = true }
            } else {
                // Use a separate static subtree. Removing the animated branch
                // is what reliably tears down SwiftUI's repeat-forever driver.
                dot
            }
        }
        .onChange(of: surfaceIsActive) {
            if !surfaceIsActive {
                pulsing = false
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
    }
}
