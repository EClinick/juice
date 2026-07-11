import SwiftUI
import Charts
import AppKit
import JuiceCore

/// Detail window content for a single app: where its energy came from
/// (CPU/GPU/Neural Engine), when it was used across the range window, and a
/// plain-English explanation of the pattern.
///
/// Data arrives through an injected async `provider` closure so the view can
/// be previewed and tested without a live XPC connection.
struct AppDetailView: View {
    enum Resolution {
        case hourlyComponents
        case dailyTotals
    }

    let displayName: String
    let bundleId: String
    let rangeLabel: String
    let windowStart: Date
    let windowEnd: Date
    let windowHours: Int
    let resolution: Resolution
    let provider: () async throws -> AppEnergyBreakdown

    private enum LoadState {
        case loading
        case loaded(AppEnergyBreakdown)
        case failed(String)
    }

    private enum ProcessLoadState: Equatable {
        case idle
        case loading
        case loaded
        case timedOut
    }

    private enum DetailLoadError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            "Energy details took too long to load. Try opening this app again."
        }
    }

    /// A non-blocking race between the helper request and its timeout. The
    /// XPC request is deliberately unstructured: cancellation cannot force a
    /// missing XPC reply to return, so the UI must not wait for it on timeout.
    private final class DetailLoadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<AppEnergyBreakdown, Error>?
        private var resolved = false

        func install(_ continuation: CheckedContinuation<AppEnergyBreakdown, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(_ result: Result<AppEnergyBreakdown, Error>) {
            lock.lock()
            guard !resolved, let continuation else {
                lock.unlock()
                return
            }
            resolved = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    @State private var state: LoadState = .loading
    @State private var processes: [AppProcess] = []
    @State private var showsAllProcesses = false
    @State private var processLoadState: ProcessLoadState = .idle
    @State private var processLoadID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .loading:
                ProgressView("Loading energy details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "bolt.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let breakdown):
                content(breakdown)
            }
        }
        .frame(minWidth: 540, minHeight: 520)
        .task {
            do {
                let breakdown = try await loadBreakdown()
                state = .loaded(breakdown)
                if resolution == .hourlyComponents {
                    loadProcesses()
                }
            } catch {
                state = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "Detailed data needs the helper connection."
                )
            }
        }
    }

    /// Process discovery is helpful context, but it must never delay the
    /// authoritative energy summary. A slow system process table degrades to
    /// an explanatory process-state message after a short timeout.
    private func loadProcesses() {
        let loadID = UUID()
        processLoadID = loadID
        processLoadState = .loading
        let rootPIDs = AppProcessInspector.rootPIDs(for: bundleId)

        Task {
            let result = await Task.detached {
                AppProcessInspector.processes(appKey: bundleId, rootPIDs: rootPIDs)
            }.value
            guard processLoadID == loadID, processLoadState == .loading else { return }
            switch result {
            case .loaded(let liveProcesses):
                processes = liveProcesses
                processLoadState = .loaded
            case .timedOut:
                processLoadState = .timedOut
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard processLoadID == loadID, processLoadState == .loading else { return }
            processLoadState = .timedOut
        }
    }

    /// XPC should normally return in well under a second. A timeout prevents
    /// an unavailable or wedged helper from leaving the detail window in a
    /// permanent loading state.
    private func loadBreakdown() async throws -> AppEnergyBreakdown {
        let gate = DetailLoadGate()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)

            Task {
                do {
                    gate.resolve(.success(try await provider()))
                } catch {
                    gate.resolve(.failure(error))
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                gate.resolve(.failure(DetailLoadError.timedOut))
            }
        }
    }

    // MARK: - Loaded content

    private func content(_ breakdown: AppEnergyBreakdown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(breakdown)
                if resolution == .hourlyComponents {
                    componentBreakdown(breakdown)
                }
                energyChart(breakdown)
                if resolution == .dailyTotals {
                    historicalSummary(breakdown)
                } else {
                    explanation(breakdown)
                }
                statLine(breakdown)
                if resolution == .hourlyComponents {
                    processBreakdown(breakdown)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func header(_ breakdown: AppEnergyBreakdown) -> some View {
        HStack(spacing: 10) {
            DetailAppIconView(bundleId: bundleId, displayName: displayName)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text("\(String(format: "%.1f Wh", breakdown.totalWh)) · \(rangeLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Component breakdown

    private struct Component: Identifiable {
        var id: String { name }
        let name: String
        let wh: Double
        let share: Double
        let color: Color
    }

    private func components(_ breakdown: AppEnergyBreakdown) -> [Component] {
        [
            Component(name: "CPU", wh: breakdown.cpuWh,
                      share: breakdown.cpuShare, color: .accentColor),
            Component(name: "GPU", wh: breakdown.gpuWh,
                      share: breakdown.gpuShare, color: .orange),
            Component(name: "Neural Engine", wh: breakdown.aneWh,
                      share: breakdown.aneShare, color: .green)
        ]
    }

    private func componentBreakdown(_ breakdown: AppEnergyBreakdown) -> some View {
        let components = components(breakdown)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Where the energy went")
                .font(.caption)
                .foregroundStyle(.secondary)

            // One stacked horizontal bar; segments proportional to share.
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(components) { component in
                        Rectangle()
                            .fill(component.color)
                            .frame(width: geo.size.width
                                   * CGFloat(max(0, min(1, component.share))))
                    }
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            }
            .frame(height: 8)

            HStack(spacing: 12) {
                ForEach(components) { component in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(component.color)
                            .frame(width: 7, height: 7)
                        Text(String(format: "%@ %.0f%% · %.1f Wh",
                                    component.name, component.share * 100, component.wh))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Hourly chart

    /// Hourly energy over the range window. The x-axis is pinned to the full
    /// window (matching ``ChargeTimelineView``) so hours with no energy show
    /// as gaps rather than the data stretching to fill the chart.
    private func energyChart(_ breakdown: AppEnergyBreakdown) -> some View {
        let isDaily = resolution == .dailyTotals
        let component: Calendar.Component = isDaily ? .day : .hour
        return VStack(alignment: .leading, spacing: 6) {
            Text(isDaily ? "Energy by day" : "Energy by hour")
                .font(.caption)
                .foregroundStyle(.secondary)

            Chart(breakdown.hourlyWh, id: \.bucketStart) { bucket in
                BarMark(
                    x: .value(isDaily ? "Day" : "Hour", bucket.bucketStart, unit: component),
                    y: .value("Energy", bucket.wh)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXScale(domain: windowStart...windowEnd)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let wh = value.as(Double.self) {
                            Text(String(format: "%.1f Wh", wh))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.1))
                    AxisValueLabel()
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 90)
        }
    }

    // MARK: - Live process map

    private struct ProcessEnergy: Identifiable {
        let process: AppProcess
        let energyWh: Double?

        var id: Int32 { process.id }
    }

    private func attributedProcesses(_ breakdown: AppEnergyBreakdown) -> [ProcessEnergy] {
        let activeCPU = processes.reduce(0) { $0 + $1.cpuPercent }
        return processes.map { process in
            ProcessEnergy(
                process: process,
                energyWh: activeCPU > 0
                    ? breakdown.totalWh * process.cpuPercent / activeCPU
                    : nil
            )
        }
    }

    private func processBreakdown(_ breakdown: AppEnergyBreakdown) -> some View {
        let attributedProcesses = attributedProcesses(breakdown)
        let previewCount = min(3, attributedProcesses.count)
        let visibleProcesses = showsAllProcesses
            ? attributedProcesses
            : Array(attributedProcesses.prefix(previewCount))

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Processes using this app's power")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !attributedProcesses.isEmpty {
                    Text("\(attributedProcesses.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                Spacer()

                if attributedProcesses.count > previewCount {
                    Button {
                        showsAllProcesses.toggle()
                    } label: {
                        Label(
                            showsAllProcesses
                                ? "Show fewer"
                                : "View all \(attributedProcesses.count)",
                            systemImage: showsAllProcesses ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if attributedProcesses.isEmpty {
                switch processLoadState {
                case .loading, .idle:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Finding live processes…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                case .timedOut:
                    Text("Process discovery took too long. The app energy summary is still complete.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                case .loaded:
                    Text("No matching process is running now. The energy above may be from an earlier session.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Group {
                    if showsAllProcesses {
                        ScrollView {
                            VStack(spacing: 5) {
                                ForEach(visibleProcesses) { item in
                                    processRow(item)
                                }
                            }
                        }
                        .frame(maxHeight: 190)
                    } else {
                        VStack(spacing: 5) {
                            ForEach(visibleProcesses) { item in
                                processRow(item)
                            }
                        }
                    }
                }

                Text("Powerlog measures the app coalition. Process energy is estimated from this live CPU snapshot.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func processRow(_ item: ProcessEnergy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.process.isRootProcess ? "app.dashed" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.process.isRootProcess ? Color.accentColor : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.process.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("PID \(item.process.pid)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(item.process.role)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f%% CPU", item.process.cpuPercent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let energyWh = item.energyWh {
                    Text(String(format: "%.2f Wh est.", energyWh))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("CPU idle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .help(item.process.executablePath)
    }

    // MARK: - Explanation and stats

    private func historicalSummary(_ breakdown: AppEnergyBreakdown) -> some View {
        let recordedDays = breakdown.hourlyWh.filter { $0.wh > 0 }.count
        let average = recordedDays > 0 ? breakdown.totalWh / Double(recordedDays) : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Stored history")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Juice recorded energy on \(recordedDays) day\(recordedDays == 1 ? "" : "s"), averaging \(String(format: "%.1f Wh", average)) per recorded day.")
                .font(.callout)
            Text("Component and hourly measurements are only available while macOS retains the raw PowerLog data.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func explanation(_ breakdown: AppEnergyBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why it used this much")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(
                BreakdownBuilder.explanation(for: breakdown, windowHours: windowHours),
                id: \.self
            ) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(line)
                }
                .font(.callout)
            }
        }
    }

    private func statLine(_ breakdown: AppEnergyBreakdown) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%.1f CPU-hours", breakdown.cpuHours))
            if breakdown.activeHours > 0 {
                Text("·")
                Text(String(format: "%.1f W average while active",
                            breakdown.totalWh / breakdown.activeHours))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// The app's real icon when the bundle id resolves, otherwise a lettered
/// placeholder. Mirrors the icon-loading approach in ``TopAppsView``.
private struct DetailAppIconView: View {
    let bundleId: String
    let displayName: String

    var body: some View {
        if let icon = Self.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.25))
                .overlay(
                    Text(String(displayName.prefix(1)))
                        .font(.system(size: 16, weight: .semibold))
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
