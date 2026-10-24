import AppKit
import EventKit
import SwiftUI

// Accès aux calendriers, partagé par l'onglet Lecteur (semaine) et l'onglet Agenda (prochain rendez-vous).

enum CalendarAccess: Equatable {
    case notDetermined
    case denied
    case granted
}

struct MediaEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var color: Color
    /// Lieu tel que saisi dans l'événement (salle, adresse) ; vide si absent.
    var location = ""
    /// Lien de visioconférence reconnu dans l'événement. Le texte vient d'un tiers : il n'est jamais ouvert tout seul.
    var meeting: MeetingLink?
}

struct MediaCalendarInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var source: String
    var color: Color
}

/// Accès aux calendriers : EventKit dans l'app, un double dans les tests. Résultats sur le main thread.
protocol CalendarSource: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess(_ done: @escaping (CalendarAccess) -> Void)
    func calendars(_ done: @escaping ([MediaCalendarInfo]) -> Void)
    /// Événements qui chevauchent [start, end[, triés, sauf ceux des calendriers masqués.
    func events(from start: Date, to end: Date, hidden: Set<String>, _ done: @escaping ([MediaEvent]) -> Void)
    /// Base libérée (arrêt du module) ; recréée à la prochaine demande.
    func release()
}

/// EventKit. Toute la base passe par une file série : `events(matching:)` peut prendre un moment, la notch ne gèle pas.
final class EventKitCalendar: CalendarSource {
    private let queue = DispatchQueue(label: "oriel.media.calendar")
    private var store: EKEventStore?

    private func withStore(_ body: @escaping (EKEventStore) -> Void) {
        queue.async {
            let store = self.store ?? EKEventStore()
            self.store = store
            body(store)
        }
    }

    var access: CalendarAccess { Self.currentAccess }

    private static var currentAccess: CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        default:
            // macOS 14 : « écriture seule » ne permet pas de lire.
            if #available(macOS 14, *) { return status == .fullAccess ? .granted : .denied }
            return .granted
        }
    }

    func requestAccess(_ done: @escaping (CalendarAccess) -> Void) {
        // L'app n'a pas d'icône dans le Dock : sans activation, la demande s'ouvrirait derrière les fenêtres.
        HookSetup.activateApp()
        withStore { store in
            let finish: (Bool, Error?) -> Void = { _, _ in
                DispatchQueue.main.async { done(Self.currentAccess) }
            }
            if #available(macOS 14, *) {
                store.requestFullAccessToEvents(completion: finish)
            } else {
                store.requestAccess(to: .event, completion: finish)
            }
        }
    }

    func calendars(_ done: @escaping ([MediaCalendarInfo]) -> Void) {
        guard access == .granted else { return done([]) }
        withStore { store in
            let list = store.calendars(for: .event)
                .map { MediaCalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "",
                                         color: Self.color($0)) }
                .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
            DispatchQueue.main.async { done(list) }
        }
    }

    func events(from start: Date, to end: Date, hidden: Set<String>, _ done: @escaping ([MediaEvent]) -> Void) {
        guard access == .granted else { return done([]) }
        withStore { store in
            let calendars = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
            var events: [MediaEvent] = []
            if !calendars.isEmpty {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
                events = store.events(matching: predicate).map {
                    MediaEvent(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)",
                               title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay,
                               color: $0.calendar.map(Self.color) ?? .gray, location: $0.location ?? "",
                               meeting: MeetingLink.find(url: $0.url, location: $0.location, notes: $0.notes))
                }
            }
            DispatchQueue.main.async { done(MediaCalendarMath.sorted(events)) }
        }
    }

    func release() {
        queue.async { self.store = nil }
    }

    private static func color(_ calendar: EKCalendar) -> Color {
        calendar.cgColor.map { Color(cgColor: $0) } ?? .gray
    }
}
