import AppKit
import SwiftUI

/// Onglet « Presse-papiers » : historique des copies. Textes dans Resources/{en,fr}.lproj/Clipboard.strings ;
/// réglages dans UserDefaults sous « clipboard.… ».
///
/// - Capture : un `Timer` d'une seconde (tolérance 0,5 s) ne lit que `changeCount`. Le contenu n'est lu que si
///   le compteur a changé, et seulement après les contrôles de confidentialité (types déclarés, app au premier
///   plan). Le module tourne panneau replié tant que la capture n'est pas suspendue, sinon l'historique aurait
///   des trous ; suspendue, il n'a plus de timer ni d'observateur. La copie est attribuée à l'app de devant au
///   début de l'intervalle (copier puis changer d'app est le geste courant), pas à celle du tic.
/// - Confidentialité : jamais d'élément portant un type « confidentiel », « temporaire » ou « généré » (voir
///   `ClipboardPrivacy`), jamais de copie faite depuis une app exclue (gestionnaires de mots de passe par défaut,
///   modifiable). L'exclusion vaut pour toutes les apps passées au premier plan depuis le dernier tic.
/// - Mémoire : historique en mémoire seulement par défaut, vidé quand l'onglet est désactivé. « Garder
///   l'historique après redémarrage » écrit textes et liens (jamais images, fichiers ni mise en forme) dans un
///   fichier 0600 (`ClipboardStorage`) qui est relu à la réactivation.
/// - Mise en forme (RTF, HTML) des textes : gardée en mémoire (100 Ko au plus par élément) pour que « Copier »
///   la restitue ; « Copier en texte brut » l'écarte.
/// - Accès : depuis macOS 15.4 le presse-papiers général peut être refusé ou soumis à une alerte ; `access` le
///   dit à l'onglet et aux réglages, qui renvoient vers Réglages Système.
/// - Images : vignette de 96 pt ; données d'origine gardées jusqu'à 5 Mo, au-delà l'image est ignorée ; 40 Mo
///   d'images au plus au total (les plus anciennes non épinglées partent d'abord).
/// - Copier depuis la liste réécrit le presse-papiers (jamais de collage automatique : il exigerait
///   l'accessibilité). Le `changeCount` obtenu est mémorisé : la copie n'est pas recapturée, l'élément remonte.
/// - La suspension ne dure que la session : au lancement suivant la capture reprend.
final class ClipboardModule: NotchModule {
    let id = "clipboard"
    let symbol = "doc.on.clipboard"
    var title: String { L("Presse-papiers", table: "Clipboard") }

    static let limits = [25, 50, 100]
    static let defaultLimit = 50
    /// Durée du retour visuel « Copié ».
    static let copiedFeedback: TimeInterval = 1.2

    // MARK: État

    @Published private(set) var history = ClipboardHistory()
    /// Élément qui vient d'être recopié (retour « Copié »).
    @Published private(set) var copiedID: UUID?
    /// Accès que macOS accorde au presse-papiers (relu au démarrage, à chaque copie vue et à l'ouverture de l'onglet).
    @Published private(set) var access = ClipboardAccess.allowed
    /// Dernière copie ignorée dont l'utilisateur doit savoir pourquoi ; effacée à la copie suivante gardée.
    @Published private(set) var notice: ClipboardNotice?
    /// La dernière écriture du fichier d'historique a échoué.
    @Published private(set) var persistenceFailed = false

    // MARK: Réglages

    /// Capture suspendue : le presse-papiers n'est plus lu du tout.
    @Published var suspended = false {
        didSet { if suspended != oldValue { syncPolling() } }
    }

    /// Plafond des éléments non épinglés : 25, 50 ou 100.
    @Published var limit: Int {
        didSet {
            if !Self.limits.contains(limit) { limit = Self.defaultLimit }
            defaults.set(limit, forKey: Key.limit)
            history.trim(limit: limit)
            historyChanged()
        }
    }

