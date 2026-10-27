import Foundation
import IOKit
import IOKit.hid

/// Whether a keyboard other than the built-in one is connected (a Magic Keyboard, say),
/// so the tap that catches external keyboards' brightness keys (see `BrightnessKeyTap`)
/// only runs while there's one to catch.
///
/// Reads the I/O Registry, which needs no permission (opening the devices themselves
/// would ask for Input Monitoring). Anything that presents itself as a keyboard counts,
/// including some mouse receivers: when unsure, the tap runs.
@MainActor
final class ExternalKeyboards {
    private(set) var isConnected = false
    var onChange: ((Bool) -> Void)?

    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var recheck: Task<Void, Never>?

    isolated deinit {
        stop()
    }

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, Self.matching(), { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<ExternalKeyboards>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    ExternalKeyboards.drain(iterator)
                    watcher.scheduleRecount()
                }
            }, context, &iterator)
            guard result == KERN_SUCCESS else { continue }
            // Emptying the iterator arms the notification.
            Self.drain(iterator)
            iterators.append(iterator)
        }
        recount()
    }

    func stop() {
        recheck?.cancel()
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    /// A keyboard that's just gone can linger in the registry for a moment, so count
    /// again once things have settled.
    private func scheduleRecount() {
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.recount()
        }
    }

    private func recount() {
        let connected = Self.externalKeyboardConnected()
        guard connected != isConnected else { return }
        isConnected = connected
        onChange?(connected)
    }

    private static func matching() -> NSMutableDictionary {
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
        return matching
    }

    /// True if the registry can't be read, so the tap errs on the side of running.
    private static func externalKeyboardConnected() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &iterator) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            let builtIn = IORegistryEntryCreateCFProperty(service, kIOHIDBuiltInKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool
            IOObjectRelease(service)
            if builtIn != true { found = true }
        }
        return found
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
