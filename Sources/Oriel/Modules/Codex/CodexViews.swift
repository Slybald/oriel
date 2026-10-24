import SwiftUI

// Vues du module Codex : onglet (cartes de session, approbation), mode compact plein écran, réglages.
// Même gabarit que l'onglet Claude (`SessionCard`, `ModuleKit`) : cartes de 14 pt, boutons en capsule.

// MARK: - Présentation d'une session

extension CodexSession {
    /// Pour réutiliser l'icône de phase de l'onglet Claude.
    var iconPhase: Phase {
        switch phase {
        case .ready: return .ready
        case .working: return .thinking
        case .waitingApproval: return .waitingPermission
        case .done: return .done
        case .ended: return .ended
        }
    }

    var status: SessionStatus {
        switch phase {
        case .ready:
            return SessionStatus(label: L("Prête"), detail: lastMessage, isCode: false, color: Palette.secondary)
        case .working:
            if let tool = currentTool {
                return SessionStatus(label: tool.label, detail: tool.detail, isCode: tool.isCode, color: Palette.accent)
            }
            return SessionStatus(label: L("Réfléchit…"), detail: lastPrompt.map { String(format: L("« %@ »"), $0) },
                                 isCode: false, color: Palette.accent)
        case .waitingApproval:
            return SessionStatus(label: L("Attend ton approbation", table: "Codex"), detail: attention?.detail,
                                 isCode: attention?.isCode ?? false, color: Palette.amber)
        case .done:
            return SessionStatus(label: L("Terminé"), detail: lastMessage, isCode: false, color: Palette.green)
        case .ended:
            return SessionStatus(label: L("Session terminée"), detail: nil, isCode: false, color: Palette.secondary)
        }
    }
}

// MARK: - En-tête

/// Icône de l'onglet : spinner quand Codex travaille, main qui pulse quand il attend, symbole sinon.
struct CodexTabIcon: View {
    @ObservedObject var store: CodexStore

    var body: some View {
        switch store.indicator {
        case .working: GlyphSpinner(size: 13)
        case .attention: PulsingHand(size: 12)
        default:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Palette.accent)
                .frame(width: 17, height: 17)
        }
    }
}

// MARK: - Onglet

struct CodexPanel: View {
    @ObservedObject var module: CodexModule
    @ObservedObject var store: CodexStore
    @ObservedObject var approvals: CodexApprovals
    @ObservedObject var setup: CodexHookSetup
    @ObservedObject var usage: CodexUsageStore

    @Environment(\.notchContentMaxHeight) private var contentMaxHeight
    @State private var listHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 296

    var body: some View {
        let sessions = store.sortedSessions
        VStack(alignment: .leading, spacing: ExpandedPanel.spacing) {
            if sessions.isEmpty {
                emptyState
            } else {
                sessionList(sessions)
            }
            if module.showsQuota, let windows = usage.snapshot?.live(at: Date()) {
                QuotaStrip(windows: windows)
            }
        }
    }

    /// Ce qu'il reste à faire pour voir une session : poser les hooks, les approuver dans Codex, ouvrir une conversation.
    private var emptyState: some View {
        CodexSetupState(module: module, setup: setup)
            .padding(.vertical, 12)
    }

    private func sessionList(_ sessions: [CodexSession]) -> some View {
        let estimate = CGFloat(sessions.count) * 72
        let cap = module.replyFromNotch && !approvals.requests.isEmpty ? contentMaxHeight : Self.maxListHeight
        let limit = min(cap, contentMaxHeight)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            CodexSessionCard(session: session, now: context.date, onTap: { module.activate(session) })
                            CodexApprovalArea(module: module, approvals: approvals, session: session, compact: false)
                        }
                        .animation(notchSpring, value: approvals.request(for: session.id)?.id)
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CodexListHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: min(listHeight > 0 ? listHeight : estimate, limit))
        }
        .onPreferenceChange(CodexListHeightKey.self) { listHeight = $0 }
    }
}

private struct CodexListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Parcours d'installation

