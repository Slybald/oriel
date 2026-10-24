import AppKit
import SwiftUI

// Interface de « Répondre depuis la notch » : sous chaque carte de session, la demande en cours (permission,
// question, plan), le champ de message et les retours. Textes : table « Claude ».

/// Saisies en cours, gardées quand le panneau se replie ou qu'un onglet change.
final class ReplyDrafts: ObservableObject {
    /// Session dont le champ de message est ouvert.
    @Published var composing: String?
    /// Message libre, par session : gardé jusqu'à l'envoi, jamais touché par `prune`.
    @Published var messages: [String: String] = [:]
    /// Motif de refus ou changements demandés (clé : demande), réponse libre (clé : demande#question).
    @Published var texts: [String: String] = [:]
    /// Libellés cochés d'une question (clé : demande#question).
    @Published var choices: [String: Set<String>] = [:]

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.texts[key] ?? "" }, set: { self.texts[key] = $0.isEmpty ? nil : $0 })
    }

    func message(_ session: String) -> Binding<String> {
        Binding(get: { self.messages[session] ?? "" }, set: { self.messages[session] = $0.isEmpty ? nil : $0 })
    }

    static func key(_ request: UUID, _ question: Int? = nil) -> String {
        question.map { "\(request.uuidString)#\($0)" } ?? request.uuidString
    }

    /// Oublie les saisies des demandes qui ne sont plus tenues (les messages ont leur propre table).
    func prune(keeping requests: [UUID]) {
        let live = Set(requests.map(\.uuidString))
        texts = texts.filter { live.contains(String($0.key.prefix(36))) }
        choices = choices.filter { live.contains(String($0.key.prefix(36))) }
    }
}

/// Clavier du panneau de la notch, qui ne s'active jamais : il ne devient fenêtre clé que pour un champ de texte,
/// et rend le clavier à l'app de devant dès que le champ se ferme, sinon les frappes suivantes s'y perdraient.
enum NotchKeyboard {
    /// La bulle quand la notch est détachée (la notch ne peut alors pas se déplier), sinon la notch.
    static var panel: NSWindow? {
        NSApp.windows.first { $0 is BubblePanel && $0.isVisible } ?? NSApp.windows.first { $0 is NotchPanel && $0.isVisible }
    }

    static func take() {
        panel?.makeKey()
    }

