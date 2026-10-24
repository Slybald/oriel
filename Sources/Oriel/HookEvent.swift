import Foundation

/// En-têtes de contexte ajoutés par le script de hook (variables d'environnement du hook).
struct HookHeaders {
    var ppid: pid_t?
    var termProgram: String?
    var bundleId: String?
    var entrypoint: String?
    var taskListId: String?
    var configDir: String?
    /// Identifiant de la session côté Claude Desktop (`local_…`), absent en CLI.
    var hostSessionId: String?

    /// Même règle que le gestionnaire `claude://code/continue?session=` de Claude Desktop.
    static func isDesktopSessionId(_ id: String) -> Bool {
        id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
    }

    init(_ headers: [String: String] = [:]) {
        func value(_ key: String) -> String? {
            guard let raw = headers[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        ppid = (value("x-claude-ppid") ?? value("x-codex-ppid")).flatMap { pid_t($0) }
        termProgram = value("x-term-program")
        bundleId = value("x-bundle-id")
        entrypoint = value("x-entrypoint")
        taskListId = value("x-task-list-id")
        configDir = value("x-config-dir")
        hostSessionId = value("x-host-session-id").flatMap { Self.isDesktopSessionId($0) ? $0 : nil }
    }
}

/// Événement de hook Claude Code.
/// Tout est optionnel et lu à la demande dans le JSON brut : un champ absent ou d'un type inattendu
/// donne `nil`, jamais un plantage.
struct HookEvent {
    let raw: [String: Any]
    let headers: HookHeaders

    init?(data: Data, headers: HookHeaders = HookHeaders()) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        self.init(raw: dict, headers: headers)
    }

    init(raw: [String: Any], headers: HookHeaders = HookHeaders()) {
        self.raw = raw
        self.headers = headers
    }

    // MARK: - Champs communs

    var name: String { string("hook_event_name") ?? "" }
    var sessionId: String? { string("session_id") }
    var transcriptPath: String? { string("transcript_path") }
    var cwd: String? { string("cwd") }
    var permissionMode: String? { string("permission_mode") }
    var agentId: String? { string("agent_id") }
    var agentType: String? { string("agent_type") }
    /// Agents internes (suggestion de prompt, compaction) : `agent_type` vide, SubagentStop sans SubagentStart.
    var isInternalAgent: Bool { (raw["agent_type"] as? String)?.isEmpty ?? false }

    // MARK: - Champs par événement

    /// UserPromptSubmit
    var prompt: String? { string("prompt") }
    /// Le résultat d'un agent d'arrière-plan revient comme un faux prompt `<task-notification>…`.
    var isTaskNotification: Bool { prompt?.hasPrefix("<task-notification>") ?? false }
    /// Message envoyé depuis la notch (hook `asyncRewake`) : il revient aussi en `<task-notification>`, avec notre
    /// résumé, le texte venant après `rewakeMessage`. Chaîne vide si le texte est introuvable. Les textes d'avant le
    /// renommage comptent aussi (session ouverte avant la mise à jour).
    var notchMessage: String? {
        guard isTaskNotification, let prompt,
              let marker = [(HookInstaller.rewakeSummary, HookInstaller.rewakeMessage),
                            (HookInstaller.legacyRewakeSummary, HookInstaller.legacyRewakeMessage)]
                .first(where: { prompt.contains("<summary>\($0.0)</summary>") })?.1 else { return nil }
        guard let start = prompt.range(of: marker) else { return "" }
        var text = prompt[start.upperBound...]
        if let end = text.range(of: "</system-reminder>") { text = text[..<end.lowerBound] }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Stop, SubagentStop, StopFailure
    var lastAssistantMessage: String? { string("last_assistant_message") }
    /// SessionStart : startup / resume / clear / compact
    var source: String? { string("source") }
    /// Absent des payloads observés (2.1.299) ; le titre vient de la ligne `ai-title` du transcript.
    var sessionTitle: String? { string("session_title") }
    var model: String? {
        if let name = string("model") { return name }
        if let model = raw["model"] as? [String: Any] {
            return (model["display_name"] as? String) ?? (model["id"] as? String)
        }
        return nil
    }

    /// PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest
    var toolName: String? { string("tool_name") }
    var toolInput: [String: Any]? { raw["tool_input"] as? [String: Any] }
    var toolResponse: Any? { raw["tool_response"] }
    var toolUseId: String? { string("tool_use_id") }

    /// Notification
    var message: String? { string("message") }
    var title: String? { string("title") }
    var notificationType: String? { string("notification_type") }

    /// PostToolUseFailure
    var isInterrupt: Bool { (raw["is_interrupt"] as? Bool) ?? false }

    /// PostToolUseFailure (« Exit code 1\n… »), StopFailure (code court : « model_not_found »)
    var errorText: String? {
        for key in ["error", "error_type", "error_message"] {
            if let text = string(key) { return text }
            if let dict = raw[key] as? [String: Any] {
                if let text = (dict["type"] as? String) ?? (dict["message"] as? String) { return text }
            }
        }
        return nil
    }

    /// SessionEnd
    var reason: String? { string("reason") }
    /// PreCompact, PostCompact
    var trigger: String? { string("trigger") }

    /// TaskCreated, TaskCompleted
    var taskId: String? { string("task_id") }
    var taskSubject: String? { string("task_subject") }

    // MARK: - Lecture tolérante

    func string(_ keys: String...) -> String? {
        for key in keys {
            if let text = raw[key] as? String, !text.isEmpty { return text }
            if let number = raw[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }
}
