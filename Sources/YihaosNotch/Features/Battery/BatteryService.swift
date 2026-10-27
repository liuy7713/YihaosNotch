import Foundation
import IOKit
import IOKit.ps

enum PowerState: Equatable {
    case battery, charging, charged
    /// On power but not charging: holding at the optimised or set charge limit, or a
    /// charger too weak to do more than run the Mac.
    case pluggedIn
}

/// Reads the internal battery via IOKit power-source notifications (event-driven). The
/// one thing that polls is the live input power, and only while something on screen
/// shows it and the charger is connected.
@MainActor
@Observable
final class BatteryService {
    private(set) var level = 100
    private(set) var isCharging = false
    private(set) var isPluggedIn = false
    private(set) var isCharged = false
    /// The connected charger's rating, as macOS reports it (e.g. 65 for a 65 W charger).
    private(set) var adapterWatts: Int?
    /// Power coming in from the charger right now, smoothed. Nil when unknown, or while
    /// nothing is watching (see `beginLiveReadings`).
    private(set) var inputWatts: Double?

    var powerState: PowerState {
        guard isPluggedIn else { return .battery }
        if isCharging { return .charging }
        return isCharged ? .charged : .pluggedIn
    }

    /// Called when the charger is connected or the battery crosses a low threshold.
    @ObservationIgnored var onPowerEvent: ((LiveActivity) -> Void)?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var hasReading = false
    @ObservationIgnored private var followUpTask: Task<Void, Never>?
    @ObservationIgnored private var liveReaders = 0
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var recentInput: [Double] = []
    /// When the charger was last disconnected. A plug-in only shows if the Mac was on
    /// battery for a while first: a loose cable or tired charger can drop out and come
    /// back every few seconds, and that shouldn't flash the notch each time.
    @ObservationIgnored private var unpluggedAt = Date.distantPast
    private let reconnectQuietPeriod: TimeInterval = 5

    private let lowThresholds = [20, 10]

    isolated deinit {
        // The run-loop source holds an unretained pointer to self; remove it first.
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    /// Call once; a second call would add a second run-loop source.
    func start() {
        guard runLoopSource == nil else { return }
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
            let charged = description[kIOPSIsChargedKey] as? Bool ?? false

            if hasReading, pluggedIn != isPluggedIn {
                scheduleFollowUpReads()
            }
            if hasReading {
                if !pluggedIn && isPluggedIn { unpluggedAt = .now }
                if pluggedIn && !isPluggedIn, Date.now.timeIntervalSince(unpluggedAt) >= reconnectQuietPeriod {
                    onPowerEvent?(.charging(level: newLevel))
                } else if !pluggedIn, lowThresholds.contains(where: { newLevel <= $0 && level > $0 }) {
                    onPowerEvent?(.lowBattery(level: newLevel))
                }
            }
            hasReading = true
            if level != newLevel { level = newLevel }
            if isPluggedIn != pluggedIn { isPluggedIn = pluggedIn }
            if isCharging != charging { isCharging = charging }
            if isCharged != charged { isCharged = charged }
            // The charger's details can be missing for a moment while it's connected
            // (most often just after it connects), so the last rating is kept until
            // it's unplugged.
            let watts = pluggedIn ? (Self.readAdapterWatts() ?? adapterWatts) : nil
            if adapterWatts != watts { adapterWatts = watts }
            updateLiveReadings()
            return
        }
    }

    private static func readAdapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0
        else { return nil }
        return watts
    }

    // MARK: Live input power

    /// Views showing `inputWatts` call this when they appear and `endLiveReadings` when
    /// they go; readings run every 2 s while at least one is showing and the charger is in.
    func beginLiveReadings() {
        liveReaders += 1
        updateLiveReadings()
    }

    func endLiveReadings() {
        liveReaders = max(0, liveReaders - 1)
        updateLiveReadings()
    }

    private func updateLiveReadings() {
        let wanted = liveReaders > 0 && isPluggedIn
        if wanted, liveTask == nil {
            liveTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.readInputPower()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } else if !wanted, let task = liveTask {
            task.cancel()
            liveTask = nil
            recentInput.removeAll()
            if inputWatts != nil { inputWatts = nil }
        }
    }

    /// The battery controller's "system power in" (milliwatts). It isn't public API: if
    /// it's missing or zero (as for a moment while a charger negotiates), the reading
    /// is simply unknown and views fall back to the charger's rating.
    private func readInputPower() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }
        let telemetry = IORegistryEntryCreateCFProperty(service, "PowerTelemetryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        guard let milliwatts = telemetry?["SystemPowerIn"] as? Int, milliwatts > 500, milliwatts < 400_000 else {
            recentInput.removeAll()
            if inputWatts != nil { inputWatts = nil }
            return
        }
        // Averaged over the last three readings, so the number doesn't flicker.
        recentInput = Array((recentInput + [Double(milliwatts) / 1000]).suffix(3))
        let average = recentInput.reduce(0, +) / Double(recentInput.count)
        if inputWatts.map({ abs($0 - average) >= 0.5 }) ?? true { inputWatts = average }
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
