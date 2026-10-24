import AppKit
import SwiftUI

// MARK: - Onglet

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Les conversations récentes, la plus récente en haut. Un clic ouvre la zone de réponse sous la ligne.
/// Sans accès à la base, un état dit pourquoi et mène au bon volet de Réglages Système.
struct MessagesPanel: View {
    @ObservedObject var module: MessagesModule
    @Environment(\.notchContentMaxHeight) private var contentMaxHeight

    @State private var listHeight: CGFloat = 0

    var body: some View {
        Group {
            switch module.access {
            case .unknown:
                ModuleEmptyState(symbol: "message", title: L("Lecture des conversations…", table: "Messages"), progress: true)
                    .padding(.vertical, 22)
            case .needsFullDiskAccess:
                ModuleEmptyState(
                    symbol: "lock.shield", tint: Palette.amber,
                    title: L("Accès complet au disque requis", table: "Messages"),
                    detail: L("Messages garde ses conversations dans un fichier protégé. Autorise Oriel dans Réglages Système › Confidentialité et sécurité › Accès complet au disque, puis relance l'app. Tout reste sur ton Mac.", table: "Messages"),
                    action: ModuleAction(title: L("Ouvrir les Réglages", table: "Messages"), symbol: "gearshape", style: .prominent) {
                        module.openPrivacy(.fullDiskAccess)
                    })
                    .padding(.vertical, 8)
            case .noDatabase:
                ModuleEmptyState(
                    symbol: "message", title: L("Messages n'est pas configuré", table: "Messages"),
                    detail: L("Ouvre l'app Messages et connecte-toi avec ton identifiant Apple, puis reviens ici.", table: "Messages"),
                    action: ModuleAction(title: L("Ouvrir Messages", table: "Messages"), symbol: "arrow.up.forward.app", run: module.openMessagesApp))
                    .padding(.vertical, 14)
            case .unsupported:
                ModuleEmptyState(
                    symbol: "exclamationmark.triangle", tint: Palette.amber,
                    title: L("Format de Messages non reconnu", table: "Messages"),
                    detail: L("Cette version de macOS range les conversations autrement : Oriel ne peut pas les lire pour l'instant.", table: "Messages"))
                    .padding(.vertical, 14)
            case .ready:
                ready
            }
        }
        .animation(notchSpring, value: module.composing)
        .onAppear { module.tabAppeared() }
    }

    // MARK: Prêt

    private var ready: some View {
        VStack(spacing: 6) {
            if let banner = contactsBanner { banner }
            if module.threads.isEmpty {
                ModuleEmptyState(symbol: "message", title: L("Aucune conversation récente", table: "Messages"),
                                 detail: L("Les nouveaux messages apparaissent ici.", table: "Messages"))
                    .padding(.vertical, 18)
            } else {
                list
            }
        }
    }

    private var contactsBanner: ModuleBanner? {
        guard !module.contactsHintDismissed else { return nil }
        let dismiss = (label: L("Ignorer", table: "Messages"), run: { module.contactsHintDismissed = true })
        switch module.contactsAccess {
        case .notDetermined:
            return ModuleBanner(symbol: "person.crop.circle", tone: .neutral,
                                text: L("Afficher les noms de tes contacts ?", table: "Messages"),
                                action: ModuleAction(title: L("Autoriser", table: "Messages"), run: module.requestContacts),
                                dismiss: dismiss)
        case .denied:
            return ModuleBanner(symbol: "person.crop.circle.badge.exclamationmark", tone: .neutral,
                                text: L("Contacts refusés : on voit les numéros.", table: "Messages"),
                                action: ModuleAction(title: L("Réglages", table: "Messages")) { module.openPrivacy(.contacts) },
                                dismiss: dismiss)
        case .granted:
            return nil
        }
    }

    private var listMaxHeight: CGFloat {
        max(120, contentMaxHeight - (module.contactsHintDismissed || module.contactsAccess == .granted ? 0 : ModuleBanner.minHeight + 6))
    }

