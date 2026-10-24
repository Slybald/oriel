import SwiftUI

/// Onglet « Claude » : les sessions Claude Code, la section outils et la ligne Claude Desktop.
/// Le suivi des sessions (`SessionStore`, `ClaudeMonitor`) tourne tant que l'onglet est activé, géré par `AppCore` :
/// il nourrit les oreilles et la visibilité de la notch. Le module, lui, ne vit que panneau déplié (section outils).
final class ClaudeModule: NotchModule {
    let id = ModuleRegistry.claudeId
    let title = "Claude"
    let symbol = "sparkle"

    let store: SessionStore
    let monitor: ClaudeMonitor
    let tools: ToolsFeed
    let prefs: Preferences
    /// État des hooks (menu « … », réglages) ; injectable pour les tests.
    let hooks: HookSetup
    /// Demandes tenues et messages (« Répondre depuis la notch »), alimentés par le serveur de hooks.
    let replies: ReplyCenter
    /// Quota du compte (relais de statusLine) et réglage du relais : jauge de l'onglet, du résumé et de l'intercalaire.
    let usage: ClaudeUsageStore
    let quota: StatusLineSetup
    /// Saisies en cours dans les cartes de réponse.
    let drafts = ReplyDrafts()
    /// Posées par `NotchController.start()` (elles referment le panneau).
    var actions = NotchActions()

    /// Volet ouvert dans la section outils ; tout est replié à chaque ouverture du panneau.
    @Published var toolsPane: ToolsPane?
    /// Listes de tâches dépliées, par session ; oubliées à la fermeture du panneau.
    @Published var openChecklists: Set<String> = []

    init(store: SessionStore, monitor: ClaudeMonitor, tools: ToolsFeed, prefs: Preferences,
         hooks: HookSetup = .shared, replies: ReplyCenter = .shared, usage: ClaudeUsageStore = .shared,
         quota: StatusLineSetup = .shared) {
        self.store = store
        self.monitor = monitor
        self.tools = tools
        self.prefs = prefs
        self.hooks = hooks
        self.replies = replies
        self.usage = usage
        self.quota = quota
    }

    func start() {
        tools.setActive(true)
        // État des hooks pour le menu « … » (settings.json a pu changer depuis).
        hooks.refresh()
    }

    func stop() {
        tools.setActive(false)
        if toolsPane != nil { toolsPane = nil }
        if !openChecklists.isEmpty { openChecklists = [] }
        // Panneau replié : le clavier revient à l'app de devant, le texte saisi reste pour la prochaine fois.
        NotchKeyboard.release(force: true)
        if drafts.composing != nil { drafts.composing = nil }
        drafts.prune(keeping: replies.requests.map(\.id))
    }

    /// Clic dans une carte de réponse : la décision part au hook, la session quitte « attend ta permission ».
    func decide(_ request: ReplyCenter.Request, _ decision: ReplyCenter.Decision) {
        guard replies.decide(request, decision) else { return }
        switch decision {
        case .allow, .answer, .approvePlan: store.resolveAttention(request.sessionId, allowed: true)
        case .deny, .revisePlan: store.resolveAttention(request.sessionId, allowed: false)
        }
        drafts.prune(keeping: replies.requests.map(\.id))
    }

    /// « Activer » (carte du haut, conversation) : le réglage, puis les hooks si besoin. Déjà posés : rien d'autre ;
    /// d'une version précédente : mis à jour ; absents : la fenêtre d'installation, le choix reste à l'utilisateur.
    func enableReplies() {
        prefs.replyFromNotch = true
        hooks.refresh()
        switch HookSetup.repairNeeded(for: hooks.status) {
        case .none: break
        case .update: hooks.update()
        case .install: hooks.showOnboarding()
        }
    }

    func makeView() -> AnyView {
        AnyView(ClaudePanel(module: self, store: store, monitor: monitor, tools: tools, replies: replies, drafts: drafts,
                             usage: usage))
    }

    func makeCompactView() -> AnyView? {
        AnyView(ClaudeCompactView(module: self, store: store, replies: replies, prefs: prefs, usage: usage,
                                  activate: { [weak self] in self?.actions.activate($0) }))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(ClaudeSettingsView(prefs: prefs, setup: hooks, quota: quota))
    }

