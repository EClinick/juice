import SwiftUI

/// Compact electricity-rate editor embedded in both Stats dashboards.
///
/// Keeping the only app preference beside the cost estimates it affects avoids
/// a second settings window and makes rate changes immediately understandable.
struct ElectricityRateControl: View {
    @AppStorage(ElectricityCost.pricePerKilowattHourStorageKey)
    private var pricePerKilowattHour = ElectricityCost.defaultPricePerKilowattHour

    private var normalizedPriceBinding: Binding<Double> {
        Binding(
            get: { ElectricityCost.normalizedPrice(pricePerKilowattHour) },
            set: { pricePerKilowattHour = ElectricityCost.normalizedPrice($0) })
    }

    private var exampleCost: String? {
        ElectricityCost.formattedEstimate(
            wattHours: 100,
            pricePerKilowattHour: pricePerKilowattHour)
    }

    private var helpText: String {
        let base = "Use the price per kWh from your electric bill. Juice uses it to estimate each app's cost."
        guard let exampleCost else { return base }
        return "\(base) At this rate, 100 Wh costs \(exampleCost)."
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("kWh price")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                "Price per kWh",
                value: normalizedPriceBinding,
                format: .number.precision(.fractionLength(2...6)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 76)
                .accessibilityLabel("Electricity price per kilowatt-hour")
                .accessibilityHint(
                    "Enter the price from your electric bill in "
                    + "\(ElectricityCost.currencyCode()) per kilowatt-hour")

            Text(ElectricityCost.currencyCode())
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(exampleCost.map { "100 Wh = \($0)" } ?? "Set a rate")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .controlSize(.small)
        .help(helpText)
        .onAppear {
            pricePerKilowattHour = ElectricityCost.normalizedPrice(pricePerKilowattHour)
        }
    }
}
