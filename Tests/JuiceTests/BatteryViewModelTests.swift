import Foundation
import Combine
import Testing
@testable import Juice

@Suite("Battery view model")
struct BatteryViewModelTests {
    @MainActor
    @Test("Laptop polling and power-state changes refresh their state")
    func laptopBackgroundUpdatesRefreshState() async {
        var isLowPowerModeEnabled = false
        var batteryReadCount = 0
        var pollingPublisherCreationCount = 0
        let pollingSubject = PassthroughSubject<Date, Never>()
        let notificationCenter = NotificationCenter()
        let model = BatteryViewModel(
            isMacMini: false,
            batteryReader: {
                batteryReadCount += 1
                return BatteryReading(
                    percent: 50,
                    watts: 5,
                    isCharging: false,
                    onAC: false,
                    timeRemainingMinutes: 120,
                    cycleCount: 10,
                    healthPercent: 95,
                    hasBattery: true)
            },
            lowPowerModeProvider: { isLowPowerModeEnabled },
            notificationCenter: notificationCenter,
            batteryPollingPublisher: {
                pollingPublisherCreationCount += 1
                return pollingSubject.eraseToAnyPublisher()
            })

        #expect(batteryReadCount == 1)
        #expect(pollingPublisherCreationCount == 1)
        #expect(!model.isLowPowerModeEnabled)

        pollingSubject.send(Date())
        #expect(batteryReadCount == 2)

        isLowPowerModeEnabled = true
        notificationCenter.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(model.isLowPowerModeEnabled)
    }

    @MainActor
    @Test("Mac mini mode schedules no battery or power-state background work")
    func macMiniSkipsBatteryBackgroundWork() async {
        var readCount = 0
        var lowPowerModeReadCount = 0
        var pollingPublisherCreationCount = 0
        var isLowPowerModeEnabled = true
        let notificationCenter = NotificationCenter()
        let model = BatteryViewModel(
            isMacMini: true,
            batteryReader: {
                readCount += 1
                throw BatteryMonitorError.serviceNotFound
            },
            lowPowerModeProvider: {
                lowPowerModeReadCount += 1
                return isLowPowerModeEnabled
            },
            notificationCenter: notificationCenter,
            batteryPollingPublisher: {
                pollingPublisherCreationCount += 1
                return Empty().eraseToAnyPublisher()
            })

        #expect(readCount == 0)
        #expect(lowPowerModeReadCount == 1)
        #expect(pollingPublisherCreationCount == 0)
        #expect(model.isLowPowerModeEnabled)
        #expect(model.reading == nil)
        #expect(model.lastError == nil)

        isLowPowerModeEnabled = false
        notificationCenter.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: nil)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(readCount == 0)
        #expect(lowPowerModeReadCount == 1)
        #expect(model.isLowPowerModeEnabled)
    }
}