    func makeTabIcon() -> AnyView? {
        AnyView(ClaudeTabIcon(store: store))
    }

    func makeHeaderAccessory() -> AnyView? {
        AnyView(ClaudeHeaderPills(store: store, monitor: monitor))
    }
}

// MARK: - Onglet

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Hauteur cumulée des lignes sous la liste des sessions (espacement compris) : la liste leur cède la place
/// pour que le panneau tienne dans sa fenêtre.
private struct RowsBelowListKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    /// Déclare la hauteur de la ligne, plus l'espacement du VStack qui la précède.
    func countedBelowList(spacing: CGFloat) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: RowsBelowListKey.self, value: proxy.size.height + spacing)
        })
    }
}

/// Sessions, sessions sans suivi, section outils, ligne Claude Desktop.
struct ClaudePanel: View {
    @ObservedObject var module: ClaudeModule
    @ObservedObject var store: SessionStore
    @ObservedObject var monitor: ClaudeMonitor
    @ObservedObject var tools: ToolsFeed
    @ObservedObject var replies: ReplyCenter
    @ObservedObject var drafts: ReplyDrafts
    @ObservedObject var usage: ClaudeUsageStore

    @Environment(\.notchContentMaxHeight) private var contentMaxHeight
    @State private var listHeight: CGFloat = 0
    @State private var rowsBelowList: CGFloat = 0

    private static let spacing = ExpandedPanel.spacing
    static let maxListHeight: CGFloat = 296
    private static let minListHeight: CGFloat = 120

    /// Sans la section outils, on retombe toujours sur 296 (les autres lignes tiennent dans la marge). Une carte
    /// de réponse ou une conversation à l'écran : toute la hauteur disponible, pour que leurs boutons restent visibles.
    private var listMaxHeight: CGFloat {
        let needsRoom = module.prefs.replyFromNotch && !replies.requests.isEmpty || drafts.composing != nil
        let cap = needsRoom ? contentMaxHeight : Self.maxListHeight
        return min(cap, max(Self.minListHeight, contentMaxHeight - rowsBelowList))
    }

    private var untrackedCount: Int { monitor.cliPids.subtracting(store.trackedPids).count }

    /// Réponses coupées et jamais écartées : une carte les propose, volet des outils fermé (ouvert, la carte ferait
    /// déborder le panneau).
    private var proposesReplies: Bool {
        !module.prefs.replyFromNotch && !module.prefs.replyPromptDismissed && module.toolsPane == nil
    }

    var body: some View {
        let sessions = store.sortedSessions
        VStack(alignment: .leading, spacing: Self.spacing) {
            if proposesReplies {
                ReplyPromptCard(enable: { module.enableReplies() }, later: { module.prefs.replyPromptDismissed = true })
                    .countedBelowList(spacing: Self.spacing)
            }
            if sessions.isEmpty {
                EmptyStateView()
            } else {
                sessionList(sessions)
            }
            if untrackedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(String(format: L(untrackedCount,
                                          one: "%d session sans suivi — apparaîtra au prochain message",
                                          other: "%d sessions sans suivi — apparaîtront au prochain message"),
                                untrackedCount))
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 4)
                .countedBelowList(spacing: Self.spacing)
            }
            if tools.hasContent {
                ToolsSection(feed: tools, pane: $module.toolsPane, reveal: { module.actions.revealFile($0) })
                    .countedBelowList(spacing: Self.spacing)
            }
            if monitor.desktopRunning {
                DesktopRow(frontmost: monitor.desktopFrontmost, open: { module.actions.openDesktop() })
                    .countedBelowList(spacing: Self.spacing)
            }
            if let windows = usage.snapshot?.live(at: Date()) {
                QuotaStrip(windows: windows)
                    .countedBelowList(spacing: Self.spacing)
            }
        }
        .onPreferenceChange(RowsBelowListKey.self) { height in rowsBelowList = height }
    }

    private func sessionList(_ sessions: [Session]) -> some View {
        let estimate = CGFloat(sessions.count) * 72
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(sessions) { session in
                            ReplyableSessionCard(replies: module.replies, drafts: module.drafts, prefs: module.prefs,
                                                 session: session, now: context.date,
                                                 showTasks: checklistBinding(session.id),
                                                 onTap: { module.actions.activate(session) },
                                                 decide: { module.decide($0, $1) },
                                                 enable: { module.enableReplies() })
                                .id(session.id)
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    })
                }
                // La conversation qui s'ouvre vient en haut de la liste, champ de message compris.
                .onChange(of: drafts.composing) { id in
                    guard let id else { return }
                    withAnimation(notchSpring) { scroll.scrollTo(id, anchor: .top) }
                }
            }
            .frame(height: min(listHeight > 0 ? listHeight : estimate, listMaxHeight))
            .mask(listFade(overflowing: tools.hasContent && listHeight > listMaxHeight + 1))
        }
        .onPreferenceChange(ListHeightKey.self) { height in listHeight = height }
    }

    /// Liste tronquée par la section outils : fondu en bas plutôt qu'une carte coupée net.
    private func listFade(overflowing: Bool) -> some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: overflowing ? 22 : 0)
        }
    }

    private func checklistBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { module.openChecklists.contains(id) },
            set: { isOpen in
                if isOpen { module.openChecklists.insert(id) } else { module.openChecklists.remove(id) }
            }
        )
    }
}

