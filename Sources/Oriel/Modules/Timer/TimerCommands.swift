import Foundation
import SwiftUI

// Barre de commande : « t 25 » lance un minuteur de 25 min, « t » propose les durées et le Pomodoro.
// Textes dans la table « Command ».

/// Durée tapée : « 25 », « 25 min », « 25m », « 1h », « 1h30 », « 1 h 30 min », « 2 heures ».
enum CommandDuration {
    /// Minutes ; nil si le texte n'est pas une durée, ou sort de 1 min à 24 h (bornes du minuteur simple).
    /// `allowBare` : « 25 » seul est lu comme 25 minutes (après le verbe « t » seulement).
    static func minutes(from text: String, allowBare: Bool) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let number = group(1).flatMap({ Int($0) }) else { return nil }
        let total: Int
        if group(2) != nil {
            let extra = group(3).flatMap { Int($0) } ?? 0
            guard extra < 60 else { return nil }
            total = number * 60 + extra
        } else if group(4) != nil || allowBare {
            total = number
        } else {
            return nil
        }
        return TimerState.simpleRange.contains(TimeInterval(total * 60)) ? total : nil
    }

    // 1 : nombre ; 2 : unité d'heures puis 3 : minutes en plus ; 4 : unité de minutes.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{1,4})\s*(?:(h|hr|hrs|heure|heures|hour|hours)\s*(?:(\d{1,2})\s*(?:m|min|mn|minute|minutes)?)?|(m|min|mn|minute|minutes))?$"#,
        options: .caseInsensitive)
}

extension TimerModule {
    var commandVerb: CommandVerb? { CommandVerb(key: "t", title: L("minuteur", table: "Command")) }

    /// Durées usuelles proposées par « t » seul.
    static let commandPresets = [25, 5, 10]

    func commands(for query: CommandQuery) -> [NotchCommand] {
        // Sans verbe, seule une durée avec son unité (« 25 min ») est adressée au minuteur.
        if let minutes = CommandDuration.minutes(from: query.argument, allowBare: query.verb != nil) {
            return [startCommand(minutes: minutes, score: 1000)]
        }
        guard query.verb != nil else { return [] }
        var commands: [NotchCommand] = []
        if query.argument.isEmpty {
            commands = Self.commandPresets.enumerated().map { startCommand(minutes: $1, score: 900 - $0) }
        }
        let name = L("Pomodoro", table: "Timer")
        if query.argument.isEmpty || FuzzyMatch.score(query.argument, in: name) != nil {
            commands.append(pomodoroCommand(score: 800))
        }
        return commands
    }

    private func startCommand(minutes: Int, score: Int) -> NotchCommand {
        let length = TimerFormat.duration(TimeInterval(minutes * 60))
        let replaces = state.isActive
        let end = TimerFormat.time(Date().addingTimeInterval(TimeInterval(minutes * 60)))
        return NotchCommand(
            id: "timer.start.\(minutes)", symbol: "timer",
            title: String(format: replaces ? L("Remplacer par un minuteur de %@", table: "Command")
                : L("Minuteur de %@", table: "Command"), length),
            detail: replaces ? L("Arrête le minuteur en cours", table: "Command")
                : String(format: L("Démarre tout de suite, fin à %@", table: "Command"), end),
            score: score,
            run: { [weak self] in
                guard let self else { return nil }
                if self.state.isActive { self.stopTimer() }
                self.startSimple(minutes: minutes)
                return nil
            })
    }

    private func pomodoroCommand(score: Int) -> NotchCommand {
        NotchCommand(
            id: "timer.pomodoro", symbol: "arrow.triangle.2.circlepath",
            title: String(format: L("Pomodoro %d / %d", table: "Command"), focusMinutes, shortBreakMinutes),
            detail: state.isActive ? L("Arrête le minuteur en cours", table: "Command")
                : String(format: L("%d cycles, pause longue de %d min", table: "Command"),
                         sessionsBeforeLongBreak, longBreakMinutes),
            tint: Palette.green, score: score,
            run: { [weak self] in
                guard let self else { return nil }
                if self.state.isActive { self.stopTimer() }
                self.setMode(.pomodoro)
                self.startTimer()
                return nil
            })
    }
}