/// Onglet sans session : l'étape où en est l'utilisateur (hooks absents, à approuver dans Codex, prêts) et le bouton qui
/// la fait avancer. Se met à jour tout seul (`CodexHookSetup.watch`).
struct CodexSetupState: View {
    @ObservedObject var module: CodexModule
    @ObservedObject var setup: CodexHookSetup

    var body: some View {
        let content = Self.content(for: setup.flow, message: setup.message, messageIsError: setup.messageIsError)
        VStack(spacing: 8) {
            ModuleEmptyState(symbol: content.symbol, tint: content.warning ? Palette.amber : Palette.accent,
                             title: content.title, detail: content.detail, progress: setup.isWorking,
                             action: setup.isWorking ? nil : action(for: content.action))
            if setup.messageIsError, let message = setup.message {
                Text(verbatim: message)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.amber)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    enum Action { case settings, approve }

    struct Content: Equatable {
        var symbol: String
        var title: String
        var detail: String
        var warning = false
        var action: Action?
    }

    /// Textes de chaque étape (testés sans vue).
    static func content(for flow: CodexHookSetup.Flow, message: String?, messageIsError: Bool) -> Content {
        let symbol = "chevron.left.forwardslash.chevron.right"
        switch flow {
        case .notInstalled:
            return Content(symbol: symbol, title: L("Hooks Codex non posés", table: "Codex"),
                           detail: L("Pose les hooks Codex dans les réglages pour suivre tes sessions.", table: "Codex"),
                           action: .settings)
        case .needsUpdate:
            return Content(symbol: symbol, title: L("Hooks Codex à mettre à jour", table: "Codex"),
                           detail: L("Mets-les à jour dans les réglages, puis approuve-les dans Codex.", table: "Codex"),
                           warning: true, action: .settings)
        case .disabled:
            return Content(symbol: "exclamationmark.triangle.fill", title: L("Hooks coupés dans Codex", table: "Codex"),
                           detail: L("config.toml contient [features] hooks = false : Codex n'exécute aucun hook.", table: "Codex"),
                           warning: true)
        case .unreadable:
            return Content(symbol: "exclamationmark.triangle.fill", title: L("hooks.json illisible", table: "Codex"),
                           detail: L("Corrige-le ou ouvre les réglages pour voir pourquoi.", table: "Codex"), warning: true,
                           action: .settings)
        case .pendingApproval:
            return Content(symbol: "hand.raised.fill", title: L("À approuver dans Codex", table: "Codex"),
                           detail: L("Codex ignore les hooks d'Oriel tant que tu ne les as pas approuvés.\n"
                                     + "1. Clique sur « Approuver dans Codex ».\n"
                                     + "2. Ouvre une nouvelle conversation dans l'app ChatGPT (ou lance codex).", table: "Codex"),
                           warning: true, action: .approve)
        case .active:
            let confirmation = messageIsError ? nil : message
            return Content(symbol: symbol, title: L("Aucune session Codex", table: "Codex"),
                           detail: confirmation ?? L("Ouvre une nouvelle conversation dans l'app ChatGPT ou lance codex dans un "
                                                     + "terminal. Les conversations déjà ouvertes ne sont pas suivies.",
                                                     table: "Codex"))
        }
    }

    private func action(for action: Action?) -> ModuleAction? {
        switch action {
        case .settings:
            return ModuleAction(title: L("Ouvrir les réglages", table: "Codex"), symbol: "gearshape", run: module.openSettings)
        case .approve:
            return ModuleAction(title: L("Approuver dans Codex", table: "Codex"), symbol: "checkmark.shield",
                                style: .prominent, run: setup.approve)
        case nil:
            return nil
        }
    }
}

// MARK: - Carte de session

struct CodexSessionCard: View {
    let session: CodexSession
    let now: Date
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PhaseIcon(phase: session.iconPhase)
                    .frame(width: 16, height: 16)
                Text(verbatim: session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                SourcePill(text: session.sourceLabel)
                if let model = session.model {
                    Text(verbatim: model)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 8)
                Text(verbatim: timeText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Palette.secondary)
            }
            activityLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ModuleStyle.shape(14).fill(Color.white.opacity(hovering ? 0.08 : 0.05))
        )
        .overlay(
            ModuleStyle.shape(14).strokeBorder(Palette.amber.opacity(session.phase.needsAttention ? 0.9 : 0), lineWidth: 1)
        )
        .contentShape(ModuleStyle.shape(14))
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .help(session.cwd ?? "")
    }

