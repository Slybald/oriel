import SwiftUI

// Conversation d'une session dans l'onglet Claude : ce que Claude vient de dire (Stop, SubagentStop), ce que tu lui
// as écrit, puis le champ de message — ou, quand on ne peut pas lui écrire d'ici, le bouton qui ouvre la session.
// Textes : table « Claude ».

extension Session {
    /// Où répondre quand la notch ne le peut pas : l'app de la session.
    var replyTarget: String { source == .desktop ? "Claude Desktop" : (hostName ?? "CLI") }
}

// MARK: - Répliques

/// Les dernières répliques de la session, la plus récente en bas.
struct ConversationLog: View {
    let utterances: [Utterance]

    static let visibleCount = 2

    var body: some View {
        if utterances.isEmpty {
            Text("Rien de dit pour l'instant", tableName: "Claude")
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 6)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(utterances.suffix(Self.visibleCount)) { UtteranceBubble(utterance: $0) }
            }
        }
    }
}

/// Une réplique : au plus 4 lignes, un clic la déplie. Le Markdown en ligne (gras, code, liens) est rendu.
struct UtteranceBubble: View {
    let utterance: Utterance

    @State private var expanded = false

    private static let collapsedLines = 4

    private var isYou: Bool { utterance.speaker == .you }
    private var isLong: Bool { RequestCard.isLong(utterance.text) }

    var body: some View {
        VStack(alignment: isYou ? .trailing : .leading, spacing: 2) {
            speaker
            Text(Self.rendered(utterance.text))
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(expanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: isYou ? .trailing : .leading)
                .multilineTextAlignment(isYou ? .trailing : .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(ModuleStyle.shape(ModuleStyle.itemRadius)
                    .fill(isYou ? Palette.accent.opacity(0.18) : Color.white.opacity(0.07)))
                .contentShape(ModuleStyle.shape(ModuleStyle.itemRadius))
                .onTapGesture { if isLong { withAnimation(notchSpring) { expanded.toggle() } } }
                .help(isLong ? utterance.text : "")
            if isLong {
                Text(expanded ? L("Réduire", table: "Claude") : L("Afficher tout", table: "Claude"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: isYou ? .trailing : .leading)
    }

    @ViewBuilder
    private var speaker: some View {
        switch utterance.speaker {
        case .you:
            Text("Toi", tableName: "Claude").speakerStyle(Palette.accent)
        case .claude:
            Text(verbatim: "Claude").speakerStyle(Palette.accent)
        case .agent(let type):
            Text(type.isEmpty ? L("Agent", table: "Claude") : String(format: L("Agent %@", table: "Claude"), type))
                .speakerStyle(Palette.secondary)
        }
    }

    /// Titres sans les dièses, lignes vides retirées (la notch est petite) ; le reste du Markdown en ligne est
    /// interprété, sinon le texte brut.
    static func rendered(_ text: String) -> AttributedString {
        let plain = text.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.map { line -> String in
            let stripped = line.drop { $0 == "#" }
            return stripped.count < line.count ? String(stripped.drop { $0 == " " }) : String(line)
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: plain, options: options)) ?? AttributedString(plain)
    }
}

private extension Text {
    func speakerStyle(_ color: Color) -> some View {
        font(.system(size: 9.5, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 4)
    }
}

// MARK: - Zone conversation

/// Répliques, puis de quoi répondre : le champ de message, ou le bouton qui ouvre la session quand la notch ne peut
/// pas lui écrire, ou l'invitation à activer les réponses.
struct ConversationView: View {
    @ObservedObject var replies: ReplyCenter
    @ObservedObject var drafts: ReplyDrafts
    @ObservedObject var prefs: Preferences
    let session: Session
    let open: () -> Void
    let enable: () -> Void

    private func close() {
        drafts.composing = nil
        NotchKeyboard.release(force: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConversationLog(utterances: session.conversation)
            footer
        }
        .padding(8)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Color.white.opacity(0.07)))
    }

    @ViewBuilder
    private var footer: some View {
        if !prefs.replyFromNotch {
            ReplyActionLine(icon: "bubble.left.and.bubble.right",
                            text: L("Active les réponses pour écrire à Claude d'ici", table: "Claude"),
                            button: L("Activer", table: "Claude"), action: enable, close: close)
        } else if session.phase == .ended {
            ReplyActionLine(icon: "moon.zzz", text: L("Session terminée"), close: close)
        } else if replies.headless.contains(session.id) {
            ReplyActionLine(icon: "arrow.up.forward.app",
                            text: String(format: L("Réponds dans %@", table: "Claude"), session.replyTarget),
                            button: L("Ouvrir", table: "Claude"), action: open, close: close)
        } else {
            MessageComposer(replies: replies, drafts: drafts, session: session, framed: false, open: open)
        }
    }
}

/// Une ligne d'état avec un bouton facultatif (« Ouvrir », « Activer ») et la fermeture de la conversation.
struct ReplyActionLine: View {
    let icon: String
    let text: String
    var button: String?
    var action: () -> Void = {}
    var close: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            ReplyStatusLine(icon: icon, color: Palette.secondary, text: text)
            Spacer(minLength: 4)
            if let button {
                ReplyButton(title: button, style: .primary, action: action)
            }
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Fermer (Échap)", table: "Claude"))
                .accessibilityLabel(L("Fermer (Échap)", table: "Claude"))
            }
        }
    }
}

// MARK: - Activer les réponses

/// En haut de l'onglet tant que « Répondre depuis la notch » est coupé : le dire, en une carte, plutôt que de le
/// cacher dans Réglages › Claude.
struct ReplyPromptCard: View {
    let enable: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.accent)
                Text("Réponds à Claude sans quitter la notch", tableName: "Claude")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
            }
            Text(L("Autorise une action, réponds à une question ou écris à Claude depuis ici. Rien ne part sans ton clic ; "
                   + "le terminal ou Claude Desktop gardent toujours la main.", table: "Claude"))
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ReplyButton(title: L("Plus tard", table: "Claude"), style: .secondary, action: later)
                ReplyButton(title: L("Activer", table: "Claude"), style: .primary, action: enable)
            }
        }
        .padding(10)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Color.white.opacity(0.07)))
        .overlay(ModuleStyle.shape(ModuleStyle.cardRadius).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
    }
}
