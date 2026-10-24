import AppKit
import Foundation

/// Calculs de dates du calendrier (purs, testés).
enum MediaCalendarMath {
    /// Les 7 jours (début de journée) de la semaine qui contient `day`, selon le premier jour de la semaine local.
    static func week(containing day: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? calendar.startOfDay(for: day)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Journée entière d'abord, puis par heure de début.
    static func sorted(_ events: [MediaEvent]) -> [MediaEvent] {
        events.sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
    }

    /// Événements qui touchent la journée de `day`.
    static func events(_ events: [MediaEvent], on day: Date, calendar: Calendar = .current) -> [MediaEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.start < end && ($0.end > start || ($0.end == $0.start && $0.start >= start)) }
    }

    /// Prochain événement à heure fixe pas encore terminé (en cours compris).
    static func next(_ events: [MediaEvent], after now: Date) -> MediaEvent? {
        events.filter { !$0.isAllDay && $0.end > now }.min { $0.start < $1.start }
    }
}

/// Ouvre Calendrier à une date : AppleScript « view calendar at » (autorisation Automatisation, demandée par
/// macOS au premier usage), sinon simplement l'app. osascript tourne hors du main thread : la fenêtre
/// d'autorisation ne fige pas la notch.
enum CalendarOpener {
    static let bundleIdentifier = "com.apple.iCal"

    /// Le jour est posé champ par champ : une date en texte dépendrait de la langue du Mac.
    static func script(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return """
        set d to current date
        set day of d to 1
        set year of d to \(parts.year ?? 2000)
        set month of d to \(parts.month ?? 1)
        set day of d to \(parts.day ?? 1)
        set time of d to 0
        tell application id "\(bundleIdentifier)"
            activate
            switch view to day view
            view calendar at d
        end tell
        """
    }

    static func open(at date: Date) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script(for: date)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async(execute: openApp)
        }
        do { try process.run() } catch { openApp() }
    }

    static func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