    /// `force` : même si un champ est en cours de saisie (Échap, envoi, panneau replié).
    static func release(force: Bool = false) {
        guard let panel, panel.isKeyWindow else { return }
        if !force, panel.firstResponder is NSText { return }
        panel.makeFirstResponder(nil)
        // Sortir puis remettre le panneau (non activant) : le statut de fenêtre clé revient à l'app de devant.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}

// MARK: - Sous la carte de session

/// Carte de session, avec « Converser » au survol, puis la zone de réponse.
struct ReplyableSessionCard: View {
    @ObservedObject var replies: ReplyCenter
    @ObservedObject var drafts: ReplyDrafts
    @ObservedObject var prefs: Preferences
    let session: Session
    let now: Date
    @Binding var showTasks: Bool
    let onTap: () -> Void
    let decide: (ReplyCenter.Request, ReplyCenter.Decision) -> Void
    let enable: () -> Void

    @State private var hovering = false

    private var canConverse: Bool {
        session.phase != .ended && replies.request(for: session.id) == nil && drafts.composing != session.id
    }

    /// La conversation s'ouvre même réponses coupées (on y lit ce que Claude a dit) ; le reste, seulement réponses
    /// activées.
    private var showsArea: Bool {
        drafts.composing == session.id
            || (prefs.replyFromNotch && SessionReplyArea.hasContent(session, replies: replies, drafts: drafts))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SessionCard(session: session, now: now, showTasks: $showTasks, onTap: onTap)
                .overlay(alignment: .topTrailing) {
                    if hovering, canConverse { conversationButton }
                }
                .onHover { hovering = $0 }
            if showsArea {
                SessionReplyArea(replies: replies, drafts: drafts, prefs: prefs, session: session, open: onTap,
                                 enable: enable, decide: decide)
            }
        }
        .animation(notchSpring, value: replies.request(for: session.id)?.id)
        .animation(notchSpring, value: drafts.composing == session.id)
    }

    /// Recouvre l'heure de la carte, le temps du survol.
    private var conversationButton: some View {
        Button {
            drafts.composing = session.id
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble")
                Text("Converser", tableName: "Claude")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Palette.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(white: 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Voir la conversation et écrire à Claude", table: "Claude"))
        .padding(.top, 8)
        .padding(.trailing, 10)
        .transition(.opacity)
    }
}

/// Demande en cours, champ de message, consigne « Réponds dans… », file d'attente, dernier retour.
struct SessionReplyArea: View {
    @ObservedObject var replies: ReplyCenter
    @ObservedObject var drafts: ReplyDrafts
    @ObservedObject var prefs: Preferences
    let session: Session
    var compact = false
    /// Ouvre la session dans son app (Claude Desktop, terminal).
    let open: () -> Void
    let enable: () -> Void
    let decide: (ReplyCenter.Request, ReplyCenter.Decision) -> Void

    static func hasContent(_ session: Session, replies: ReplyCenter, drafts: ReplyDrafts, compact: Bool = false) -> Bool {
        replies.request(for: session.id) != nil || (!compact && drafts.composing == session.id)
            || session.phase.needsAttention || replies.queued[session.id] != nil || replies.notices[session.id] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let request = replies.request(for: session.id) {
                RequestCard(request: request, drafts: drafts, compact: compact,
                            engage: { replies.engage(request.id) }, decide: { decide(request, $0) })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !compact, drafts.composing == session.id {
                ConversationView(replies: replies, drafts: drafts, prefs: prefs, session: session, open: open,
                                 enable: enable)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if session.phase.needsAttention {
                ReplyActionLine(icon: "arrow.up.forward.app",
                                text: String(format: L("Réponds dans %@", table: "Claude"), session.replyTarget),
                                button: L("Ouvrir", table: "Claude"), action: open)
            }
            if let count = replies.queued[session.id]?.count, count > 0 {
                HStack(spacing: 6) {
                    // Tour en cours : il part à sa fin. Session au repos sans attente : au prochain tour de Claude.
                    ReplyStatusLine(icon: "tray.full", color: Palette.amber, text: String(format: session.phase.isWorking ? L(
                        count, one: "%d message en file : il partira à la fin du tour",
                        other: "%d messages en file : ils partiront à la fin du tour", table: "Claude") : L(
                        count, one: "%d message en file : il partira au prochain tour de Claude",
                        other: "%d messages en file : ils partiront au prochain tour de Claude", table: "Claude"), count))
                    Spacer(minLength: 4)
                    Button(L("Annuler", table: "Claude")) { replies.dropQueue(session.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
            }
            if let notice = replies.notices[session.id] {
                ReplyStatusLine(icon: notice.tone.icon, color: notice.tone.color, text: notice.text)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: replies.notices[session.id])
    }
}

extension ReplyCenter.Notice.Tone {
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

struct ReplyStatusLine: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 6)
    }
}

// MARK: - Demande (permission, question, plan)

struct RequestCard: View {
    let request: ReplyCenter.Request
    @ObservedObject var drafts: ReplyDrafts
    var compact = false
    @ObservedObject var keys: ApprovalQueue = .shared
    let engage: () -> Void
    let decide: (ReplyCenter.Decision) -> Void

    private var key: String { ReplyDrafts.key(request.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.kind {
            case .permission(let permission): permissionBody(permission)
            case .question(let questions): QuestionForm(request: request, questions: questions, drafts: drafts,
                                                        decide: decide)
            case .plan(let plan): planBody(plan)
            }
        }
        .padding(10)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Color.white.opacity(0.07)))
        .overlay(
            ModuleStyle.shape(ModuleStyle.cardRadius)
                .strokeBorder(Palette.amber.opacity(0.35), lineWidth: 1)
        )
        // La carte est à l'écran : la notch garde la demande le temps qu'il faut (sinon 4 s).
        .onAppear {
            engage()
            keys.cardAppeared(request.id)
        }
        .onDisappear {
            keys.cardDisappeared(request.id)
            NotchKeyboard.release()
        }
    }

    // MARK: Permission

    /// La touche, seulement sur la carte qui a les touches (la plus ancienne) et si macOS a accepté la combinaison.
    private func keycap(_ choice: HotKeyChoice, live: Bool) -> String? {
        keys.keyedId == request.id && live ? choice.title : nil
    }

    private func permissionBody(_ permission: ReplyCenter.Permission) -> some View {
        let reason = drafts.binding(key)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.amber)
                Text(String(format: L("Autoriser %@ ?", table: "Claude"), permission.label))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                if let note = permission.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                ApprovalRank(keys: keys, id: request.id)
            }
            if let detail = permission.detail {
                PermissionDetail(text: detail, isCode: permission.isCode)
            }
            actionRow(
                field: ReplyField(placeholder: L("Pourquoi refuser ? (facultatif)", table: "Claude"), text: reason,
                                  onSubmit: { if !reason.wrappedValue.isEmpty { decide(.deny(reason.wrappedValue)) } }),
                secondary: ReplyButton(title: L("Refuser", table: "Claude"), style: .destructive,
                                       keycap: keycap(.controlOptionN, live: keys.denyLive)) {
                    decide(.deny(reason.wrappedValue))
                },
                primary: ReplyButton(title: L("Autoriser", table: "Claude"), style: .primary,
                                     keycap: keycap(.controlOptionY, live: keys.approveLive)) { decide(.allow) }
            )
        }
    }

    // MARK: Plan

    private func planBody(_ plan: String) -> some View {
        let changes = drafts.binding(key)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.amber)
                Text("Plan à valider", tableName: "Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
            }
            if !plan.isEmpty {
                Text(plan)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(compact ? 6 : 9)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ModuleStyle.shape(ModuleStyle.itemRadius).fill(Color.black.opacity(0.35)))
                    .help(plan)
            }
            actionRow(
                field: ReplyField(placeholder: L("Changements à demander…", table: "Claude"), text: changes,
                                  onSubmit: { if !changes.wrappedValue.isEmpty { decide(.revisePlan(changes.wrappedValue)) } }),
                secondary: ReplyButton(title: L("Demander des changements", table: "Claude"), style: .secondary) {
                    decide(.revisePlan(changes.wrappedValue))
                },
                primary: ReplyButton(title: L("Approuver", table: "Claude"), style: .primary) { decide(.approvePlan) }
            )
        }
    }

    /// Champ et boutons sur une ligne ; en mode compact (plein écran, demi-largeur), le champ au-dessus.
    @ViewBuilder
    private func actionRow(field: ReplyField, secondary: ReplyButton, primary: ReplyButton) -> some View {
        if compact {
            VStack(alignment: .trailing, spacing: 6) {
                field
                HStack(spacing: 6) {
                    secondary
                    primary
                }
            }
        } else {
            HStack(spacing: 6) {
                field.frame(minWidth: 120)
                secondary
                primary
            }
        }
    }

    /// Coupé à coup sûr, sans mesure : plus de 420 caractères ou de 6 lignes.
    static func isLong(_ text: String) -> Bool {
        text.count > 420 || text.reduce(0) { $1.isNewline ? $0 + 1 : $0 } >= 6
    }
}

