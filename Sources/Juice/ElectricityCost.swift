import Foundation

/// Shared electricity-rate storage, calculation, and currency formatting.
///
/// Power is an instantaneous rate in watts, so cost is derived from the
/// recorded energy for the selected range rather than projected from a single
/// live reading.
enum ElectricityCost {
    static let pricePerKilowattHourStorageKey = "electricityPricePerKilowattHour"
    static let defaultPricePerKilowattHour = 0.0

    /// User-entered rates must be finite and non-negative. A zero rate means
    /// cost estimates are disabled and keeps existing energy UI unchanged.
    static func normalizedPrice(_ pricePerKilowattHour: Double) -> Double {
        guard pricePerKilowattHour.isFinite, pricePerKilowattHour > 0 else {
            return 0
        }
        return pricePerKilowattHour
    }

    static func estimate(
        wattHours: Double,
        pricePerKilowattHour: Double
    ) -> Double? {
        let price = normalizedPrice(pricePerKilowattHour)
        guard wattHours.isFinite, wattHours >= 0, price > 0 else { return nil }

        let cost = wattHours / 1_000 * price
        return cost.isFinite ? cost : nil
    }

    /// Produces a stable range total even if a corrupt or partially-written
    /// history row contains an invalid energy value.
    static func totalWattHours(_ values: [Double]) -> Double {
        values.reduce(0) { total, value in
            guard value.isFinite, value > 0 else { return total }
            let updatedTotal = total + value
            return updatedTotal.isFinite ? updatedTotal : total
        }
    }

    /// Formats small app costs with enough precision to avoid displaying a
    /// positive estimate as zero. Values below one millionth of a currency
    /// unit use a localized less-than threshold.
    static func formattedEstimate(
        wattHours: Double,
        pricePerKilowattHour: Double,
        locale: Locale = .current
    ) -> String? {
        guard let cost = estimate(
            wattHours: wattHours,
            pricePerKilowattHour: pricePerKilowattHour)
        else { return nil }

        let smallestDisplayedCost = 0.000_001
        if cost > 0, cost < smallestDisplayedCost {
            return "<" + currencyText(
                smallestDisplayedCost,
                maximumFractionDigits: 6,
                locale: locale)
        }

        let maximumFractionDigits: Int
        if cost == 0 || cost >= 0.01 {
            maximumFractionDigits = 2
        } else if cost >= 0.000_1 {
            maximumFractionDigits = 4
        } else {
            maximumFractionDigits = 6
        }
        return currencyText(
            cost,
            maximumFractionDigits: maximumFractionDigits,
            locale: locale)
    }

    static func currencyCode(locale: Locale = .current) -> String {
        locale.currency?.identifier ?? "USD"
    }

    private static func currencyText(
        _ value: Double,
        maximumFractionDigits: Int,
        locale: Locale
    ) -> String {
        value.formatted(
            .currency(code: currencyCode(locale: locale))
                .precision(.fractionLength(2...maximumFractionDigits))
                .locale(locale))
    }
}
