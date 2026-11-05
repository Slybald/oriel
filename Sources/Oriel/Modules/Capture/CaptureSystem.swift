import CoreAudio
import CoreMediaIO
import Foundation

/// Source réelle : écouteurs de propriétés Core Audio (micros) et Core Media I/O (caméras), pilotés par événements.
///
/// - Lire « en marche quelque part » ne demande ni l'autorisation Micro ni Caméra et n'ouvre aucun flux : Oriel
///   n'enregistre rien et n'enverra jamais de demande d'autorisation pour cette fonction. Aucune clé dans `Info.plist`.
/// - Aucun sondage : un écouteur sur la liste des appareils (branchement) et un par appareil (« en marche »).
///   `stop()` les retire tous ; arrêtée, la source ne coûte rien.
/// - Non essayé sur un vrai Mac ici (aucun micro ni caméra allumés pour tester) : voir le rapport de la PR.
final class SystemCaptureSource: CaptureSource {
    private let microphones = AudioMicrophoneWatcher()
    private let cameras = CameraWatcher()
    private var onChange: (([CaptureDevice]) -> Void)?

    func start(_ onChange: @escaping ([CaptureDevice]) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        let publish: () -> Void = { [weak self] in
            guard let self, let onChange = self.onChange else { return }
            onChange(self.microphones.devices + self.cameras.devices)
        }
        microphones.start(publish)
        cameras.start(publish)
    }

    func stop() {
        microphones.stop()
        cameras.stop()
        onChange = nil
    }
}

// MARK: - Micros (Core Audio)

private final class AudioMicrophoneWatcher {
    private(set) var devices: [CaptureDevice] = []
    private var changed: (() -> Void)?
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func start(_ changed: @escaping () -> Void) {
        self.changed = changed
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
        systemBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        rescan()
    }

    func stop() {
        if let systemBlock {
            var address = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemBlock)
        }
        systemBlock = nil
        for (id, block) in deviceBlocks { removeListener(id, block) }
        deviceBlocks = [:]
        devices = []
        changed = nil
    }

    private func removeListener(_ id: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
    }

    /// La liste des appareils a changé (ou premier tour) : écouteurs recalés, état relu.
    private func rescan() {
        guard changed != nil else { return }
        let ids = Self.microphoneIDs()
        let diff = CaptureRules.listenerChanges(current: Set(deviceBlocks.keys.map(String.init)), wanted: Set(ids.map(String.init)))
        for key in diff.remove {
            guard let id = AudioObjectID(key), let block = deviceBlocks.removeValue(forKey: id) else { continue }
            removeListener(id, block)
        }
        for key in diff.add {
            guard let id = AudioObjectID(key) else { continue }
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            deviceBlocks[id] = block
            AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
        }
        refresh()
    }

    private func refresh() {
        guard let changed else { return }
        let next = deviceBlocks.keys.map { id in
            CaptureDevice(id: "mic-\(id)", name: Self.name(id), kind: .microphone, isRunning: Self.isRunning(id))
        }
        if next != devices {
            devices = next
            changed()
        }
    }

    private static func microphoneIDs() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter {
            CaptureRules.countsAsMicrophone(inputStreams: streamCount($0, scope: kAudioObjectPropertyScopeInput),
                                            outputStreams: streamCount($0, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    private static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func isRunning(_ id: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func name(_ id: AudioObjectID) -> String {
        var address = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }
}

// MARK: - Caméras (Core Media I/O)

private final class CameraWatcher {
    private(set) var devices: [CaptureDevice] = []
    private var changed: (() -> Void)?
    private var systemBlock: CMIOObjectPropertyListenerBlock?
    private var deviceBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    func start(_ changed: @escaping () -> Void) {
        self.changed = changed
        var address = Self.address(Int(kCMIOHardwarePropertyDevices))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
        systemBlock = block
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, .main, block)
        rescan()
    }

    func stop() {
        if let systemBlock {
            var address = Self.address(Int(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, .main, systemBlock)
        }
        systemBlock = nil
        for (id, block) in deviceBlocks { removeListener(id, block) }
        deviceBlocks = [:]
        devices = []
        changed = nil
    }

    private func removeListener(_ id: CMIOObjectID, _ block: @escaping CMIOObjectPropertyListenerBlock) {
        var address = Self.address(Int(kCMIODevicePropertyDeviceIsRunningSomewhere))
        CMIOObjectRemovePropertyListenerBlock(id, &address, .main, block)
    }

    private func rescan() {
        guard changed != nil else { return }
        let ids = Self.cameraIDs()
        let diff = CaptureRules.listenerChanges(current: Set(deviceBlocks.keys.map(String.init)), wanted: Set(ids.map(String.init)))
        for key in diff.remove {
            guard let id = CMIOObjectID(key), let block = deviceBlocks.removeValue(forKey: id) else { continue }
            removeListener(id, block)
        }
        for key in diff.add {
            guard let id = CMIOObjectID(key) else { continue }
            var address = Self.address(Int(kCMIODevicePropertyDeviceIsRunningSomewhere))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            deviceBlocks[id] = block
            CMIOObjectAddPropertyListenerBlock(id, &address, .main, block)
        }
        refresh()
    }

    private func refresh() {
        guard let changed else { return }
        let next = deviceBlocks.keys.map { id in
            CaptureDevice(id: "cam-\(id)", name: Self.name(id), kind: .camera, isRunning: Self.isRunning(id))
        }
        if next != devices {
            devices = next
            changed()
        }
    }

    private static func cameraIDs() -> [CMIOObjectID] {
        var address = Self.address(Int(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunning(_ id: CMIOObjectID) -> Bool {
        var address = Self.address(Int(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
            && value != 0
    }

    private static func name(_ id: CMIOObjectID) -> String {
        var address = Self.address(Int(kCMIOObjectPropertyName))
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(id, &address, 0, nil, size, &used, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }
}