    private var activityLine: some View {
        let status = session.status
        return HStack(spacing: 6) {
            Text(verbatim: status.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(status.color)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = status.detail {
                Text(verbatim: detail)
                    .font(.system(size: 11, design: status.isCode ? .monospaced : .default))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var timeText: String {
        if session.inTurn, let start = session.turnStart { return SessionCard.duration(now.timeIntervalSince(start)) }
        return SessionCard.relative(now.timeIntervalSince(session.endedAt ?? session.lastActivity))
    }
}

// MARK: - Approbation

/// Sous la carte : la demande de Codex avec ses boutons, ou la consigne « Réponds dans … », et le dernier retour.
struct CodexApprovalArea: View {
    @ObservedObject var module: CodexModule
    @ObservedObject var approvals: CodexApprovals
    let session: CodexSession
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if module.replyFromNotch, let request = approvals.request(for: session.id) {
                CodexApprovalCard(request: request, compact: compact, engage: { approvals.engage(request.id) },
                                  decide: { module.decide(request, $0) })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if session.phase.needsAttention {
                ReplyStatusLine(icon: "arrow.up.forward.app", color: Palette.secondary,
                                text: String(format: L("Réponds dans %@", table: "Codex"), session.sourceLabel))
            }
            if let notice = approvals.notices[session.id] {
                ReplyStatusLine(icon: notice.tone.icon, color: notice.tone.color, text: notice.text)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: approvals.notices[session.id])
    }

    static func hasContent(_ session: CodexSession, module: CodexModule, approvals: CodexApprovals) -> Bool {
        (module.replyFromNotch && approvals.request(for: session.id) != nil) || session.phase.needsAttention
            || approvals.notices[session.id] != nil
    }
}

extension CodexApprovals.Notice.Tone {
    var icon: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: return Palette.green
        case .info: return Palette.secondary
        case .warning: return Palette.amber
        }
    }
}

struct CodexApprovalCard: View {
    let request: CodexApprovals.Request
    var compact = false
    @ObservedObject var keys: ApprovalQueue = .shared
    let engage: () -> Void
    let decide: (CodexApprovals.Decision) -> Void

    /// La touche, seulement sur la carte qui a les touches (la plus ancienne) et si macOS a accepté la combinaison.
    private func keycap(_ choice: HotKeyChoice, live: Bool) -> String? {
        keys.keyedId == request.id && live ? choice.title : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.amber)
                Text(verbatim: String(format: L("Autoriser %@ ?", table: "Codex"), request.tool.label))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                if let note = request.note {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                ApprovalRank(keys: keys, id: request.id)
            }
            if let detail = request.tool.detail {
                Text(verbatim: detail)
                    .font(.system(size: 11, design: request.tool.isCode ? .monospaced : .default))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ModuleStyle.shape(ModuleStyle.itemRadius).fill(Color.black.opacity(0.35)))
                    .help(detail)
                if RequestCard.isLong(detail) || detail.hasSuffix("…") {
                    ReplyStatusLine(icon: "eye", color: Palette.amber,
                                    text: L("Texte coupé : lis-le en entier dans la session", table: "Codex"))
                }
            }
            // Étroit (plein écran compact) : la ligne serait coupée ; le délai reste dit dans les réglages.
            if !compact {
                ReplyStatusLine(icon: "clock", color: Palette.secondary,
                                text: String(format: L("Sans clic sous %d s, Codex te le redemande dans le terminal.", table: "Codex"),
                                             Int(CodexApprovals.engagedDelay)))
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ReplyButton(title: L("Dans le terminal", table: "Codex"), style: .secondary) { decide(.terminal) }
                ReplyButton(title: L("Refuser", table: "Codex"), style: .destructive,
                            keycap: keycap(.controlOptionN, live: keys.denyLive)) { decide(.deny) }
                ReplyButton(title: L("Autoriser", table: "Codex"), style: .primary,
                            keycap: keycap(.controlOptionY, live: keys.approveLive)) { decide(.allow) }
            }
        }
        .padding(10)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Color.white.opacity(0.07)))
        .overlay(ModuleStyle.shape(ModuleStyle.cardRadius).strokeBorder(Palette.amber.opacity(0.35), lineWidth: 1))
        // La carte est à l'écran : la notch garde la demande le temps qu'il faut (sinon 4 s).
        .onAppear {
            engage()
            keys.cardAppeared(request.id)
        }
        .onDisappear { keys.cardDisappeared(request.id) }
    }
}