/// Ce qui sera autorisé, sur 6 lignes au plus. Dès que le texte affiché est coupé (lignes longues repliées
/// comprises), la carte le dit : la fin cachée peut changer ce que fait la commande.
private struct PermissionDetail: View {
    let text: String
    let isCode: Bool

    @State private var clipped = false

    private static let maxLines = 6
    private var font: Font { .system(size: 11, design: isCode ? .monospaced : .default) }

    var body: some View {
        let long = RequestCard.isLong(text)
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(font)
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(Self.maxLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay { if !long { probe } }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ModuleStyle.shape(ModuleStyle.itemRadius).fill(Color.black.opacity(0.35)))
                .help(text)
            if long || clipped {
                ReplyStatusLine(icon: "eye", color: Palette.amber,
                                text: L("Texte coupé : lis-le en entier dans la session", table: "Claude"))
            }
        }
        .onPreferenceChange(ClippedKey.self) { clipped = $0 }
    }

    /// Le même texte sans limite de lignes, invisible, à la même largeur : plus haut que l'affiché, il est coupé.
    private var probe: some View {
        GeometryReader { shown in
            Text(text)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .frame(width: shown.size.width, alignment: .leading)
                .background(GeometryReader { full in
                    Color.clear.preference(key: ClippedKey.self, value: full.size.height > shown.size.height + 1)
                })
        }
    }
}

