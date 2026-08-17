import CoreAudio
import Foundation

final class AudioOutputMonitor {
    var onRouteChange: ((AudioOutputRoute) -> Void)?

    private let listenerQueue = DispatchQueue(label: "com.chaitanya.edgebeat.audio-output")
    private var isListening = false

    func start() {
        guard !isListening else { return }
        isListening = true
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listenerBlock
        )
        publishCurrentRoute()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listenerBlock
        )
    }

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.publishCurrentRoute()
    }

    private func publishCurrentRoute() {
        let route = Self.currentRoute()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isListening else { return }
            self.onRouteChange?(route)
        }
    }

    private static func currentRoute() -> AudioOutputRoute {
        var address = defaultOutputAddress
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return .builtIn
        }

        let name = deviceName(deviceID) ?? "Audio Output"
        let normalized = name.lowercased()
        let kind: AudioOutputKind
        if normalized.contains("airpods max") {
            kind = .headphones
        } else if normalized.contains("airpod") || normalized.contains("earbud")
            || normalized.contains("buds") || normalized.contains("beats fit") {
            kind = .earbuds
        } else if normalized.contains("headphone") || normalized.contains("headset")
                    || normalized.contains("beats") {
            kind = .headphones
        } else if normalized.contains("macbook") || normalized.contains("built-in")
                    || normalized.contains("imac") || normalized.contains("studio display") {
            kind = .mac
        } else {
            kind = .speaker
        }
        return AudioOutputRoute(name: name, kind: kind)
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
