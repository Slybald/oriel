import Foundation

/// Libellés lisibles pour les outils : « Terminal · npm test », « Édition · App.swift »…
enum ToolDescriber {
    struct Description: Equatable {
        let label: String
        let detail: String?
        /// Le détail est du code (commande, motif) : affiché en monospace.
        let isCode: Bool

        var text: String { detail.map { "\(label) · \($0)" } ?? label }
    }

    static let taskTools: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]

    static func describe(tool: String, input: [String: Any]?) -> Description {
        let input = input ?? [:]
        func text(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func file(_ key: String) -> String? {
            text(key).map { ($0 as NSString).lastPathComponent }
        }

        switch tool {
        case "Bash":
            if let description = text("description") {
                return Description(label: L("Terminal"), detail: firstLine(description), isCode: false)
            }
            return Description(label: L("Terminal"), detail: text("command").map { firstLine($0) }, isCode: true)
        case "BashOutput", "TaskOutput":
            return Description(label: L("Terminal"), detail: L("sortie en arrière-plan"), isCode: false)
        case "KillShell", "KillBash", "TaskStop":
            return Description(label: L("Terminal"), detail: L("arrêt d'un processus"), isCode: false)
        case "Read":
            return Description(label: L("Lecture"), detail: file("file_path"), isCode: true)
        case "Edit", "MultiEdit":
            return Description(label: L("Édition"), detail: file("file_path"), isCode: true)
        case "Write":
            return Description(label: L("Écriture"), detail: file("file_path"), isCode: true)
        case "NotebookEdit":
            return Description(label: L("Édition"), detail: file("notebook_path"), isCode: true)
        case "Grep", "Glob":
            return Description(label: L("Recherche"), detail: text("pattern").map { firstLine($0) }, isCode: true)
        case "WebFetch":
            let host = text("url").flatMap { URL(string: $0)?.host }
            return Description(label: L("Web"), detail: host, isCode: false)
        case "WebSearch":
            return Description(label: L("Recherche web"), detail: text("query").map { firstLine($0) }, isCode: false)
        case "Task", "Agent":
            let detail = text("description") ?? text("subagent_type")
            return Description(label: L("Sous-agent"), detail: detail.map { firstLine($0) }, isCode: false)
        case "TaskCreate":
            return Description(label: L("Tâches"), detail: text("subject").map { firstLine($0) }, isCode: false)
        case _ where taskTools.contains(tool):
            return Description(label: L("Tâches"), detail: nil, isCode: false)
        case "AskUserQuestion":
            return Description(label: L("Question"), detail: question(from: input), isCode: false)
        case "ExitPlanMode":
            return Description(label: L("Plan"), detail: nil, isCode: false)
        case "EnterPlanMode":
            return Description(label: L("Plan"), detail: L("passage en mode plan"), isCode: false)
        case "Skill":
            return Description(label: L("Skill"), detail: text("skill") ?? text("command"), isCode: false)
        case "SlashCommand":
            return Description(label: L("Commande"), detail: text("command"), isCode: true)
        case "ToolSearch":
            return Description(label: L("Outils"), detail: L("chargement"), isCode: false)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                if parts.count >= 3 {
                    let server = parts[1]
                    let name = parts[2...].joined(separator: "__")
                    return Description(label: server, detail: name, isCode: false)
                }
            }
            return Description(label: tool, detail: nil, isCode: false)
        }
    }

    /// Texte de la première question d'un AskUserQuestion.
    static func question(from input: [String: Any]?) -> String? {
        if let questions = input?["questions"] as? [[String: Any]], let first = questions.first {
            let text = (first["question"] as? String) ?? (first["header"] as? String)
            return text.map { firstLine($0, max: 120) }
        }
        return (input?["question"] as? String).map { firstLine($0, max: 120) }
    }

    /// Première ligne utile du plan proposé par ExitPlanMode.
    static func planSummary(from input: [String: Any]?) -> String? {
        (input?["plan"] as? String).flatMap { cleanMarkdown($0, max: 120) }
    }

    // MARK: - Texte

    static func firstLine(_ text: String, max: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return truncate(line, max: max)
    }

    static func truncate(_ text: String, max: Int) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }

    /// Première ligne non vide, débarrassée du markdown (titres, listes, gras, code, liens).
    static func cleanMarkdown(_ text: String, max: Int = 120) -> String? {
        var inFence = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            if line.allSatisfy({ "-*_=|: ".contains($0) }) { continue }   // séparateurs, tableaux

            line = line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#,
                                             with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            for marker in ["**", "__", "`"] {
                line = line.replacingOccurrences(of: marker, with: "")
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return truncate(line, max: max) }
        }
        return nil
    }
}