    /// Écrire textes et liens sur disque pour les retrouver après un redémarrage.
    @Published var keepsHistory: Bool {
        didSet {
            guard keepsHistory != oldValue else { return }
            defaults.set(keepsHistory, forKey: Key.keepsHistory)
            if keepsHistory {
                loadPersisted()
                scheduleSave()
            } else {
                saveWork?.cancel()
                saveWork = nil
                persistenceFailed = false
                storage.delete()
            }
        }
    }

    /// Identifiants d'apps dont les copies sont ignorées.
    @Published var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: Key.excludedApps) }
    }

    private enum Key {
        static let limit = "clipboard.limit"
        static let keepsHistory = "clipboard.keepsHistory"
        static let excludedApps = "clipboard.excludedApps"
    }

    private let defaults: UserDefaults
    private let pasteboard: ClipboardPasteboard
    private let frontApps: ClipboardFrontApps
    private let storage: ClipboardStorage
    private let clock: () -> Date
    private let saveDelay: TimeInterval

    private var isRunning = false
    private var timer: Timer?
    private var lastChangeCount = -1
    /// `changeCount` obtenu en écrivant nous-mêmes dans le presse-papiers.
    private var ownChangeCount = -1
    private var loaded = false
    private var saveWork: DispatchWorkItem?
    private var copiedWork: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    /// Le défaut ne touche ni au disque ni au presse-papiers : tout n'arrive qu'au `start()`.
    init(defaults: UserDefaults = .standard, pasteboard: ClipboardPasteboard = SystemPasteboard(),
         frontApps: ClipboardFrontApps = WorkspaceFrontApps(), storage: ClipboardStorage = ClipboardStorage(),
         clock: @escaping () -> Date = Date.init, saveDelay: TimeInterval = 2) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.frontApps = frontApps
        self.storage = storage
        self.clock = clock
        self.saveDelay = saveDelay
        let saved = defaults.integer(forKey: Key.limit)
        limit = Self.limits.contains(saved) ? saved : Self.defaultLimit
        keepsHistory = defaults.bool(forKey: Key.keepsHistory)
        excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? ClipboardPrivacy.defaultExcludedApps.map(\.id)
    }

    deinit { timer?.invalidate() }

    // MARK: Contrat

    var keepsRunningWhenCollapsed: Bool { !suspended }

    func makeView() -> AnyView { AnyView(ClipboardPanel(module: self)) }
    func makeSettingsView() -> AnyView? { AnyView(ClipboardSettingsView(module: self)) }
    func makeHeaderAccessory() -> AnyView? { AnyView(ClipboardSuspendButton(module: self)) }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshAccess()
        if keepsHistory { loadPersisted() }
        // Fin de l'app dans la seconde qui suit un changement : l'écriture débouncée aurait été perdue.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flushPersistence()
        }
        syncPolling()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        syncPolling()
        flushPersistence()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
        copiedWork?.cancel()
        copiedWork = nil
        copiedID = nil
        // Désactivé (et non simple repli d'une capture suspendue, que le module ne distingue pas de l'extérieur
        // quand il est aussi désactivé) : textes, liens et images ne restent pas en mémoire. Ce qui est sur disque
        // revient à la réactivation.
        if !suspended { releaseHistory() }
    }

    private func releaseHistory() {
        guard !history.items.isEmpty || notice != nil else { return }
        history = ClipboardHistory()
        notice = nil
        loaded = false
    }

    /// Le timer existe quand le module tourne et que la capture n'est pas suspendue. Il part toujours d'un
    /// `changeCount` frais : ce qui a été copié pendant la suspension ou l'arrêt n'est jamais enregistré.
    private func syncPolling() {
        let shouldPoll = isRunning && !suspended
        if shouldPoll, timer == nil {
            lastChangeCount = pasteboard.changeCount
            frontApps.start()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldPoll, let timer {
            timer.invalidate()
            self.timer = nil
            frontApps.stop()
        }
    }

    var isPolling: Bool { timer != nil }

    // MARK: Capture

    /// Un tic : si `changeCount` n'a pas bougé, rien d'autre n'est lu.
    func poll() {
        guard isRunning, !suspended else { return }
        let count = pasteboard.changeCount
        let apps = frontApps.drain()
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // Notre propre écriture (recopie d'un élément) : déjà dans l'historique.
        guard count != ownChangeCount else { return }
        refreshAccess()
        capture(apps: apps)
    }

    /// Relit l'accès accordé par macOS (une simple propriété, jamais le contenu).
    func refreshAccess() {
        let current = pasteboard.access
        if current != access { access = current }
    }

    func dismissNotice() {
        if notice != nil { notice = nil }
    }

    private func capture(apps: [ClipboardSource]) {
        if ClipboardPrivacy.hasIgnoredType(pasteboard.types) { return }
        if apps.contains(where: { ClipboardPrivacy.isExcluded($0, in: excludedApps) }) { return }
        let read = pasteboard.read()
        // `apps.first` : l'app de devant au début de l'intervalle. Une copie suivie d'un Cmd-Tab dans la même
        // seconde vient d'elle ; l'inverse (changer d'app, sélectionner, copier en moins d'une seconde) est rare.
        guard let content = read.content,
              let item = ClipboardItem(content, date: clock(), source: apps.first, rich: read.rich) else {
            if read.imageTooLarge { notice = .imageTooLarge }
            return
        }
        dismissNotice()
        history.add(item, limit: limit)
        historyChanged()
    }

    // MARK: Actions

    /// Recopie l'élément dans le presse-papiers (ou son texte brut) et le remonte en tête.
    func copy(_ id: UUID, plainText: Bool = false) {
        guard let item = history.items.first(where: { $0.id == id }) else { return }
        ownChangeCount = pasteboard.write(item.content, rich: item.rich, plainText: plainText)
        lastChangeCount = ownChangeCount
        history.touch(id, at: clock())
        historyChanged()
        copiedID = id
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copiedID = nil }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFeedback, execute: work)
    }

    func togglePin(_ id: UUID) {
        history.togglePin(id, limit: limit, at: clock())
        historyChanged()
    }

    func remove(_ id: UUID) {
        history.remove(id)
        historyChanged()
    }

    /// « Effacer l'historique » : tout part, épinglés compris, avec le fichier et les fichiers mis de côté (`.corrupt`),
    /// même si l'écriture sur disque est désactivée aujourd'hui.
    func clearHistory() {
        history.clear()
        copiedID = nil
        notice = nil
        persistenceFailed = false
        saveWork?.cancel()
        saveWork = nil
        storage.delete()
    }

    // MARK: Réglages des apps exclues

    func exclude(_ bundleID: String) {
        guard !bundleID.isEmpty, !excludedApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
        else { return }
        excludedApps.append(bundleID)
    }

    func resetExcludedApps() {
        excludedApps = ClipboardPrivacy.defaultExcludedApps.map(\.id)
    }

    // MARK: Disque

    private func historyChanged() {
        if keepsHistory { scheduleSave() }
    }

    private func loadPersisted() {
        guard !loaded else { return }
        loaded = true
        let older = storage.load().compactMap(ClipboardItem.init(record:))
        guard !older.isEmpty else { return }
        history.merge(older, limit: limit)
    }

    /// Écriture débouncée : une rafale de copies donne une seule écriture, faite hors du main thread.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    private func saveNow() {
        saveWork = nil
        guard keepsHistory else { return }
        storage.save(history.items.compactMap(\.record)) { [weak self] succeeded in
            guard let self, keepsHistory, persistenceFailed == succeeded else { return }
            persistenceFailed = !succeeded
        }
    }

    /// Écrit tout de suite ce qui attend et attend la fin (arrêt du module, fin de l'app, tests).
    func flushPersistence() {
        if saveWork != nil {
            saveWork?.cancel()
            saveNow()
        }
        storage.flush()
    }
}

/// Pourquoi une copie n'a pas été gardée.
enum ClipboardNotice: Equatable {
    /// Une image de plus de 5 Mo.
    case imageTooLarge
}