// MARK: - En-tête

/// Icône de l'onglet : spinner quand Claude travaille, main qui pulse quand il attend, ✻ sinon.
struct ClaudeTabIcon: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        switch store.indicator {
        case .working: GlyphSpinner(size: 13)
        case .attention: PulsingHand(size: 12)
        default:
            Text(verbatim: "✻")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Palette.accent)
                .frame(width: 17, height: 17)
        }
    }
}

/// Pastilles CLI et Desktop, à droite des onglets quand l'onglet Claude est actif.
struct ClaudeHeaderPills: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var monitor: ClaudeMonitor

    private var cliActive: Bool {
        !monitor.cliPids.isEmpty || store.sessions.values.contains { $0.source == .cli && $0.phase != .ended }
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusPill(text: "CLI", active: cliActive)
            StatusPill(text: "Desktop", active: monitor.desktopRunning)
        }
    }
}

// MARK: - Plein écran compact

/// Sessions en cours : état et une ligne chacune. Un clic ramène l'app hôte devant, comme une carte.
/// Avec « Répondre depuis la notch », une demande en cours s'affiche dessous (sans champ de message).
struct ClaudeCompactView: View {
    let module: ClaudeModule
    @ObservedObject var store: SessionStore
    @ObservedObject var replies: ReplyCenter
    @ObservedObject var prefs: Preferences
    @ObservedObject var usage: ClaudeUsageStore
    let activate: (Session) -> Void

    static let maxSessions = 4

    var body: some View {
        let live = store.sortedSessions.filter { $0.phase != .ended }
        VStack(alignment: .leading, spacing: 6) {
            if live.isEmpty {
                Text("Aucune session en cours")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            ForEach(live.prefix(Self.maxSessions)) { session in
                row(session)
                if prefs.replyFromNotch,
                   SessionReplyArea.hasContent(session, replies: replies, drafts: module.drafts, compact: true) {
                    SessionReplyArea(replies: replies, drafts: module.drafts, prefs: prefs, session: session,
                                     compact: true, open: { activate(session) }, enable: { module.enableReplies() },
                                     decide: { module.decide($0, $1) })
                }
            }
            if live.count > Self.maxSessions {
                let more = live.count - Self.maxSessions
                Text(String(format: L(more, one: "+ %d autre session", other: "+ %d autres sessions"), more))
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 26)
            }
            if let windows = usage.snapshot?.live(at: Date()) {
                QuotaStrip(windows: windows, title: "Claude")
            }
        }
    }

    private func row(_ session: Session) -> some View {
        let status = session.status
        return HStack(alignment: .top, spacing: 8) {
            PhaseIcon(phase: session.phase)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                (Text(status.label).foregroundColor(status.color)
                    + Text(verbatim: status.detail.map { " · \($0)" } ?? "").foregroundColor(.white.opacity(0.7)))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ModuleStyle.shape(ModuleStyle.rowRadius)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            ModuleStyle.shape(ModuleStyle.rowRadius)
                .strokeBorder(Palette.amber.opacity(session.phase.needsAttention ? 0.9 : 0), lineWidth: 1)
        )
        .contentShape(ModuleStyle.shape(ModuleStyle.rowRadius))
        .onTapGesture { activate(session) }
    }
}

