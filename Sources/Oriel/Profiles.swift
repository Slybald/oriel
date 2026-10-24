import Foundation

// Profils : plusieurs façons de partir avec la notch (développeur, étudiant…) dans UNE seule app, donc une seule
// mise à jour et une seule signature. Un profil est un point de départ : il règle les
// onglets, leur ordre, l'ouverture et les oreilles, puis tout reste modifiable. Logique pure : ni fenêtre ni accès
// au Mac, ni donnée d'un onglet, hooks, apparence ou raccourci.

enum NotchProfile: String, CaseIterable, Identifiable {
    case developer
    case student
    case creative
    case minimal

    var id: String { rawValue }

    /// Identifiant de l'onglet Codex (`CodexModule`) ; un profil ignore ce que l'app n'a pas.
    static let codexId = ModuleRegistry.codexId
    /// Onglets d'assistant : proposés seulement si l'outil est sur le Mac, ou si l'onglet est déjà activé.
    static let agentTabs: Set<String> = [ModuleRegistry.claudeId, codexId]

    /// Onglets du profil, dans l'ordre. Ajouter un onglet à un profil = une ligne ici, même avant que le module existe.
    var tabs: [String] {
        switch self {
        case .developer: return [ModuleRegistry.claudeId, Self.codexId, "clipboard", "timer", "notes"]
        case .student: return ["agenda", "media", "timer", "notes", "quicksettings"]
        case .creative: return ["media", "shelf", "clipboard"]
        case .minimal: return ["media", "quicksettings"]
        }
    }

    /// Le panneau s'ouvre au survol, ou au clic pour qui ne veut pas l'ouvrir sans le vouloir.
    var openTrigger: OpenTrigger {
        switch self {
        case .developer, .creative: return .hover
        case .student, .minimal: return .click
        }
    }

    /// Oreilles de la notch repliée ; « minimal » garde une notch qui ressemble à la vraie.
    var showEars: Bool { self != .minimal }

    var title: String {
        switch self {
        case .developer: return L("Développeur", table: "Profiles")
        case .student: return L("Étudiant", table: "Profiles")
        case .creative: return L("Créatif", table: "Profiles")
        case .minimal: return L("Minimal", table: "Profiles")
        }
    }

    var symbol: String {
        switch self {
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .student: return "graduationcap"
        case .creative: return "paintbrush"
        case .minimal: return "leaf"
        }
    }

    /// Ceux des onglets du profil qui sont proposés, dans l'ordre du profil. Jamais vide si `offered` ne l'est pas : la
    /// barre n'est jamais vide (un profil sans aucun onglet présent garde le premier proposé).
    func shown(offered: [String]) -> [String] {
        let wanted = tabs.filter(offered.contains)
        return wanted.isEmpty ? Array(offered.prefix(1)) : wanted
    }

    /// Les onglets du profil d'abord, dans son ordre, puis les autres comme ils sont.
    func arrange(_ ids: [String]) -> [String] {
        tabs.filter(ids.contains) + ids.filter { !tabs.contains($0) }
    }

    /// Onglets qu'un profil peut activer : tous, sauf Claude et Codex absents du Mac (`detected`) et pas déjà activés.
    static func offered(order: [String], detected: Set<String>, isEnabled: (String) -> Bool) -> [String] {
        order.filter { !agentTabs.contains($0) || detected.contains($0) || isEnabled($0) }
    }

    /// Assistants trouvés sur ce Mac (lu quand la feuille de changement de profil s'ouvre, jamais en arrière-plan).
    /// Jamais réel sous XCTest (les deux détections le garantissent).
    static func agentsOnThisMac() -> Set<String> {
        var found: Set<String> = []
        if HookInstaller.claudeCodeOnThisMac { found.insert(ModuleRegistry.claudeId) }
        if CodexHookInstaller.codexOnThisMac { found.insert(codexId) }
        return found
    }

    /// Le profil dont les onglets sont ceux qui sont activés (l'ordre ne compte pas), sinon nil : « Personnalisé ».
    /// Claude, Codex et les onglets que l'app n'a pas (`known`) peuvent manquer : un profil les propose, il ne les impose pas.
    static func matching(enabled: [String], known: [String]) -> NotchProfile? {
        let on = Set(enabled)
        guard !on.isEmpty else { return nil }
        return allCases.first { profile in
            on.isSubset(of: profile.tabs)
                && profile.tabs.allSatisfy { on.contains($0) || agentTabs.contains($0) || !known.contains($0) }
        }
    }
}

/// Ce qu'un profil change, calculé sans rien écrire (aperçu avant confirmation) puis appliqué.
struct ProfilePlan: Equatable {
    let profile: NotchProfile
    /// Onglets affichés, dans l'ordre du profil.
    let shown: [String]
    /// Onglets proposés que le profil ne garde pas : masqués, pas supprimés.
    let hidden: [String]
    /// Ordre complet des réglages après application.
    let order: [String]

    /// `current` : tous les onglets dans l'ordre des réglages ; `offered` : ceux que le profil peut activer.
    init(_ profile: NotchProfile, current: [String], offered: [String]) {
        let shown = profile.shown(offered: offered)
        self.profile = profile
        self.shown = shown
        hidden = offered.filter { !shown.contains($0) }
        order = Self.order(shown: shown, current: current)
    }

    /// Les onglets affichés d'abord, puis les masqués dans leur ordre actuel.
    static func order(shown: [String], current: [String]) -> [String] {
        shown + current.filter { !shown.contains($0) }
    }

    /// Onglets aujourd'hui activés que le profil masque.
    func newlyHidden(enabled: [String]) -> [String] {
        hidden.filter(enabled.contains)
    }

    /// Écrit onglets (par le registre, comme Réglages › Onglets), ordre, ouverture et oreilles : rien d'autre.
    func apply(to registry: ModuleRegistry, prefs: Preferences) {
        for id in shown { registry.setEnabled(id, true) }
        for id in hidden { registry.setEnabled(id, false) }
        prefs.tabOrder = order
        prefs.openTrigger = profile.openTrigger
        prefs.showEars = profile.showEars
    }
}
