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
        }
        .frame(width: size.width + model.topRadius * 2, height: size.height)
        .clipShape(shape)
        .background {
            // Sized to fit the panel window's 10–12 pt margin; only drawn while open.
            if isOpen {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
            }
        }
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
                    removal: .opacity.animation(.easeIn(duration: 0.1))
                ))
        } else if let activity = model.activity {
            CompactActivityView(activity: activity)
                .transition(.opacity.animation(.easeOut(duration: 0.2)))
        }
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