// MARK: - Réglages

/// Réglages › Claude : réponses depuis la notch, état des hooks.
struct ClaudeSettingsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var setup: HookSetup
    @ObservedObject var quota: StatusLineSetup

    var body: some View {
        SettingsPane {
            Section {
                Toggle("Répondre depuis la notch", isOn: $prefs.replyFromNotch)
                if prefs.replyFromNotch, setup.status != .installed {
                    Label(L("Hooks à mettre à jour pour répondre depuis la notch", table: "Claude"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.amber)
                }
            } header: {
                Text("Réponses", tableName: "Claude")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsNote(L("Permissions, questions et plans depuis la notch ; la première réponse gagne.",
                                   table: "Claude"))
                    SettingsNote(L("Carte pas ouverte sous 4 s : le terminal garde la main. Jamais de « toujours autoriser ».",
                                   table: "Claude"))
                    if prefs.replyFromNotch {
                        SettingsNote(L("Redémarre les sessions ouvertes avant la mise à jour des hooks.", table: "Claude"))
                    }
                }
            }
            if prefs.replyFromNotch { ApprovalKeysSettings(prefs: prefs) }
            quotaSection
            Section {
                LabeledContent("État") {
                    Text(statusText)
                        .foregroundColor(setup.status == .installed ? Palette.green : Palette.amber)
                }
                HStack {
                    switch setup.status {
                    case .installed:
                        Button("Réinstaller les hooks", action: setup.update)
                    case .outdated, .scriptOutdated:
                        Button("Mettre à jour les hooks", action: setup.update)
                    case .notInstalled, .unreadable:
                        Button("Installer les hooks Claude Code", action: setup.showOnboarding)
                    }
                    Spacer()
                    Button("Désinstaller Oriel…", action: setup.confirmAndUninstall)
                }
            } header: {
                Text("Hooks Claude Code")
            } footer: {
                SettingsNote(L("Les hooks relaient chaque événement de Claude Code à l'app, en local (127.0.0.1)."))
            }
        }
        .onAppear {
            setup.refresh()
            quota.refresh()
        }
    }

    /// Jauges de quota : le relais de `statusLine` ne se pose que sur ce réglage, et se retire de la même façon.
    private var quotaSection: some View {
        Section {
            Toggle(isOn: Binding(get: { quota.isOn }, set: { quota.setOn($0) })) {
                Text("Afficher le quota (5 h et 7 jours)", tableName: "Claude")
            }
            .disabled(quota.status == .unsupported)
            if let message = quota.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(quota.messageIsError ? Palette.amber : Palette.secondary)
            }
            if quota.status == .unsupported {
                Label(L("La « statusLine » de settings.json n'est pas une simple commande : rien n'a été modifié.",
                        table: "Claude"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.amber)
            }
        } header: {
            Text("Quota", tableName: "Claude")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                SettingsNote(L("Claude Code ne donne le quota qu'à sa « statusLine » (une seule commande possible, abonnés Pro et Max).",
                               table: "Claude"))
                SettingsNote(L("Le quota s'affiche quand Claude Code tourne dans un terminal (`claude`). L'app Claude ne le transmet pas.", table: "Claude"))
                SettingsNote(quota.chainsPrevious
                             ? L("Ta commande de statusLine continue de tourner : le relais la relance avec les mêmes données.",
                                 table: "Claude")
                             : L("Sans statusLine existante, le relais affiche seulement « 5h 39% · 7d 63% ».", table: "Claude"))
                SettingsNote(L("Sauvegarde horodatée de settings.json, retrait en un clic. Seuls les pourcentages sont gardés, en mémoire.",
                               table: "Claude"))
            }
        }
    }

    private var statusText: String {
        switch setup.status {
        case .installed: return L("Installés")
        case .outdated, .scriptOutdated: return L("À mettre à jour")
        case .notInstalled: return L("Non installés")
        case .unreadable(let message): return String(format: L("settings.json illisible : %@"), message)
        }
    }
}
