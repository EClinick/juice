import Foundation
import Combine

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var reading: BatteryReading?
    @Published var lastError: String?
    @Published private(set) var isLowPowerModeEnabled: Bool

    /// Invoked after each successful refresh with the fresh reading.
    var onReading: ((BatteryReading) -> Void)?

    private var timer: AnyCancellable?
    private var powerStateObserver: AnyCancellable?
    private let lowPowerModeProvider: () -> Bool

    init(
        onReading: ((BatteryReading) -> Void)? = nil,
        lowPowerModeProvider: @escaping () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.onReading = onReading
        self.lowPowerModeProvider = lowPowerModeProvider
        isLowPowerModeEnabled = lowPowerModeProvider()
        refresh()
        // Background cadence; the popover triggers an immediate refresh on open.
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        // Power mode can change independently of a battery reading. Observe the
        // system notification so the menu bar icon updates immediately.
        powerStateObserver = notificationCenter.publisher(
            for: .NSProcessInfoPowerStateDidChange
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            self.isLowPowerModeEnabled = self.lowPowerModeProvider()
        }
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