    private var list: some View {
        let estimate = CGFloat(module.threads.count) * 44
        return ScrollView(.vertical, showsIndicators: false) {
            // Relu chaque minute : « il y a 3 min » reste juste tant que le panneau est ouvert.
            TimelineView(.everyMinute) { context in
                VStack(spacing: 3) {
                    ForEach(module.threads) { thread in
                        VStack(spacing: 4) {
                            MessageRow(thread: thread, now: context.date, selected: module.composing == thread.id)
                                .onTapGesture { module.select(thread.id) }
                            if module.composing == thread.id {
                                MessageReplyBar(module: module, thread: thread)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                })
            }
        }
        .frame(height: min(listHeight > 0 ? listHeight : estimate, listMaxHeight))
        .bottomFade(listHeight > listMaxHeight + 1)
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
    }
}

// MARK: - Ligne

private struct MessageRow: View {
    let thread: MessageThread
    let now: Date
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.unread > 0 ? Palette.accent : Color.clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if thread.isGroup {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Palette.secondary)
                    }
                    Text(verbatim: thread.title)
                        .font(.system(size: 12.5, weight: thread.unread > 0 ? .semibold : .medium))
                        .foregroundColor(Palette.primary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: NotesFormat.relative(thread.date, now: now))
                        .font(.system(size: 10.5))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                if !thread.snippet.isEmpty {
                    Text(verbatim: thread.snippet)
                        .font(.system(size: 11.5))
                        .foregroundColor(thread.unread > 0 ? Palette.primary.opacity(0.85) : Palette.secondary)
                        .lineLimit(1)
                }
            }
            if thread.unread > 1 {
                Text(verbatim: thread.unread > 99 ? "99+" : String(thread.unread))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Palette.accent.onFill)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(Capsule().fill(Palette.accent))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(ModuleStyle.shape(ModuleStyle.rowRadius)
            .fill(selected ? Palette.accent.opacity(0.2) : Color.white.opacity(hovering ? 0.1 : 0.05)))
        .contentShape(ModuleStyle.shape(ModuleStyle.rowRadius))
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Réponse rapide

/// Champ de réponse, Envoyer, Ouvrir dans Messages, puis l'état de l'envoi. Le clavier passe par `NotchKeyboard`
/// (le panneau ne s'active jamais), comme la recherche du presse-papiers.
private struct MessageReplyBar: View {
    @ObservedObject var module: MessagesModule
    let thread: MessageThread

    @State private var focused = false

    private var canSend: Bool {
        !module.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && module.sendState != .sending
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ClipboardSearchField(text: $module.draft, placeholder: L("Répondre…", table: "Messages"),
                                     onFocus: { focused = $0 }, onMove: { _ in }, onSubmit: module.sendDraft,
                                     onCancel: { module.select(nil) })
                    .frame(height: 18)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(ModuleStyle.shape(ModuleStyle.rowRadius).fill(Color.white.opacity(0.08)))
                    .overlay(ModuleStyle.shape(ModuleStyle.rowRadius)
                        .stroke(Palette.accent.opacity(focused ? 0.8 : 0), lineWidth: 1))
                ModuleIconButton(symbol: "paperplane.fill", label: L("Envoyer", table: "Messages"),
                                 tint: canSend ? Palette.accent : Color.white.opacity(0.3), action: module.sendDraft)
                    .disabled(!canSend)
                ModuleIconButton(symbol: "arrow.up.forward.app", label: L("Ouvrir dans Messages", table: "Messages")) {
                    module.openConversation(thread)
                }
            }
            status
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var status: some View {
        switch module.sendState {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Envoi…", tableName: "Messages")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                Spacer()
            }
        case .sent:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Palette.accent)
                Text("Envoyé", tableName: "Messages").foregroundColor(Palette.secondary)
                Spacer()
            }
            .font(.system(size: 11))
        case .failed(let failure):
            ModuleBanner(symbol: "exclamationmark.triangle.fill", text: Self.message(failure), lines: 2,
                         action: failure == .notAuthorized
                             ? ModuleAction(title: L("Réglages", table: "Messages")) { module.openPrivacy(.automation) }
                             : ModuleAction(title: L("Ouvrir Messages", table: "Messages"), run: module.openMessagesApp))
        }
    }

    static func message(_ failure: AppleScriptFailure) -> String {
        switch failure {
        case .notAuthorized: return L("Autorisation refusée : Oriel ne peut pas piloter Messages.", table: "Messages")
        case .timedOut: return L("Messages ne répond pas.", table: "Messages")
        case .failed: return L("L'envoi a échoué.", table: "Messages")
        }
    }
}

