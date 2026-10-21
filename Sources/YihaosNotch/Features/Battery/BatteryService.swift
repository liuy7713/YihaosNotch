import Foundation
import IOKit.ps

/// Reads the internal battery via IOKit power-source notifications (event-driven,
/// nothing polls).
@MainActor
@Observable
final class BatteryService {
    private(set) var level = 100
    private(set) var isCharging = false
    private(set) var isPluggedIn = false

    /// Called when the charger is connected or the battery crosses a low threshold.
    @ObservationIgnored var onPowerEvent: ((LiveActivity) -> Void)?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var hasReading = false
    @ObservationIgnored private var followUpTask: Task<Void, Never>?

    private let lowThresholds = [20, 10]

    isolated deinit {
        // The run-loop source holds an unretained pointer to self; remove it first.
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    func start() {
        update()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.update() }
        }, context)?.takeRetainedValue() else { return }
        // Common modes, so updates aren't held back while scrolling or scrubbing.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    private func update() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : 0
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false

            if hasReading, pluggedIn != isPluggedIn {
                scheduleFollowUpReads()
            }
            if hasReading {
                if pluggedIn && !isPluggedIn {
                    onPowerEvent?(.charging(level: newLevel))
                } else if !pluggedIn, lowThresholds.contains(where: { newLevel <= $0 && level > $0 }) {
                    onPowerEvent?(.lowBattery(level: newLevel))
                }
            }
            hasReading = true
            if level != newLevel { level = newLevel }
            if isPluggedIn != pluggedIn { isPluggedIn = pluggedIn }
            if isCharging != charging { isCharging = charging }
            return
        }
    }

    /// Right after the charger is connected macOS reports "AC power, not charging",
    /// and no notification fires when charging actually begins a moment later.
    /// Re-read a few times so the charging state catches up.
    private func scheduleFollowUpReads() {
        followUpTask?.cancel()
        followUpTask = Task { [weak self] in
            for delay in [1.5, 4.0, 10.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.update()
            }
        }
    }
}