private struct ClippedKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Questions d'AskUserQuestion : un choix (ou plusieurs), ou une réponse libre ; « Répondre » une fois chaque
/// question réglée.
struct QuestionForm: View {
    let request: ReplyCenter.Request
    let questions: [ReplyCenter.Question]
    @ObservedObject var drafts: ReplyDrafts
    let decide: (ReplyCenter.Decision) -> Void

    private func key(_ question: ReplyCenter.Question) -> String { ReplyDrafts.key(request.id, question.id) }

    /// Réponse de chaque question, ou nil si l'une manque.
    private var answers: [String: String]? {
        var result: [String: String] = [:]
        for question in questions {
            let chosen = drafts.choices[key(question)] ?? []
            let other = drafts.texts[key(question)] ?? ""
            // Choix unique : le texte libre remplace le choix ; multiple : il s'y ajoute.
            let selected = question.multiSelect || other.isEmpty
                ? question.options.map(\.label).filter(chosen.contains) : []
            let answer = ReplyCenter.answer(selected: selected, other: other)
            guard !answer.isEmpty else { return nil }
            result[question.text] = answer
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(questions) { question in
                questionView(question, isLast: question.id == questions.last?.id)
            }
        }
    }

    private func submit() {
        if let answers { decide(.answer(answers)) }
    }

    private func questionView(_ question: ReplyCenter.Question, isLast: Bool) -> some View {
        let chosen = drafts.choices[key(question)] ?? []
        let other = ReplyField(placeholder: L("Autre réponse…", table: "Claude"), text: otherBinding(question),
                               onSubmit: submit)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let header = question.header {
                    Text(header.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(Palette.amber)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Palette.amber.opacity(0.15)))
                }
                Text(question.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                optionRow(option, question: question, selected: chosen.contains(option.label))
            }
            if isLast {
                // « Répondre » à côté du dernier champ : la carte reste basse.
                HStack(spacing: 6) {
                    other
                    ReplyButton(title: L("Répondre", table: "Claude"), style: .primary, isEnabled: answers != nil) {
                        submit()
                    }
                }
            } else {
                other
            }
        }
    }

    /// Choix unique : écrire une réponse libre décoche l'option choisie.
    private func otherBinding(_ question: ReplyCenter.Question) -> Binding<String> {
        let key = key(question)
        return Binding(get: { drafts.texts[key] ?? "" }, set: { text in
            drafts.texts[key] = text.isEmpty ? nil : text
            if !question.multiSelect, !text.isEmpty, drafts.choices[key] != nil { drafts.choices[key] = nil }
        })
    }

    private func optionRow(_ option: ReplyCenter.Question.Option, question: ReplyCenter.Question,
                           selected: Bool) -> some View {
        Button {
            var set = drafts.choices[key(question)] ?? []
            if question.multiSelect {
                if selected { set.remove(option.label) } else { set.insert(option.label) }
            } else {
                set = selected ? [] : [option.label]
                drafts.texts[key(question)] = nil
            }
            drafts.choices[key(question)] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: question.multiSelect
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(selected ? Palette.accent : Palette.secondary)
                Text(option.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(Palette.primary)
                if let detail = option.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(ModuleStyle.shape(ModuleStyle.itemRadius)
                .fill(selected ? Palette.accent.opacity(0.16) : Color.white.opacity(0.04)))
            .contentShape(ModuleStyle.shape(ModuleStyle.itemRadius))
        }
        .buttonStyle(.plain)
        .help(option.detail ?? option.label)
    }
}

