import SwiftUI

/// The black shape that morphs between the hardware notch, a live activity, and the
/// open panel. Everything else is drawn inside it.
struct NotchRootView: View {
    @Environment(NotchViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size = model.shapeSize
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius)
        let isOpen = model.state == .open

        ZStack(alignment: .top) {
            Color.black
            content
                .padding(.horizontal, model.topRadius)
                // Without this, a view leaving the ZStack drops behind Color.black for
                // its removal transition and appears to vanish on the first frame.
                .zIndex(1)
        }
        .frame(width: size.width + model.topRadius * 2, height: size.height)
        .clipShape(shape)
        // Always present, with only its opacity animated, so the shadow tracks the
        // morphing shape. (Inserting or removing it with a transition freezes the removed
        // copy at its old size, which shows as a large grey rectangle mid-animation.)
        // Sized to fit the panel window's 10–12 pt margin.
        .background(
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 7, y: 4)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(stateAnimation, value: model.state)
        .animation(Theme.close, value: model.activity?.kind)
    }

    @ViewBuilder
    private var content: some View {
        if model.state == .open {
            OpenPanelView()
                .frame(width: model.openSize.width, height: model.openSize.height)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                        .animation(.easeOut(duration: 0.22).delay(0.06)),
                    removal: panelRemoval
                ))
        } else if let activity = model.activity {
            CompactActivityView(activity: activity)
                // Waits until the shape has mostly shrunk back, so the wings fade in
                // around the notch instead of inside a still-large panel.
                .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.22)))
        }
    }

    /// On close the content draws in towards the notch: it shrinks toward the top,
    /// softens and fades a little ahead of the shape, so the shape never shrinks around
    /// visibly clipped content.
    private var panelRemoval: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeIn(duration: 0.12)) }
        return AnyTransition.opacity
            .combined(with: .scale(scale: 0.9, anchor: .top))
            .combined(with: .modifier(active: BlurEffect(radius: 6), identity: BlurEffect(radius: 0)))
            // Ease-out: the fade starts on the very first frame, in step with the shape.
            .animation(.easeOut(duration: 0.2))
    }

    private var stateAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return switch model.state {
        case .open: Theme.open
        case .arming: Theme.nudge
        case .closed: Theme.close
        }
    }
}
