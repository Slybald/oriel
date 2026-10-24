import AppKit
import UserNotifications

// Ce que le minuteur demande au système : une notification programmée pour la fin, un son. Rien n'est touché avant
// le premier minuteur lancé ; les tests injectent des doubles.

enum NotificationAccess: Equatable {
    case notDetermined
    case granted
    case denied
}

protocol TimerNotifier: AnyObject {
    /// État de l'autorisation, sans jamais la demander.
    func access(_ completion: @escaping (NotificationAccess) -> Void)
    /// Affiche la demande du système (une seule fois, au premier minuteur).
    func request(_ completion: @escaping (Bool) -> Void)
    /// Notification pour `date` : le système la remet même si l'app est endormie ou fermée. Même `id` = remplace.
    func schedule(id: String, title: String, body: String, at date: Date)
    func cancel(id: String)
}

/// `UNUserNotificationCenter`, créé à la première utilisation. Hors d'une app (`swift run`, tests) il n'y a pas de
/// bundle et le centre de notifications plante : le module se comporte alors comme si l'autorisation était refusée.
final class SystemTimerNotifier: NSObject, TimerNotifier, UNUserNotificationCenterDelegate {
    private var cached: UNUserNotificationCenter?

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        if cached == nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            cached = center
        }
        return cached
    }

    func access(_ completion: @escaping (NotificationAccess) -> Void) {
        guard let center else { return completion(.denied) }
        center.getNotificationSettings { settings in
            let access: NotificationAccess
            switch settings.authorizationStatus {
            case .notDetermined: access = .notDetermined
            case .denied: access = .denied
            default: access = .granted
            }
            DispatchQueue.main.async { completion(access) }
        }
    }

    func request(_ completion: @escaping (Bool) -> Void) {
        guard let center else { return completion(false) }
        // Pas de `.sound` : le son de fin est celui du réglage, joué par l'app.
        center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func schedule(id: String, title: String, body: String, at date: Date) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        guard date.timeIntervalSinceNow > 1 else { return }
        // Date absolue (et non un délai) : la veille de la machine ne la décale pas.
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(id: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// L'app est « au premier plan » dès qu'une de ses fenêtres est active : la bannière s'affiche quand même.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

enum TimerSound {
    /// Sons fournis par macOS (/System/Library/Sounds).
    static let names = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                        "Sosumi", "Submarine", "Tink"]
    static let defaultName = "Glass"

    /// Garde le son en vie jusqu'au suivant : un `NSSound` libéré s'arrête.
    private static var current: NSSound?

    /// `name` vide : aucun son. Un nom inconnu reste silencieux.
    static func play(_ name: String) {
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        current?.stop()
        current = sound
        sound.play()
    }
}
