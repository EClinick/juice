import Foundation
import Combine

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var reading: BatteryReading?
    @Published var lastError: String?
    @Published private(set) var isLowPowerModeEnabled: Bool
    let isMacMini: Bool

    /// Invoked after each successful refresh with the fresh reading.
    var onReading: ((BatteryReading) -> Void)?

    private var timer: AnyCancellable?
    private var powerStateObserver: AnyCancellable?
    private let lowPowerModeProvider: () -> Bool
    private let batteryReader: () throws -> BatteryReading

    init(
        onReading: ((BatteryReading) -> Void)? = nil,
        isMacMini: Bool = MacHardware.isCurrentMacMini,
        batteryReader: @escaping () throws -> BatteryReading = BatteryMonitor.read,
        lowPowerModeProvider: @escaping () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.onReading = onReading
        self.isMacMini = isMacMini
        self.batteryReader = batteryReader
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
        // A Mac mini intentionally has no battery. Its current-power reading is
        // supplied by LivePowerCoordinator, so absence of AppleSmartBattery is
        // a supported mode rather than an error.
        guard !isMacMini else {
            reading = nil
            lastError = nil
            return
        }
        do {
            let fresh = try batteryReader()
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
