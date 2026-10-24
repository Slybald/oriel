import Foundation

// Données du module Codex : phases d'une session, ce que Codex est en train de faire, processus qui l'héberge.
// Rien ici ne touche le Mac : tout se teste avec de faux événements.

enum CodexPhase: Equatable {
    case ready
    case working
    case waitingApproval
    case done
    case ended

    var needsAttention: Bool { self == .waitingApproval }
}

/// Ce que Codex fait (outil en cours, approbation demandée) : une étiquette et le détail à montrer.
struct CodexToolText: Equatable {
    let label: String
    let detail: String?
    let isCode: Bool
}

enum CodexTools {
    static let maxDetail = 600

    /// `tool_name` et `tool_input` d'un hook Codex : `Bash` (commande), `apply_patch` (le patch est dans
    /// `command`), `mcp__serveur__outil`, ou un autre outil local.
    static func describe(name: String, input: [String: Any]?) -> CodexToolText {
        switch name {
        case "Bash":
            let command = (input?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexToolText(label: L("Terminal", table: "Codex"), detail: command.flatMap(clipped), isCode: true)
        case "apply_patch":
            let files = patchedFiles((input?["command"] as? String) ?? "")
            let detail = files.first.map { files.count > 1 ? "\($0) +\(files.count - 1)" : $0 }
            return CodexToolText(label: L("Modification de fichiers", table: "Codex"), detail: detail, isCode: false)
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 {
                    return CodexToolText(label: parts[0], detail: parts.dropFirst().joined(separator: " "), isCode: false)
                }
            }
            return CodexToolText(label: name, detail: nil, isCode: false)
        }
    }

    /// Fichiers du patch (`*** Add File: chemin`, `*** Update File:`, `*** Delete File:`), nom de fichier seul.
    static func patchedFiles(_ patch: String) -> [String] {
        patch.split(separator: "\n").compactMap { line in
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return (String(line.dropFirst(prefix.count)) as NSString).lastPathComponent
            }
            return nil
        }
    }

    /// Texte de la carte : borné, la fin d'une commande très longue n'est pas montrée (la carte le dit).
    static func clipped(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return text.count > maxDetail ? String(text.prefix(maxDetail)) + "…" : text
    }
}

struct CodexSession: Identifiable, Equatable {
    let id: String
    var cwd: String?
    var projectName: String
    var model: String?
    /// App qui héberge Codex (terminal, éditeur, app Codex) ; nil si inconnue.
    var hostName: String?
    var hostBundleId: String?
    var pid: pid_t?
    var pidStart: TimeInterval?

    var phase: CodexPhase = .ready
    var inTurn = false
    var turnStart: Date?
    var lastTurnDuration: TimeInterval?
    var lastActivity = Date()
    var lastPrompt: String?
    var lastMessage: String?
    var currentTool: CodexToolText?
    var attention: CodexToolText?
    /// Début de l'attente d'une approbation (voir `CodexStore.reorderWindow`).
    var waitingSince: Date?
    var toolCount = 0
    var doneFlashUntil: Date?
    var endedAt: Date?

    init(id: String, cwd: String?) {
        self.id = id
        self.cwd = cwd
        projectName = cwd.map { ($0 as NSString).lastPathComponent } ?? String(id.prefix(8))
    }

    var isDoneFlashing: Bool { (doneFlashUntil ?? .distantPast) > Date() }
    /// « Terminal », « VS Code »… ou « Codex » quand on ne sait pas où il tourne.
    var sourceLabel: String { hostName ?? "Codex" }
}

/// Ce qu'on sait du processus Codex qui a déclenché un hook.
struct CodexContext: Equatable {
    var pid: pid_t?
    var start: TimeInterval?
    var hostName: String?
    var hostBundleId: String?
}
