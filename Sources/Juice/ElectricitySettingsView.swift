import SwiftUI

struct ElectricitySettingsView: View {
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

    var body: some View {
        Form {
            Section("Electricity") {
                LabeledContent("Price per kWh") {
                    HStack(spacing: 6) {
                        TextField(
                            "0.00",
                            value: normalizedPriceBinding,
                            format: .number.precision(.fractionLength(2...6)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 100)
                            .accessibilityLabel("Electricity price per kilowatt-hour")

                        Text(ElectricityCost.currencyCode())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(
                    "Use the energy rate from your electric bill. "
                    + "Juice multiplies each app's recorded energy for the "
                    + "selected range by this price.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let exampleCost {
                    Text("At this rate, 100 Wh costs \(exampleCost).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Enter a price above zero to show app cost estimates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 210)
        .onAppear {
            pricePerKilowattHour = ElectricityCost.normalizedPrice(pricePerKilowattHour)
        }
    }
}
