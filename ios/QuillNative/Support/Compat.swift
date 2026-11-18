import SwiftUI

/// Newer system behaviours, applied where the OS has them and skipped where it does not.
extension View {
    /// Marks the view a presented composer zooms out of.
    @ViewBuilder func zoomSource(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }

    /// Presents with the system zoom from a matching `zoomSource`.
    @ViewBuilder func zoomTransition(from id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }

    /// Liquid Glass for a floating control group; a system material before iOS 26.
    @ViewBuilder func floatingBar() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.bar, in: Capsule()).overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
        }
    }

    /// The prominent action style: tinted glass on iOS 26 and later.
    @ViewBuilder func prominentAction() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// The secondary action beside a prominent one: clear glass on iOS 26 and later.
    @ViewBuilder func secondaryAction() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }
}

/// A brief horizontal shake for a rejected input.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 4), y: 0))
    }
}
