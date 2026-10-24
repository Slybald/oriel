import SwiftUI

/// Carte d'un intercalaire posé par un script : son détail, sa provenance (« via build.sh ») et au plus deux boutons,
/// ouvrir l'app désignée et retirer l'intercalaire. Jamais « Autoriser » ni « Refuser » : rien ne mime Claude ou Codex.
struct ExternalEarDetail: View {
    let ear: ExternalEar
    let api: LocalAPI
    @Environment(\.notchContentWidth) private var width

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !ear.detail.isEmpty {
                Text(verbatim: ear.detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .semibold))
                Text(verbatim: String(format: L("via %@", table: "API"), ear.client))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let name = ear.appName {
                    // Le nom seul : la flèche dit « ouvrir », la place manque dans la carte.
                    let open = String(format: L("Ouvrir %@", table: "API"), name)
                    ModuleCapsuleButton(title: name, symbol: "arrow.up.forward.app") { api.openApp(of: ear) }
                        .help(open)
                        .accessibilityLabel(open)
                }
                ModuleIconButton(symbol: "xmark", label: L("Retirer", table: "API"), box: 20, size: 10) {
                    api.remove(ear.id)
                }
            }
            .foregroundColor(Palette.secondary)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// Réglages › Scripts : l'API locale (coupée par défaut), la commande `notch`, les derniers programmes appelants.
struct LocalAPISettings: View {
    @ObservedObject var api: LocalAPI
    var bundled: URL? = NotchCLI.bundled
    var destination: URL = NotchCLI.standardDestination

    @State private var command: NotchCLI.Status = .unavailable
    @State private var failure: String?

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $api.isEnabled) {
                    Text("Autoriser les scripts de ce Mac à poser des intercalaires", tableName: "API")
                }
            } header: {
                Text("API locale", tableName: "API")
            } footer: {
                SettingsNote(L("Coupée par défaut. Seuls les programmes de ton compte qui lisent son jeton (un fichier réservé à ton compte, renouvelé à chaque lancement) peuvent l'appeler, jamais une page web. Un intercalaire ne lance rien : un texte court, une icône de la liste et, au plus, un bouton qui ouvre une app.", table: "API"))
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: Self.label(command)).foregroundColor(.secondary)
                        switch command {
                        case .notInstalled:
                            Button { run { try NotchCLI.install(bundled: bundled, destination: destination) } } label: {
                                Text("Installer", tableName: "API")
                            }
                        case .outdated, .installed:
                            if command == .outdated {
                                Button { run { try NotchCLI.install(bundled: bundled, destination: destination) } } label: {
                                    Text("Mettre à jour", tableName: "API")
                                }
                            }
                            Button { run { try NotchCLI.remove(destination: destination) } } label: {
                                Text("Retirer", tableName: "API")
                            }
                        case .foreign, .unavailable:
                            EmptyView()
                        }
                    }
                } label: {
                    Text(verbatim: "~/.local/bin/notch").font(.system(size: 12, design: .monospaced))
                }
                Text(verbatim: String(format: "notch show --title \"%@\" --ttl 30\nnotch run -- make test",
                                      L("Build fini", table: "API")))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Commande notch", tableName: "API")
            } footer: {
                SettingsNote(failure ?? L("Installée seulement sur ton clic, jamais par-dessus un autre programme. Si le terminal ne la trouve pas, ajoute ~/.local/bin à ton PATH. Toutes les options : docs/API.md.", table: "API"))
            }
            Section {
                if api.clients.isEmpty {
                    Text("Aucun pour l'instant", tableName: "API").foregroundColor(.secondary)
                }
                ForEach(api.clients) { client in
                    LabeledContent {
                        Text(verbatim: String(format: L(client.count, one: "%@ · %d appel", other: "%@ · %d appels",
                                                        table: "API"),
                                              Self.time.string(from: client.lastSeen), client.count))
                    } label: {
                        Text(verbatim: client.name)
                    }
                }
            } header: {
                Text("Derniers clients", tableName: "API")
            } footer: {
                SettingsNote(L("Le nom que chaque programme se donne, gardé en mémoire jusqu'à la fermeture de l'app.", table: "API"))
            }
        }
        .onAppear { command = NotchCLI.status(bundled: bundled, destination: destination) }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        command = NotchCLI.status(bundled: bundled, destination: destination)
    }

    static func label(_ status: NotchCLI.Status) -> String {
        switch status {
        case .unavailable: return L("Pas livrée avec cette copie de l'app", table: "API")
        case .notInstalled: return L("Pas installée", table: "API")
        case .installed: return L("Installée", table: "API")
        case .outdated: return L("Ancienne version", table: "API")
        case .foreign: return L("Un autre programme porte ce nom", table: "API")
        }
    }
}