// MARK: - Plein écran compact

/// Sessions en cours : état et une ligne chacune. Un clic ramène l'app hôte devant. Avec « Approuver depuis la
/// notch », une demande en cours s'affiche dessous.
struct CodexCompactView: View {
    let module: CodexModule
    @ObservedObject var store: CodexStore
    @ObservedObject var approvals: CodexApprovals
    @ObservedObject var usage: CodexUsageStore

    /// Codex n'est relu que panneau ouvert : au-delà de 15 min, l'intercalaire ne montre plus la mesure.
    static let quotaMaxAge: TimeInterval = 15 * 60
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
                if CodexApprovalArea.hasContent(session, module: module, approvals: approvals) {
                    CodexApprovalArea(module: module, approvals: approvals, session: session, compact: true)
                }
            }
            if live.count > Self.maxSessions {
                let more = live.count - Self.maxSessions
                Text(String(format: L(more, one: "+ %d autre session", other: "+ %d autres sessions"), more))
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 26)
            }
            if module.showsQuota, let windows = usage.snapshot?.live(at: Date(), maxAge: Self.quotaMaxAge) {
                QuotaStrip(windows: windows, title: "Codex")
            }
        }
    }

    private func row(_ session: CodexSession) -> some View {
        let status = session.status
        return HStack(alignment: .top, spacing: 8) {
            PhaseIcon(phase: session.iconPhase)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: session.projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                (Text(verbatim: status.label).foregroundColor(status.color)
                    + Text(verbatim: status.detail.map { " · \($0)" } ?? "").foregroundColor(.white.opacity(0.7)))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ModuleStyle.shape(ModuleStyle.rowRadius).fill(Color.white.opacity(0.05)))
        .overlay(
            ModuleStyle.shape(ModuleStyle.rowRadius)
                .strokeBorder(Palette.amber.opacity(session.phase.needsAttention ? 0.9 : 0), lineWidth: 1)
        )
        .contentShape(ModuleStyle.shape(ModuleStyle.rowRadius))
        .onTapGesture { module.activate(session) }
    }
}

// MARK: - Réglages

