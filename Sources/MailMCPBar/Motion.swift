import SwiftUI

// One motion style for the panel: a critically damped spring (no overshoot; nothing here is flicked),
// started from wherever the view is, so a change that lands mid-animation redirects it instead of jumping.
// With Reduce Motion on, things change in place without moving.

enum Motion {
    static let standard = Animation.spring(duration: 0.3, bounce: 0)
}

extension View {
    /// Animates layout changes in this subtree when `value` changes; instant with Reduce Motion.
    func animatesChanges(of value: some Equatable) -> some View {
        modifier(AnimatesChanges(value: value))
    }

    /// Never animates this subtree, even inside an animated change. For the approval block: a view
    /// that fades out stays on screen for a moment, and its Send button (the default action) with it.
    func neverAnimated() -> some View {
        transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct AnimatesChanges<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Motion.standard, value: value)
    }
}

/// A plain button that dims the moment it is pressed, not when it is released.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}
