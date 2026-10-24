import AppKit
import SwiftUI

// MARK: - Onglet

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Les 3 à 5 derniers mails reçus (expéditeur, objet, début du texte, heure, pastille si non lu) ; un clic ouvre le
/// mail dans Mail, « Répondre » (au survol) ouvre un champ de réponse sous la ligne. Chaque état où Mail n'est pas
/// lisible (fermé, pas autorisé, refusé, sans compte) dit quoi faire, avec le bon bouton.
struct MailPanel: View {
    @ObservedObject var module: MailModule
    /// Rendus PNG : cette ligne s'affiche comme survolée (hors écran, il n'y a pas de pointeur).
    var hoverPreview: String?
    @Environment(\.notchContentMaxHeight) private var contentMaxHeight

    @State private var listHeight: CGFloat = 0

    /// Hauteur d'une ligne avec un début de texte sur deux lignes, et espace entre les lignes.
    private static let rowHeight: CGFloat = 72
    private static let rowSpacing: CGFloat = 3

    var body: some View {
        Group {
            switch module.state {
            case .unknown:
                ModuleEmptyState(symbol: "envelope", title: L("Lecture de Mail…", table: "Mail"), progress: true)
                    .padding(.vertical, 22)
            case .notRunning:
                ModuleEmptyState(
                    symbol: "envelope", title: L("Mail n'est pas ouvert", table: "Mail"),
                    detail: L("Oriel ne lance jamais Mail tout seul. Ouvre-le pour voir tes derniers mails ici.", table: "Mail"),
                    action: ModuleAction(title: L("Ouvrir Mail", table: "Mail"), symbol: "arrow.up.forward.app", run: module.openMail))
                    .padding(.vertical, 12)
            case .needsPermission:
                ModuleEmptyState(
                    symbol: "lock", title: L("Autoriser l'accès à Mail", table: "Mail"),
                    detail: L("Oriel lit tes derniers mails avec AppleScript et n'envoie une réponse que quand tu cliques sur Envoyer. macOS va te demander ton accord ; la lecture reste sur ton Mac.", table: "Mail"),
                    action: ModuleAction(title: L("Autoriser", table: "Mail"), style: .prominent, run: module.authorize))
                    .padding(.vertical, 8)
            case .denied:
                ModuleEmptyState(
                    symbol: "lock.slash", tint: Palette.amber, title: L("Accès à Mail refusé", table: "Mail"),
                    detail: L("Autorise Oriel à contrôler Mail dans Réglages Système › Confidentialité et sécurité › Automatisation.", table: "Mail"),
                    action: ModuleAction(title: L("Ouvrir les Réglages", table: "Mail"), symbol: "gearshape", style: .prominent) {
                        module.openPrivacy(.automation)
                    })
                    .padding(.vertical, 8)
            case .noAccount:
                ModuleEmptyState(
                    symbol: "envelope.badge.shield.half.filled", title: L("Aucun compte dans Mail", table: "Mail"),
                    detail: L("Ajoute un compte (iCloud, Gmail, Outlook…) dans Mail, puis reviens ici.", table: "Mail"),
                    action: ModuleAction(title: L("Ouvrir Mail", table: "Mail"), symbol: "arrow.up.forward.app", run: module.openMail))
                    .padding(.vertical, 12)
            case .failed:
                ModuleEmptyState(
                    symbol: "exclamationmark.triangle", tint: Palette.amber, title: L("Mail ne répond pas", table: "Mail"),
                    detail: L("Il est peut-être occupé. Réessaie dans un instant.", table: "Mail"),
                    action: ModuleAction(title: L("Réessayer", table: "Mail")) { module.refresh() })
                    .padding(.vertical, 12)
            case .ready:
                ready
            }
        }
        .onAppear { module.tabAppeared() }
        .onDisappear { module.tabDisappeared() }
    }

    @ViewBuilder private var ready: some View {
        if !module.showSubjects {
            // Texte coupé dans les réglages : le nombre suffit, et la liste n'est même pas lue.
            if module.unread == 0 {
                ModuleEmptyState(symbol: "checkmark.circle", title: L("Tout est lu", table: "Mail"),
                                 detail: L("Aucun message non lu dans la boîte de réception.", table: "Mail"))
                    .padding(.vertical, 18)
            } else {
                ModuleEmptyState(symbol: "envelope.badge", title: Self.unreadText(module.unread),
                                 action: ModuleAction(title: L("Ouvrir Mail", table: "Mail"), symbol: "arrow.up.forward.app", run: module.openMail))
                    .padding(.vertical, 14)
            }
        } else if !module.listLoaded {
            ModuleEmptyState(symbol: "envelope", title: L("Lecture de Mail…", table: "Mail"), progress: true)
                .padding(.vertical, 22)
        } else if module.messages.isEmpty {
            ModuleEmptyState(symbol: "tray", title: L("Boîte de réception vide", table: "Mail"),
                             detail: L("Aucun message reçu pour l'instant.", table: "Mail"))
                .padding(.vertical, 18)
        } else {
            list
        }
    }

