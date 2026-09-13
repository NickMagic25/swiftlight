import SwiftUI

struct StreamStatisticRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}

/// A passive panel. Its parent owns visibility and alignment inside the video
/// surface's safe area; this view never changes stream settings or captures input.
struct StreamStatisticsOverlay: View {
    let rows: [StreamStatisticRow]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        styledPanel
            .accessibilityElement(children: .contain)
            .allowsHitTesting(false)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stream Statistics")
                .font(.caption.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 5) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                        Spacer(minLength: 20)
                        Text(row.value)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(row.label))
                    .accessibilityValue(Text(row.value))
                }
            }
            .font(.caption)
            // Keep a shared label/value column and a single baseline per metric.
            // Compact windows can scale text instead of moving values below labels.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            if rows.isEmpty {
                Text("Waiting for statistics…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(12)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 720 : 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var styledPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if reduceTransparency {
            panel.background(.background, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.2), lineWidth: 1))
        } else if #available(macOS 26, iOS 26, tvOS 26, *) {
            // One regular Liquid Glass surface preserves legibility over moving
            // video. No interactive/morphing effects are needed for passive stats.
            panel.glassEffect(.regular, in: shape)
        } else {
            panel.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.12), lineWidth: 1))
        }
    }
}
