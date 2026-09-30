import Foundation
import Testing
@testable import Juice

@Suite("Electricity cost")
struct ElectricityCostTests {
    private let usLocale = Locale(identifier: "en_US")

    @Test("watt-hours are converted to kilowatt-hours before applying the rate")
    func estimateUsesKilowattHours() throws {
        let cost = try #require(ElectricityCost.estimate(
            wattHours: 1_250,
            pricePerKilowattHour: 0.32))

        #expect(abs(cost - 0.40) < 1e-12)
    }

    @Test("range totals sum valid recorded energy before applying the rate")
    func recordedEnergyTotal() throws {
        let total = ElectricityCost.totalWattHours([
            750, 500, -20, .nan, .infinity,
        ])
        let cost = try #require(ElectricityCost.estimate(
            wattHours: total,
            pricePerKilowattHour: 0.32))

        #expect(total == 1_250)
        #expect(abs(cost - 0.40) < 1e-12)
    }

    @Test("range totals remain finite if valid rows would overflow")
    func recordedEnergyOverflow() {
        let total = ElectricityCost.totalWattHours([
            Double.greatestFiniteMagnitude,
            Double.greatestFiniteMagnitude,
        ])

        #expect(total == Double.greatestFiniteMagnitude)
    }

    @Test("zero or invalid prices disable cost estimates")
    func invalidPricesDisableEstimates() {
        #expect(ElectricityCost.estimate(
            wattHours: 100,
            pricePerKilowattHour: 0) == nil)
        #expect(ElectricityCost.estimate(
            wattHours: 100,
            pricePerKilowattHour: -0.25) == nil)
        #expect(ElectricityCost.estimate(
            wattHours: 100,
            pricePerKilowattHour: .infinity) == nil)
        #expect(ElectricityCost.estimate(
            wattHours: .nan,
            pricePerKilowattHour: 0.25) == nil)
    }

    @Test("positive fractional costs do not round to zero")
    func fractionalCostFormatting() {
        #expect(ElectricityCost.formattedEstimate(
            wattHours: 1_250,
            pricePerKilowattHour: 0.32,
            locale: usLocale) == "$0.40")
        #expect(ElectricityCost.formattedEstimate(
            wattHours: 1,
            pricePerKilowattHour: 0.30,
            locale: usLocale) == "$0.0003")
        #expect(ElectricityCost.formattedEstimate(
            wattHours: 0.000_1,
            pricePerKilowattHour: 0.30,
            locale: usLocale) == "<$0.000001")
    }

    @Test("zero energy remains a real zero once a price is configured")
    func zeroEnergyFormatting() {
        #expect(ElectricityCost.formattedEstimate(
            wattHours: 0,
            pricePerKilowattHour: 0.30,
            locale: usLocale) == "$0.00")
    }

    @Test("currency follows the selected locale")
    func localeCurrency() {
        #expect(ElectricityCost.currencyCode(
            locale: Locale(identifier: "en_GB")) == "GBP")
    }
}
