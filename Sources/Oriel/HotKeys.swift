import AppKit
import Carbon.HIToolbox

/// Raccourcis globaux proposés (liste courte : pas d'enregistreur de touches à maintenir).
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case none
    case optionCommandN
    case controlOptionSpace
    case controlCommandN
    case optionCommandJ
    case optionCommandK
    /// Réservées à « Approuver au clavier » (touches fixes, pas dans les listes de choix).
    case controlOptionY
    case controlOptionN

    var id: String { rawValue }

    /// Les choix offerts dans les réglages.
    static let pickable: [HotKeyChoice] = allCases.filter { $0 != .controlOptionY && $0 != .controlOptionN }

    /// Code de touche virtuel et modificateurs au format Carbon ; nil pour `none`.
    var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .none: return nil
        case .optionCommandN: return (UInt32(kVK_ANSI_N), UInt32(optionKey | cmdKey))
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlCommandN: return (UInt32(kVK_ANSI_N), UInt32(controlKey | cmdKey))
        case .optionCommandJ: return (UInt32(kVK_ANSI_J), UInt32(optionKey | cmdKey))
        case .optionCommandK: return (UInt32(kVK_ANSI_K), UInt32(optionKey | cmdKey))
        case .controlOptionY: return (UInt32(kVK_ANSI_Y), UInt32(controlKey | optionKey))
        case .controlOptionN: return (UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey))
        }
    }

    var title: String {
        switch self {
        case .none: return L("Aucun")
        case .optionCommandN: return "⌥⌘N"
        case .controlOptionSpace: return L("⌃⌥Espace")
        case .controlCommandN: return "⌃⌘N"
        case .optionCommandJ: return "⌥⌘J"
        case .optionCommandK: return "⌥⌘K"
        case .controlOptionY: return "⌃⌥Y"
        case .controlOptionN: return "⌃⌥N"
        }
    }
}

/// Ce que `ApprovalQueue` demande au centre de raccourcis (remplaçable dans les tests).
protocol HotKeyRegistering: AnyObject {
    @discardableResult
    func set(_ choice: HotKeyChoice, for slot: HotKeyCenter.Slot, action: @escaping () -> Void) -> Bool
}

/// Raccourcis globaux par `RegisterEventHotKey` (Carbon) : aucune autorisation d'accessibilité, la touche est
/// réservée à l'app tant qu'elle est enregistrée. Une case (`Slot`) par action.
final class HotKeyCenter: ObservableObject, HotKeyRegistering {
    enum Slot: UInt32 {
        case togglePanel = 1
        case toggleHidden = 2
        case commandBar = 10
        /// Enregistrées seulement pendant une demande à régler (`ApprovalQueue`).
        case approve = 3
        case deny = 4
    }

    static let shared = HotKeyCenter()
    /// « CNOT » : signature des identifiants de nos raccourcis.
    private static let signature: OSType = 0x434E_4F54

    /// Cases dont la combinaison est refusée par macOS (déjà prise par une autre app).
    @Published private(set) var unavailable: Set<Slot> = []

    private var refs: [Slot: EventHotKeyRef] = [:]
    private var actions: [Slot: () -> Void] = [:]
    private var handler: EventHandlerRef?

    /// Remplace le raccourci de `slot` (`none` le retire). Faux si macOS refuse la combinaison.
    @discardableResult
    func set(_ choice: HotKeyChoice, for slot: Slot, action: @escaping () -> Void) -> Bool {
        if let ref = refs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
        actions[slot] = nil
        unavailable.remove(slot)
        guard let carbon = choice.carbon else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(carbon.keyCode, carbon.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: slot.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            unavailable.insert(slot)
            return false
        }
        refs[slot] = ref
        actions[slot] = action
        return true
    }

    /// Un seul gestionnaire pour toutes les cases ; il ne capture rien (pointeur de fonction C).
    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyCenter.signature,
                  let slot = HotKeyCenter.Slot(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotKeyCenter.shared.actions[slot]?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}

/// Touches du panneau ouvert au clavier (raccourci global) : ← → et ⌘1…⌘9 changent d'onglet, Échap ferme.
/// Codes de touche physiques : ⌘1 marche aussi en AZERTY (touche « & 1 »).
enum NotchKeyCommand: Equatable {
    case close
    case previousTab
    case nextTab
    /// Onglet n (0 = le premier).
    case tab(Int)

    private static let digitKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5),
        UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
    ]

    /// `editingText` : un champ de texte a le clavier ; Échap et les flèches lui reviennent.
    static func parse(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, editingText: Bool) -> NotchKeyCommand? {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if flags == .command, let index = digitKeyCodes.firstIndex(of: keyCode) { return .tab(index) }
        guard flags.isEmpty, !editingText else { return nil }
        switch Int(keyCode) {
        case kVK_Escape: return .close
        case kVK_LeftArrow: return .previousTab
        case kVK_RightArrow: return .nextTab
        default: return nil
        }
    }

    /// Onglet visé parmi `count` onglets, en partant de `current` (les flèches bouclent).
    func target(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        switch self {
        case .close: return nil
        case .previousTab: return (current - 1 + count) % count
        case .nextTab: return (current + 1) % count
        case .tab(let index): return index < count ? index : nil
        }
    }
}
