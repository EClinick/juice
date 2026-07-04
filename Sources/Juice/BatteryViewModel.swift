import Foundation
import Combine

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var reading: BatteryReading?
    @Published var lastError: String?

    private var timer: AnyCancellable?

    init() {
        refresh()
        // Background cadence; the popover triggers an immediate refresh on open.
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        do {
            reading = try BatteryMonitor.read()
            lastError = nil
        } catch {
            reading = nil
            lastError = "Could not read battery state: \(error)"
        }
    }

    var menuBarTitle: String {
        guard let r = reading, r.hasBattery else { return "–" }
        let wattsPart: String
        if r.onAC && !r.isCharging {
            wattsPart = "AC"
        } else if r.isCharging {
            wattsPart = String(format: "+%.1f W", abs(r.watts))
        } else {
            wattsPart = String(format: "%.1f W", abs(r.watts))
        }
        return "\(r.percent)% · \(wattsPart)"
    }

    var timeRemainingText: String {
        guard let r = reading else { return "—" }
        if r.onAC && !r.isCharging { return "On AC power" }
        guard let mins = r.timeRemainingMinutes else { return "Estimating…" }
        let verb = r.isCharging ? "until full" : "remaining"
        return String(format: "%d:%02d %@", mins / 60, mins % 60, verb)
    }
}
