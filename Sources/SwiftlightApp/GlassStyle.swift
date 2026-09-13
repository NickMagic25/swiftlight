import SwiftUI

extension View {
    /// Apply after the surface's padding and sizing so glass follows its bounds.
    func swiftlightGlassSurface(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(SwiftlightGlassSurface(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// Native button behavior, including keyboard, focus, and accessibility states.
    func swiftlightGlassButton(prominent: Bool = false) -> some View {
        modifier(SwiftlightGlassButton(prominent: prominent))
    }

    /// A highlight above artwork; inactive cards receive no visual treatment.
    func swiftlightArtworkHighlight(active: Bool, cornerRadius: CGFloat = 12) -> some View {
        modifier(SwiftlightArtworkHighlight(active: active, cornerRadius: cornerRadius))
    }
}

private struct SwiftlightGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(.primary.opacity(0.55), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: shape)
        } else if #available(macOS 26, iOS 26, tvOS 26, *) {
            content.glassEffect(.regular.interactive(interactive && !reduceMotion), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct SwiftlightGlassButton: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, tvOS 26, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

private struct SwiftlightArtworkHighlight: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                highlight
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
                    .transaction { transaction in
                        if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
                    }
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    @ViewBuilder private var highlight: some View {
        if !reduceTransparency, #available(macOS 26, iOS 26, tvOS 26, *) {
            Color.clear
                .glassEffect(.clear.interactive(!reduceMotion), in: shape)
                .overlay { border }
        } else {
            // An opaque outline preserves the artwork when translucency is disabled
            // and provides the same selection cue on older systems.
            border
        }
    }

    private var border: some View {
        shape.strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 3 : 2)
    }
}
