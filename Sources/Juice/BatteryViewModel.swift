import Foundation
import Combine

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var reading: BatteryReading?
    @Published var lastError: String?

    /// Invoked after each successful refresh with the fresh reading.
    var onReading: ((BatteryReading) -> Void)?

    private var timer: AnyCancellable?

    init(onReading: ((BatteryReading) -> Void)? = nil) {
        self.onReading = onReading
        refresh()
        // Background cadence; the popover triggers an immediate refresh on open.
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        do {
            let fresh = try BatteryMonitor.read()
            reading = fresh
            lastError = nil
            onReading?(fresh)
        } catch {
            reading = nil
            lastError = "Could not read battery state: \(error)"
        }
    }

    var timeRemainingText: String {
        guard let r = reading else { return "—" }
        if r.onAC && !r.isCharging { return "On AC power" }
        guard let mins = r.timeRemainingMinutes else { return "Estimating…" }
        let verb = r.isCharging ? "until full" : "remaining"
        return String(format: "%d:%02d %@", mins / 60, mins % 60, verb)
    }
}
