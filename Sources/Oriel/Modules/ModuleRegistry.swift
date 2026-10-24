import Combine
import Foundation
import SwiftUI

extension ModuleRegistry {
    /// Tous les onglets, dans l'ordre par défaut. Ajouter un module = une ligne ici.
    static func standardModules(claude: ClaudeModule, codex: CodexModule = CodexModule()) -> [any NotchModule] {
        [
            claude,
            codex,
            MediaModule(),
            AgendaModule(),
            QuickSettingsModule(),
            ShelfModule(),
            ClipboardModule(),
            TimerModule(),
            NotesModule(),
            MessagesModule(),
            MailModule(),
        ]
    }
}

/// Les onglets de la notch : ordre et activation (lus dans les réglages), cycle de vie, oreilles des modules.
final class ModuleRegistry: ObservableObject {
    static let claudeId = "claude"
    static let codexId = "codex"

    /// Tous les modules connus, dans l'ordre par défaut.
    let modules: [any NotchModule]
    /// Tous les modules dans l'ordre des réglages, activés ou non (fenêtre de réglages).
    @Published private(set) var ordered: [any NotchModule] = []
    /// Modules activés, dans l'ordre des onglets.
    @Published private(set) var enabled: [any NotchModule] = []
    /// Oreilles des modules qui tournent, dans l'ordre des onglets (un intercalaire chacune, voir `EarTabs`).
    @Published private(set) var earsEntries: [ModuleEarsEntry] = []
    /// Oreilles du module de plus haute priorité (celui que montre la notch quand Claude n'est pas actif).
    var moduleEars: ModuleEars? { Self.pickEars(earsEntries.map { $0.ears }) }
    /// Modules démarrés.
    private(set) var running: Set<String> = []

    private let prefs: Preferences
    /// Intercalaires posés par les scripts de l'utilisateur (API locale), après ceux des modules.
    let external: LocalAPI
    private var panelOpen = false
    private var cancellables = Set<AnyCancellable>()

