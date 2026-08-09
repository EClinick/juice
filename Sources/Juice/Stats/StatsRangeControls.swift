import SwiftUI

/// Shared range controls for the battery and Mac mini Stats dashboards.
/// Keeping the picker row and customization panel here prevents the two
/// separate dashboards from drifting in alignment or interaction behavior.
struct StatsRangePickerRow: View {
    let title: String
    @Binding var selection: EnergyRange
    let ranges: [EnergyRange]
    let pickerWidth: CGFloat
    let label: (EnergyRange) -> String

    var body: some View {
        HStack(spacing: 16) {
            Picker(title, selection: $selection) {
                ForEach(ranges, id: \.self) { range in
                    Text(label(range)).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: pickerWidth, alignment: .leading)

            Spacer(minLength: 0)
            ElectricityRateControl()
        }
    }
}

struct StatsRangeCustomizationButton: View {
    @Binding var isCustomizing: Bool

    var body: some View {
        Button {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) {
                isCustomizing.toggle()
            }
        } label: {
            Label(
                isCustomizing ? "Done" : "Customize Tabs",
                systemImage: isCustomizing ? "checkmark" : "slider.horizontal.3")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(isCustomizing ? "Finish customizing tabs" : "Choose which tabs appear")
    }
}

struct StatsRangeSettings: View {
    let availableRanges: [EnergyRange]
    let fallbackRanges: [EnergyRange]
    @Binding var selection: EnergyRange
    @Binding var storageValue: String

    private var visibleRanges: [EnergyRange] {
        StatsRangeVisibility.visibleRanges(
            from: storageValue,
            availableRanges: availableRanges,
            fallbackRanges: fallbackRanges)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Visible tabs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show All") {
                    storageValue = StatsRangeVisibility.storageValue(for: availableRanges)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .disabled(visibleRanges.count == availableRanges.count)
            }

            HStack(spacing: 14) {
                ForEach(availableRanges, id: \.self) { candidate in
                    Toggle(
                        candidate.rawValue,
                        isOn: visibilityBinding(for: candidate))
                    .toggleStyle(.checkbox)
                    .disabled(
                        visibleRanges.count == 1
                            && visibleRanges.contains(candidate))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func visibilityBinding(for candidate: EnergyRange) -> Binding<Bool> {
        Binding(
            get: { visibleRanges.contains(candidate) },
            set: { isVisible in
                let updated = StatsRangeVisibility.updating(
                    candidate,
                    isVisible: isVisible,
                    in: storageValue,
                    availableRanges: availableRanges,
                    fallbackRanges: fallbackRanges)
                storageValue = updated
                selection = StatsRangeVisibility.preferredRange(
                    selection,
                    from: updated,
                    availableRanges: availableRanges,
                    fallbackRanges: fallbackRanges)
            })
    }
}