// MARK: - Mode compact

/// Une ligne : le nombre de non-lus et la conversation la plus récente. Jamais le texte des messages : l'écran
/// compact reste visible en plein écran, en partage d'écran…
struct MessagesCompactView: View {
    @ObservedObject var module: MessagesModule

    var body: some View {
        ModuleSummaryRow {
            ModuleSummaryIcon(symbol: "message.fill")
            Text(verbatim: String(format: L(module.unread, one: "%d message non lu", other: "%d messages non lus",
                                            table: "Messages"), module.unread))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Palette.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let latest = module.threads.first(where: { $0.unread > 0 }) {
                Text(verbatim: latest.title)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Réglages

/// Réglages › Messages : pastille, texte, état des autorisations.
struct MessagesSettingsView: View {
    @ObservedObject var module: MessagesModule

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $module.showBadge) {
                    Text("Pastille de non-lus dans la notch repliée", tableName: "Messages")
                }
                Toggle(isOn: $module.showText) {
                    Text("Afficher le texte des messages", tableName: "Messages")
                }
            } header: {
                Text("Messages", tableName: "Messages")
            } footer: {
                SettingsNote(L("Lecture seule de la base de Messages sur ce Mac. Rien n'est enregistré ni envoyé ailleurs.", table: "Messages"))
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: Self.status(module.access)).foregroundColor(.secondary)
                        if module.access == .needsFullDiskAccess {
                            Button { module.openPrivacy(.fullDiskAccess) } label: {
                                Text("Ouvrir les Réglages", tableName: "Messages")
                            }
                        }
                    }
                } label: {
                    Text("Conversations (Accès complet au disque)", tableName: "Messages")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: Self.status(module.contactsAccess)).foregroundColor(.secondary)
                        switch module.contactsAccess {
                        case .notDetermined:
                            Button { module.requestContacts() } label: { Text("Autoriser", tableName: "Messages") }
                        case .denied:
                            Button { module.openPrivacy(.contacts) } label: { Text("Ouvrir les Réglages", tableName: "Messages") }
                        case .granted:
                            EmptyView()
                        }
                    }
                } label: {
                    Text("Noms des contacts", tableName: "Messages")
                }
            } header: {
                Text("Autorisations", tableName: "Messages")
            } footer: {
                SettingsNote(L("L'envoi d'une réponse demande l'autorisation « Automatisation » de Messages, posée par macOS au premier envoi.", table: "Messages"))
            }
        }
        .onAppear { module.refreshContactsAccess() }
    }

    static func status(_ access: MessagesAccess) -> String {
        switch access {
        case .unknown: return L("Pas encore vérifié : ouvre l'onglet.", table: "Messages")
        case .ready: return L("Autorisé", table: "Messages")
        case .needsFullDiskAccess: return L("Accès requis", table: "Messages")
        case .noDatabase: return L("Messages n'est pas configuré", table: "Messages")
        case .unsupported: return L("Format non reconnu", table: "Messages")
        }
    }

    static func status(_ access: ContactsAccess) -> String {
        switch access {
        case .notDetermined: return L("Pas demandé", table: "Messages")
        case .denied: return L("Refusé", table: "Messages")
        case .granted: return L("Autorisé", table: "Messages")
        }
    }
}
