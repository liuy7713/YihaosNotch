import CoreGraphics
import Foundation

/// Built-in display brightness. There's no public API for it, so this uses the
/// private DisplayServices framework (as MonitorControl and others do). If the symbols
/// ever disappear, `isAvailable` turns false and the brightness keys are left to macOS.
enum DisplayBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    nonisolated(unsafe) private static let framework =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Getter? =
        framework.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter: Setter? =
        framework.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    static var isAvailable: Bool { getter != nil && setter != nil && builtInDisplay != nil }

    static var level: Float? {
        guard let getter, let display = builtInDisplay else { return nil }
        var value = Float(0)
        return getter(display, &value) == 0 ? value : nil
    }

    static func setLevel(_ level: Float) {
        guard let setter, let display = builtInDisplay else { return }
        _ = setter(display, min(max(level, 0), 1))
    }

    private static var builtInDisplay: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count = UInt32(0)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
