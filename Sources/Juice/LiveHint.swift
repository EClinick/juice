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
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
