import SwiftUI

// Liquid Glass on macOS 26+, with material fallbacks so the app also builds
// with older SDKs (Swift < 6.2) and runs on macOS 14–15.

extension View {
    /// A glass panel (tinted when `tint` is given).
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? .regular
            self.glassEffect(interactive ? glass.interactive() : glass, in: .rect(cornerRadius: cornerRadius))
        } else {
            materialCard(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        materialCard(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    private func materialCard(cornerRadius: CGFloat, tint: Color?) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill((tint ?? .clear).opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(0.12)))
        }
    }

    /// Glass button style (prominent = tinted glass for the primary action).
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}

/// Groups glass shapes so they blend and morph together on macOS 26+.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A small coloured status dot with a soft glow.
struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color.gradient).frame(width: 8, height: 8).shadow(color: color.opacity(0.6), radius: 3)
    }
}
