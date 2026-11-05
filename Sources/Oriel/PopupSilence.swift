import AppKit
import CoreAudio
import CoreGraphics
import Intents

/// Ce qu'on fait d'un pop-up, décidé au moment où il arrive.
enum PopupDecision: Equatable {
    case show
    /// Affiché sans le contenu (ni expéditeur, ni ligne) : l'icône et le nom de l'onglet seulement.
    case redact
    case drop
}

/// Ce que l'on sait du Mac à l'arrivée d'un pop-up. Rien n'est surveillé : chaque valeur est lue à ce moment-là.
struct PopupSituation: Equatable {
    /// Un rendez-vous avec lien de visio est en cours (`AgendaPhase.running`).
    var meeting = false
    /// L'écran est dupliqué (recopie, AirPlay, Sidecar).
    var mirrored = false
    /// Un micro est utilisé : une visio est probable, avec ou sans partage d'écran (Zoom, Teams, Meet dans un navigateur).
    var microphoneBusy = false
    /// Un Concentration est actif (seulement si l'autorisation a déjà été donnée : l'app ne la demande pas).
    var focus = false
}

enum PopupSilence {
    /// Concentration : rien. Réunion, écran dupliqué ou micro ouvert : le texte reste caché. Sinon, tout s'affiche.
    /// Limite : un partage d'écran dans Zoom ou Teams n'est pas une duplication ; seul le micro ouvert le laisse deviner,
    /// et un partage sans micro (écran seul, micro coupé par l'app) n'est pas vu.
    static func decide(_ situation: PopupSituation) -> PopupDecision {
        if situation.focus { return .drop }
        return situation.meeting || situation.mirrored || situation.microphoneBusy ? .redact : .show
    }
}

extension PopupEvent {
    /// Le pop-up sans contenu : le nom de l'onglet à la place du titre, et la ligne neutre de la source si elle en a une
    /// (« Nouveau message »). Les textes que l'app écrit elle-même (« Terminé », « Dans 5 min ») restent.
    func redacted(title: String) -> PopupEvent {
        var copy = self
        copy.title = title
        copy.text = redactedText ?? text
        return copy
    }
}

/// Lectures du système, sans permission, à la demande (jamais en tâche de fond).
enum PopupProbes {
    static func mirrored() -> Bool {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// Un périphérique d'entrée tourne quelque part. Ne touche pas au micro : aucune autorisation, aucun voyant.
    static func microphoneBusy() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return false }
        return devices.contains { device in
            var inputs = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                    mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputs, 0, nil, &inputSize) == noErr, inputSize > 0 else { return false }
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var state = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(device, &state, 0, nil, &runningSize, &running) == noErr && running != 0
        }
    }

    /// Lecture seule : sans autorisation déjà donnée, l'état n'est pas lu et il n'y a ni dialogue ni erreur.
    static func focus() -> Bool {
        let center = INFocusStatusCenter.default
        return center.authorizationStatus == .authorized && center.focusStatus.isFocused == true
    }
}