    private var list: some View {
        let count = CGFloat(module.messages.count)
        // Deux lignes de texte si la liste tient dans le panneau, une sinon (sinon on fait défiler).
        let snippetLines = count * Self.rowHeight + (count - 1) * Self.rowSpacing <= contentMaxHeight ? 2 : 1
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Relu chaque minute : « il y a 3 min » reste juste tant que le panneau est ouvert.
                TimelineView(.everyMinute) { context in
                    VStack(spacing: Self.rowSpacing) {
                        ForEach(module.messages) { message in
                            let replying = module.replyTarget?.id == message.id
                            VStack(spacing: 4) {
                                MailRow(message: message, now: context.date, replying: replying,
                                        forcedHover: hoverPreview == message.id, snippetLines: snippetLines,
                                        open: { module.openMessage(message) }, reply: { module.beginReply(message) })
                                if replying {
                                    MailReplyBar(module: module, message: message)
                                        .transition(.opacity)
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    })
                }
            }
            .frame(height: min(listHeight > 0 ? listHeight : count * Self.rowHeight, contentMaxHeight))
            .bottomFade(listHeight > contentMaxHeight + 1)
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            // Le champ s'ouvre sous la ligne : on la ramène à l'écran si elle était en bas de la liste.
            .onChange(of: module.replyTarget?.id) { id in
                if let id { withAnimation(ModuleStyle.hover) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    static func unreadText(_ count: Int) -> String {
        String(format: L(count, one: "%d message non lu", other: "%d messages non lus", table: "Mail"), count)
    }
}

// MARK: - Ligne

private struct MailRow: View {
    let message: MailMessage
    let now: Date
    let replying: Bool
    let forcedHover: Bool
    let snippetLines: Int
    let open: () -> Void
    let reply: () -> Void

    @State private var hovering = false

    private var showsReply: Bool { (hovering || forcedHover) && !replying && !message.id.isEmpty }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(message.isUnread ? Palette.accent : Color.clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6.5)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: message.sender)
                            .font(.system(size: 12.5, weight: message.isUnread ? .semibold : .medium))
                            .foregroundColor(Palette.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        // La place de l'heure est celle du bouton « Répondre » au survol.
                        Text(verbatim: NotesFormat.relative(message.date, now: now))
                            .font(.system(size: 10.5))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                            .opacity(showsReply ? 0 : 1)
                    }
                    .frame(height: 20)
                    Text(verbatim: message.subject.isEmpty ? L("(sans objet)", table: "Mail") : message.subject)
                        .font(.system(size: 11.5, weight: message.isUnread ? .medium : .regular))
                        .foregroundColor(message.isUnread ? Palette.primary.opacity(0.9) : Palette.secondary)
                        .lineLimit(1)
                    if !message.snippet.isEmpty {
                        Text(verbatim: message.snippet)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.secondary.opacity(0.8))
                            .lineLimit(snippetLines)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModuleStyle.shape(ModuleStyle.rowRadius)
                .fill(replying ? Palette.accent.opacity(0.2) : Color.white.opacity(hovering || forcedHover ? 0.1 : 0.05)))
            .contentShape(ModuleStyle.shape(ModuleStyle.rowRadius))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if showsReply {
                ModuleCapsuleButton(title: L("Répondre", table: "Mail"), symbol: "arrowshape.turn.up.left", action: reply)
                    .padding(.top, 3)
                    .padding(.trailing, 6)
            }
        }
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .accessibilityAction(named: L("Répondre", table: "Mail"), reply)
    }
}

// MARK: - Réponse

/// Champ de réponse, Envoyer, Ouvrir dans Mail, puis l'état de l'envoi. Le clavier passe par `NotchKeyboard` (le
/// panneau ne s'active jamais), comme la réponse de Messages. Entrée = Envoyer, Échap = fermer : l'envoi ne part que
/// sur l'un de ces deux gestes de l'utilisateur.
private struct MailReplyBar: View {
    @ObservedObject var module: MailModule
    let message: MailMessage

    @State private var focused = false

