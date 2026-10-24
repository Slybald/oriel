import SwiftUI

/// Touche affichée dans un bouton de carte : « ⌃⌥Y ».
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.black.opacity(0.28)))
    }
}

/// « 1 sur 3 » : rang de la demande qui a les touches, quand d'autres attendent derrière elle.
struct ApprovalRank: View {
    @ObservedObject var keys: ApprovalQueue
    let id: UUID

    var body: some View {
        if keys.keyedId == id, keys.count > 1 {
            Spacer(minLength: 4)
            Text(verbatim: String(format: L("1 sur %d", table: "Claude"), keys.count))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Palette.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Réglage commun à Claude et à Codex (Réglages › Claude et › Codex) : approuver au clavier.
struct ApprovalKeysSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Section {
            Toggle(L("Approuver au clavier", table: "Claude"), isOn: $prefs.approveByKeyboard)
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                SettingsNote(L("⌃⌥Y autorise et ⌃⌥N refuse la plus ancienne demande, Claude et Codex ensemble. "
                               + "Une touche ne décide que si sa carte est ouverte dans la notch depuis plus d'une seconde ; "
                               + "sinon le premier appui montre la carte.", table: "Claude"))
                SettingsNote(L("Ces touches ne sont prises que tant qu'une demande attend. Une demande à la fois, "
                               + "jamais de « toujours autoriser ».", table: "Claude"))
            }
        }
    }
}
