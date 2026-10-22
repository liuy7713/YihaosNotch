import CoreAudio
import AudioToolbox
import Foundation

/// The default audio output device: volume, mute, name and transport type.
enum AudioOutput {
    static var defaultDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                  scope: kAudioObjectPropertyScopeGlobal, into: &device),
              device != 0
        else { return nil }
        return device
    }

    /// 0...1, or nil for devices without a software volume (e.g. some HDMI outputs).
    static func volume(of device: AudioDeviceID) -> Float? {
        var value = Float32(0)
        return get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, into: &value) ? value : nil
    }

    static func canSetVolume(of device: AudioDeviceID) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func setVolume(_ volume: Float, of device: AudioDeviceID) {
        var value = Float32(min(max(volume, 0), 1))
        set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &value)
    }

    static func canSetMute(of device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var value = UInt32(0)
        return get(device, kAudioDevicePropertyMute, into: &value) && value != 0
    }

    static func setMuted(_ muted: Bool, of device: AudioDeviceID) {
        var value = UInt32(muted ? 1 : 0)
        set(device, kAudioDevicePropertyMute, &value)
    }

    static func name(of device: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var address = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        guard get(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, into: &transport)
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: Plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
                               into value: inout T) -> Bool {
        var address = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) {
        var address = address(selector, kAudioDevicePropertyScopeOutput)
        let size = UInt32(MemoryLayout<T>.size)
        AudioObjectSetPropertyData(object, &address, 0, nil, size, &value)
    }
}

/// Reports when audio output switches to Bluetooth headphones (AirPods, Beats…).
/// Uses only CoreAudio's default-device notification: no Bluetooth permission needed.
@MainActor
final class HeadphoneMonitor {
    var onConnect: ((_ name: String, _ symbol: String) -> Void)?
    private var lastDevice: AudioDeviceID?

    func start() {
        lastDevice = AudioOutput.defaultDevice
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
            MainActor.assumeIsolated { self.outputChanged() }
        }
    }

    private func outputChanged() {
        guard let device = AudioOutput.defaultDevice, device != lastDevice else { return }
        lastDevice = device
        guard AudioOutput.isBluetooth(device), let name = AudioOutput.name(of: device) else { return }
        onConnect?(Self.displayName(for: name), Self.symbol(for: name))
    }

    /// macOS names devices after their owner ("Yihao's AirPods Pro"); the icon already
    /// says whose they are, so show just the model.
    static func displayName(for name: String) -> String {
        let stripped = name.replacing(/^.+?['’]s\s+/, with: "")
        return stripped.isEmpty ? name : stripped
    }

    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
}