    private var canSend: Bool {
        !module.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && module.replyState != .sending
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ClipboardSearchField(text: $module.draft,
                                     placeholder: String(format: L("Répondre à %@…", table: "Mail"), message.sender),
                                     onFocus: { focused = $0 }, onMove: { _ in }, onSubmit: module.sendReply,
                                     onCancel: module.cancelReply)
                    .frame(height: 18)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(ModuleStyle.shape(ModuleStyle.rowRadius).fill(Color.white.opacity(0.08)))
                    .overlay(ModuleStyle.shape(ModuleStyle.rowRadius)
                        .stroke(Palette.accent.opacity(focused ? 0.8 : 0), lineWidth: 1))
                ModuleCapsuleButton(title: L("Envoyer", table: "Mail"), symbol: "paperplane.fill",
                                    style: canSend ? .prominent : .soft, action: module.sendReply)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                ModuleIconButton(symbol: "arrow.up.forward.app", label: L("Continuer dans Mail", table: "Mail"),
                                 action: module.openReplyInMail)
                    .disabled(module.replyState == .sending)
            }
            status
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var status: some View {
        switch module.replyState {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Envoi…", tableName: "Mail")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                Spacer()
            }
        case .sent:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Palette.accent)
                Text("Envoyé", tableName: "Mail").foregroundColor(Palette.secondary)
                Spacer()
            }
            .font(.system(size: 11))
        case .failed(let failure):
            ModuleBanner(symbol: "exclamationmark.triangle.fill", text: Self.message(failure), lines: 3,
                         action: action(for: failure))
        }
    }

    private func action(for failure: MailReplyFailure) -> ModuleAction? {
        switch failure {
        case .notAuthorized:
            return ModuleAction(title: L("Réglages", table: "Mail")) { module.openPrivacy(.automation) }
        case .notRunning:
            return ModuleAction(title: L("Ouvrir Mail", table: "Mail"), run: module.openMail)
        case .notFound:
            return ModuleAction(title: L("Ouvrir le mail", table: "Mail")) { module.openMessage(message) }
        case .timedOut, .failed:
            return nil
        }
    }

    static func message(_ failure: MailReplyFailure) -> String {
        switch failure {
        case .notRunning: return L("Mail n'est pas ouvert. Ouvre-le, puis réessaie : ton texte est gardé.", table: "Mail")
        case .notAuthorized: return L("Autorisation refusée : Oriel ne peut pas piloter Mail.", table: "Mail")
        case .timedOut: return L("Mail n'a pas confirmé l'envoi. Regarde dans Mail si la réponse est partie avant de réessayer.", table: "Mail")
        case .notFound: return L("Ce mail n'est plus parmi les derniers reçus. Ouvre-le dans Mail pour répondre.", table: "Mail")
        case .failed: return L("L'envoi a échoué. Ton texte est gardé.", table: "Mail")
        }
    }
}

// MARK: - En-tête, compact

/// À droite des onglets : relire Mail à la demande (la lecture automatique est lente à dessein).
struct MailRefreshButton: View {
    @ObservedObject var module: MailModule

    var body: some View {
        ModuleIconButton(symbol: "arrow.clockwise", label: L("Actualiser", table: "Mail")) { module.refresh() }
    }
}

/// Une ligne : le nombre de non-lus et l'expéditeur du plus récent non lu (jamais l'objet ni le texte : l'écran
/// compact reste visible en plein écran, en partage d'écran…).
struct MailCompactView: View {
    @ObservedObject var module: MailModule

    var body: some View {
        ModuleSummaryRow {
            ModuleSummaryIcon(symbol: "envelope.fill")
            Text(verbatim: MailPanel.unreadText(module.unread))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Palette.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if module.showSubjects, let latest = module.messages.first(where: \.isUnread) {
                Text(verbatim: latest.sender)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Réglages

/// Réglages › Mail : pastille, texte, nombre de mails, état de l'autorisation.
struct MailSettingsView: View {
    @ObservedObject var module: MailModule

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $module.showBadge) {
                    Text("Pastille de non-lus dans la notch repliée", tableName: "Mail")
                }
                Toggle(isOn: $module.showSubjects) {
                    Text("Afficher les expéditeurs, les objets et le début des messages", tableName: "Mail")
                }
                Picker(selection: $module.recentCount) {
                    ForEach(Array(MailModule.recentRange), id: \.self) { Text(verbatim: "\($0)").tag($0) }
                } label: {
                    Text("Derniers mails affichés", tableName: "Mail")
                }
            } header: {
                Text("Mail", tableName: "Mail")
            } footer: {
                SettingsNote(L("Apple Mail seulement. Oriel ne lance jamais Mail, ne relit les compteurs que tant que Mail est ouvert, et n'enregistre rien ailleurs. Une réponse ne part que sur ton clic sur Envoyer (ou Entrée). Gmail et Outlook ne sont pas lus directement : ajoute-les à Mail.", table: "Mail"))
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: Self.status(module.state)).foregroundColor(.secondary)
                        switch module.state {
                        case .needsPermission:
                            Button { module.authorize() } label: { Text("Autoriser", tableName: "Mail") }
                        case .denied:
                            Button { module.openPrivacy(.automation) } label: { Text("Ouvrir les Réglages", tableName: "Mail") }
                        default:
                            EmptyView()
                        }
                    }
                } label: {
                    Text("Accès à Mail (Automatisation)", tableName: "Mail")
                }
            } header: {
                Text("Autorisations", tableName: "Mail")
            }
        }
    }

    static func status(_ state: MailState) -> String {
        switch state {
        case .unknown: return L("Pas encore vérifié : ouvre l'onglet.", table: "Mail")
        case .notRunning: return L("Mail est fermé", table: "Mail")
        case .needsPermission: return L("Pas demandé", table: "Mail")
        case .denied: return L("Refusé", table: "Mail")
        case .noAccount: return L("Aucun compte dans Mail", table: "Mail")
        case .ready: return L("Autorisé", table: "Mail")
        case .failed: return L("Mail ne répond pas", table: "Mail")
        }
    }
}
