import AppKit

/// Finds the MacBook's built-in display and its notch. External displays are
/// deliberately ignored.
@MainActor
enum ScreenLocator {
    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    /// Size of the hardware notch, or nil if the screen has none.
    static func notchSize(on screen: NSScreen) -> CGSize? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0
        else { return nil }
        return CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }
}