    init(modules: [any NotchModule], prefs: Preferences, external: LocalAPI = .shared) {
        precondition(Set(modules.map { $0.id }).count == modules.count, "identifiants de module en double")
        self.modules = modules
        self.prefs = prefs
        self.external = external
        refreshOrder()
        // `objectWillChange` part avant le changement : on relit au tour de boucle suivant.
        prefs.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshOrder()
                self?.reconcile()
            }
            .store(in: &cancellables)
        for module in modules {
            module.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reconcile() }
                .store(in: &cancellables)
        }
        external.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        // Au lancement, notch repliée : les modules qui tournent replié (oreilles, minuteur) démarrent tout de suite.
        reconcile()
    }

    func module(_ id: String) -> (any NotchModule)? {
        modules.first { $0.id == id }
    }

    func isEnabled(_ id: String) -> Bool {
        guard let module = module(id) else { return false }
        return prefs.tabEnabled[id] ?? module.isEnabledByDefault
    }

    func setEnabled(_ id: String, _ isOn: Bool) {
        prefs.tabEnabled[id] = isOn
    }

    /// Onglet Claude activé : sessions, hooks, processus `claude` ; désactivé, rien de Claude ne tourne ni ne s'affiche.
    var isClaudeEnabled: Bool { isEnabled(Self.claudeId) }

    /// Glisser-déposer de la fenêtre de réglages (indices dans `ordered`).
    func move(from source: IndexSet, to destination: Int) {
        var ids = ordered.map { $0.id }
        ids.move(fromOffsets: source, toOffset: destination)
        prefs.tabOrder = ids
    }

    // MARK: - Mode édition de la notch (même stockage que Réglages › Onglets)

    /// Ordre et onglets activés lus dans les réglages eux-mêmes : `ordered` et `enabled` ne sont relus qu'au tour
    /// de boucle suivant.
    private var savedOrder: [String] { Self.order(modules, by: prefs.tabOrder).map { $0.id } }
    private var enabledIds: [String] { savedOrder.filter { isEnabled($0) } }

    /// Onglets masqués, dans l'ordre des réglages (menu « + » de la notch).
    var hidden: [any NotchModule] { ordered.filter { !isEnabled($0.id) } }

    /// Glisser dans la barre : l'onglet `id` passe à la place `index` parmi les onglets affichés.
    func moveTab(_ id: String, to index: Int) {
        let order = TabEditing.move(id, to: index, order: savedOrder, enabled: enabledIds)
        if order != savedOrder { prefs.tabOrder = order }
    }

    /// « − » de la notch : masque l'onglet, sauf le dernier affiché. Son module s'arrête, comme depuis les réglages.
    @discardableResult
    func hideTab(_ id: String) -> Bool {
        guard TabEditing.canHide(id, enabled: enabledIds) else { return false }
        setEnabled(id, false)
        return true
    }

    /// « + » de la notch : remet un onglet masqué, en bout de barre (là où est le « + »).
    func showTab(_ id: String) {
        guard module(id) != nil, !isEnabled(id) else { return }
        prefs.tabOrder = savedOrder.filter { $0 != id } + [id]
        setEnabled(id, true)
    }

    /// Le panneau s'ouvre ou se ferme : démarre ou arrête les modules concernés.
    func setPanelOpen(_ open: Bool) {
        guard open != panelOpen else { return }
        panelOpen = open
        reconcile()
    }

    /// Onglet affiché à l'ouverture : Claude s'il attend l'utilisateur (les oreilles montraient la main) et qu'il est
    /// activé, sinon le dernier utilisé ou l'onglet par défaut des réglages s'il est encore activé, sinon le premier.
    func initialTab(claudeNeedsAttention: Bool) -> String {
        let ids = enabled.map { $0.id }
        if claudeNeedsAttention, ids.contains(Self.claudeId) { return Self.claudeId }
        if ids.contains(Self.codexId), (module(Self.codexId) as? CodexModule)?.needsAttention == true { return Self.codexId }
        let wanted = prefs.defaultTab == Preferences.lastTabChoice ? prefs.lastTab : prefs.defaultTab
        return ids.contains(wanted) ? wanted : (ids.first ?? Self.claudeId)
    }

    /// Démarre les modules activés et utiles, arrête les autres, puis relit les oreilles.
    func reconcile() {
        for module in modules {
            let id = module.id
            let shouldRun = isEnabled(id) && (panelOpen || module.keepsRunningWhenCollapsed)
            if shouldRun, !running.contains(id) {
                running.insert(id)
                module.start()
            } else if !shouldRun, running.contains(id) {
                running.remove(id)
                module.stop()
            }
        }
        let entries = enabled.filter { running.contains($0.id) }.compactMap { module in
            module.ears.map { ModuleEarsEntry(id: module.id, ears: $0) }
        } + external.earsEntries
        if entries != earsEntries { earsEntries = entries }
    }

    /// Titre d'un intercalaire : celui du module, ou celui que le script a donné.
    func earTitle(_ id: String) -> String {
        module(id)?.title ?? external.item(earId: id)?.title ?? id
    }

    /// Contenu d'un intercalaire déployé.
    func earDetailView(_ id: String) -> AnyView? {
        if let module = module(id) { return module.makeTabDetailView() }
        return external.item(earId: id).map { AnyView(ExternalEarDetail(ear: $0, api: external)) }
    }

    /// Intercalaires de la notch repliée, du plus prioritaire au moins prioritaire. Sans onglet Claude, Claude ne compte pas.
    func earTabs(claude indicator: NotchIndicator, claudeEars: SessionStore.EarsContent?) -> [EarTab] {
        EarTabs.tabs(claude: isClaudeEnabled ? indicator : .none, claudeEars: claudeEars, modules: earsEntries,
                     showEars: prefs.showEars)
    }

    /// Géométrie des intercalaires pour une notch de `notch` points.
    func earLayout(claude indicator: NotchIndicator, claudeEars: SessionStore.EarsContent?,
                   notch: CGSize) -> EarTabsLayout {
        EarTabsLayout(tabs: earTabs(claude: indicator, claudeEars: claudeEars), notch: notch, mode: prefs.earTabsMode)
    }

    /// Plus grande priorité ; à égalité, le premier dans l'ordre des onglets.
    static func pickEars(_ candidates: [ModuleEars]) -> ModuleEars? {
        candidates.reduce(nil) { best, next in
            guard let best else { return next }
            return next.priority > best.priority ? next : best
        }
    }

    /// Ordre des réglages : identifiants connus d'abord (sans doublon), puis les modules absents dans l'ordre
    /// par défaut (un nouveau module apparaît à la fin).
    static func order(_ modules: [any NotchModule], by saved: [String]) -> [any NotchModule] {
        var seen = Set<String>()
        var result: [any NotchModule] = []
        for id in saved where !seen.contains(id) {
            if let module = modules.first(where: { $0.id == id }) {
                result.append(module)
                seen.insert(id)
            }
        }
        result += modules.filter { !seen.contains($0.id) }
        return result
    }

    private func refreshOrder() {
        let all = Self.order(modules, by: prefs.tabOrder)
        let active = all.filter { isEnabled($0.id) }
        if all.map({ $0.id }) != ordered.map({ $0.id }) { ordered = all }
        if active.map({ $0.id }) != enabled.map({ $0.id }) { enabled = active }
    }

    var debugInfo: [String: Any] {
        var info: [String: Any] = [
            "tabs": enabled.map { $0.id },
            "running": running.sorted(),
        ]
        info["ears"] = moduleEars.map { "\($0.symbol) \($0.text)" }
        return info
    }
}

/// Mode édition des onglets dans la notch (appui long sur la barre, comme les apps sur iPhone) : règles pures.
enum TabEditing {
    /// Durée de l'appui long qui ouvre le mode.
    static let pressDuration: TimeInterval = 0.5

    /// Ordre complet des réglages quand l'onglet affiché `id` passe à la place `index` parmi les onglets affichés
    /// (`enabled`, dans l'ordre). Les onglets masqués gardent leurs cases : seuls les affichés s'y redistribuent.
    static func move(_ id: String, to index: Int, order: [String], enabled: [String]) -> [String] {
        guard let from = enabled.firstIndex(of: id) else { return order }
        var moved = enabled
        moved.remove(at: from)
        moved.insert(id, at: min(max(index, 0), moved.count))
        let shown = Set(enabled)
        var next = moved.makeIterator()
        return order.map { shown.contains($0) ? next.next() ?? $0 : $0 }
    }

    /// On masque un onglet affiché tant qu'il en reste un autre : la barre n'est jamais vide.
    static func canHide(_ id: String, enabled: [String]) -> Bool {
        enabled.count > 1 && enabled.contains(id)
    }

    /// Place visée par l'onglet `from` déplacé de `translation` points (une case = `slot` points), dans la barre.
    static func dropIndex(from: Int, translation: CGFloat, slot: CGFloat, count: Int) -> Int {
        min(max(from + Int((translation / slot).rounded()), 0), max(count - 1, 0))
    }

    /// Décalage, en cases, de l'onglet `index` pendant qu'un autre glisse de `from` vers `to` : il s'écarte.
    static func shift(_ index: Int, from: Int, to: Int) -> Int {
        if from < index, index <= to { return -1 }
        if to <= index, index < from { return 1 }
        return 0
    }
}

/// Oreilles d'un module qui tourne, avec son identifiant.
struct ModuleEarsEntry: Equatable {
    let id: String
    let ears: ModuleEars
}