/// Réglages › Codex : approbations depuis la notch, état des hooks.
struct CodexSettingsView: View {
    @ObservedObject var module: CodexModule
    @ObservedObject var setup: CodexHookSetup
    @ObservedObject var prefs: Preferences = .shared

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $module.replyFromNotch) {
                    Text("Approuver depuis la notch", tableName: "Codex")
                }
            } header: {
                Text("Approbations", tableName: "Codex")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsNote(L("Les demandes d'approbation de Codex s'affichent dans la notch ; un clic décide.",
                                   table: "Codex"))
                    SettingsNote(String(format: L("Codex attend ce hook avant de poser sa question : sans clic sous %d s, ou avec « Dans le terminal », "
                                                  + "il te la pose dans le terminal. Jamais de « toujours autoriser ».",
                                                  table: "Codex"), Int(CodexApprovals.engagedDelay)))
                }
            }
            if module.replyFromNotch { ApprovalKeysSettings(prefs: prefs) }
            Section {
                Toggle(isOn: $module.showsQuota) {
                    Text("Afficher le quota (5 h et 7 jours)", tableName: "Codex")
                }
            } header: {
                Text("Quota", tableName: "Codex")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsNote(L("Lu par Codex lui-même (compte ChatGPT), seulement panneau ouvert : au plus une fois par minute, "
                                   + "puis toutes les 5 min. Rien sans compte ChatGPT.", table: "Codex"))
                }
            }
            Section {
                LabeledContent("État") {
                    HStack(spacing: 6) {
                        if setup.isWorking { ProgressView().controlSize(.small) }
                        Text(verbatim: statusText)
                            .foregroundColor(setup.flow == .active ? Palette.green : Palette.amber)
                    }
                }
                if setup.notes.hooksDisabled {
                    warning(L("Les hooks sont coupés dans config.toml ([features] hooks = false).", table: "Codex"))
                }
                if case .pendingApproval = setup.flow {
                    warning(L("Codex ignore ces hooks tant qu'ils ne sont pas approuvés.", table: "Codex"))
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsNote(L("1. Clique sur « Approuver dans Codex ».", table: "Codex"))
                        SettingsNote(L("2. Ouvre une nouvelle conversation dans l'app ChatGPT (ou lance codex) : "
                                       + "les conversations déjà ouvertes ne sont pas suivies.", table: "Codex"))
                    }
                }
                if let last = module.lastEventAt {
                    LabeledContent {
                        Text(verbatim: SessionCard.relative(Date().timeIntervalSince(last)))
                    } label: {
                        Text("Dernier événement", tableName: "Codex")
                    }
                }
                if setup.canApprove {
                    HStack {
                        Button(action: setup.approve) { Text("Approuver dans Codex", tableName: "Codex") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
                HStack {
                    Button(action: setup.install) { installLabel }
                    if setup.status == .installed {
                        Button { setup.verify(force: true) } label: { Text("Vérifier", tableName: "Codex") }
                            .disabled(setup.isWorking)
                    }
                    Spacer()
                    if setup.status != .notInstalled {
                        Button(action: setup.uninstall) { Text("Retirer les hooks", tableName: "Codex") }
                    }
                }
                if let message = setup.message {
                    Text(verbatim: message)
                        .font(.system(size: 11))
                        .foregroundColor(setup.messageIsError ? Palette.red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Hooks Codex", tableName: "Codex")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsNote(L("Les hooks relaient chaque événement de Codex à l'app, en local (127.0.0.1).", table: "Codex"))
                    SettingsNote(L("Oriel n'écrit que ~/.codex/hooks.json (sauvegarde horodatée) ; ton notify n'est jamais "
                                   + "touché.", table: "Codex"))
                    SettingsNote(L("« Approuver » demande à Codex lui-même d'inscrire l'approbation de ces hooks dans config.toml "
                                   + "(la requête du bouton « Review hooks » de l'app). Tu peux aussi les revoir toi-même : "
                                   + "« Review hooks » dans l'app, /hooks dans le terminal.", table: "Codex"))
                    if setup.notes.inlineHooks {
                        SettingsNote(L("config.toml contient aussi des hooks : Codex charge les deux fichiers.", table: "Codex"))
                    }
                }
            }
        }
        .onAppear {
            setup.refresh()
            setup.watch(true)
            setup.verify()
        }
        .onDisappear { setup.watch(false) }
    }

    @ViewBuilder
    private var installLabel: some View {
        switch setup.status {
        case .installed: Text("Réinstaller les hooks", tableName: "Codex")
        case .outdated, .scriptOutdated: Text("Mettre à jour les hooks", tableName: "Codex")
        case .notInstalled, .unreadable: Text("Installer les hooks Codex", tableName: "Codex")
        }
    }

    private var statusText: String {
        switch setup.flow {
        case .active: return L("Actifs", table: "Codex")
        case .pendingApproval: return L("En attente d'approbation dans Codex", table: "Codex")
        case .needsUpdate: return L("À mettre à jour")
        case .notInstalled: return L("Non installés")
        case .disabled: return L("Coupés dans config.toml", table: "Codex")
        case .unreadable(let message): return String(format: L("hooks.json illisible : %@", table: "Codex"), message)
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 11))
        .foregroundColor(Palette.amber)
    }
}