// MARK: - Message libre

/// Champ de message d'une session. Avec une attente connectée, le message part tout de suite (Claude le lit à la
/// fin de l'action en cours, ou reprend la main) ; sinon il attend la fin du tour.
struct MessageComposer: View {
    @ObservedObject var replies: ReplyCenter
    @ObservedObject var drafts: ReplyDrafts
    let session: Session
    /// Seul : sa propre carte. Dans la conversation : la carte de la conversation l'entoure déjà.
    var framed = true
    /// Ouvre la session dans son app : proposé quand le message ne peut pas partir tout de suite.
    var open: (() -> Void)?

    @FocusState private var focused: Bool

    private var text: String { drafts.messages[session.id] ?? "" }
    private var canSend: Bool { !ReplyCenter.sanitize(text).isEmpty }

    var body: some View {
        let connected = replies.waiting.contains(session.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                ReplyField(placeholder: L("Message à Claude…", table: "Claude"), text: drafts.message(session.id),
                           onSubmit: send, onCancel: close)
                    .focused($focused)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundColor(canSend ? Palette.accent : Color.white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(L("Envoyer (Entrée)", table: "Claude"))
                .accessibilityLabel(L("Envoyer (Entrée)", table: "Claude"))
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Fermer (Échap)", table: "Claude"))
                .accessibilityLabel(L("Fermer (Échap)", table: "Claude"))
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(connected ? Palette.green : Palette.amber)
                    .frame(width: 6, height: 6)
                Text(connected
                     ? (session.phase.isWorking
                        ? L("Claude le lira après l'action en cours", table: "Claude")
                        : L("Claude le lira tout de suite", table: "Claude"))
                     : session.phase.isWorking
                        ? L("En file : il partira à la fin du tour", table: "Claude")
                        : L("En file : Claude le lira à son prochain tour", table: "Claude"))
                if text.utf8.count > ReplyCenter.maxMessageBytes {
                    Text(verbatim: "·")
                    Text("trop long, il sera coupé", tableName: "Claude")
                        .foregroundColor(Palette.amber)
                }
                if !connected, !session.phase.isWorking, let open {
                    Spacer(minLength: 4)
                    Button(L("Ouvrir", table: "Claude"), action: open)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Palette.accent)
                }
            }
            .font(.system(size: 10.5))
            .foregroundColor(Palette.secondary)
            .lineLimit(1)
            .padding(.leading, 2)
        }
        .padding(framed ? 8 : 0)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Color.white.opacity(framed ? 0.07 : 0)))
        .onAppear {
            NotchKeyboard.take()
            DispatchQueue.main.async { focused = true }
        }
        .onDisappear { NotchKeyboard.release() }
    }

    private func send() {
        guard canSend, replies.send(text, to: session.id) != nil else { return }
        drafts.messages[session.id] = nil
        close()
    }

    private func close() {
        focused = false
        drafts.composing = nil
        NotchKeyboard.release(force: true)
    }
}

// MARK: - Éléments

/// Champ sur fond sombre : Entrée envoie, Échap sort du champ (ou ferme, selon `onCancel`).
struct ReplyField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void = { NotchKeyboard.release(force: true) }

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.4)), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Palette.primary)
            .lineLimit(1...4)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(ModuleStyle.shape(ModuleStyle.itemRadius).fill(Color.white.opacity(0.08)))
    }
}

struct ReplyButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    let style: Style
    var isEnabled = true
    /// Touche du clavier qui fait la même chose (« ⌃⌥Y »), pour « Approuver au clavier ».
    var keycap: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let keycap { KeyCap(text: keycap) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(foreground)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .white.opacity(0.9)
        case .destructive: return Palette.red
        }
    }

    private var background: Color {
        let boost = hovering && isEnabled ? 0.06 : 0
        switch style {
        case .primary: return Palette.accent.opacity(hovering && isEnabled ? 1 : 0.88)
        case .secondary: return Color.white.opacity(0.12 + boost)
        case .destructive: return Palette.red.opacity(0.16 + boost)
        }
    }
}
