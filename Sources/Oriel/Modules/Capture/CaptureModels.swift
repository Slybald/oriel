import Foundation

/// Un appareil de capture et son état « en marche quelque part » (une app s'en sert), lu sans jamais l'ouvrir.
struct CaptureDevice: Equatable {
    enum Kind: Equatable { case microphone, camera }
    /// Identifiant du système, préfixé par le type : un micro et une caméra peuvent avoir le même numéro.
    let id: String
    let name: String
    let kind: Kind
    let isRunning: Bool
}

/// Ce que montre l'intercalaire : les appareils en marche. Aucun nom d'app : au niveau de l'appareil, le système dit
/// « en marche quelque part », pas qui s'en sert (les objets « processus » de Core Audio existent à partir de
/// macOS 14.2, ne couvrent pas la caméra et ne sont pas essayables ici). On affiche le nom de l'appareil, jamais
/// celui d'une app devinée.
struct CaptureState: Equatable {
    var active: [CaptureDevice] = []

    var microphones: [CaptureDevice] { active.filter { $0.kind == .microphone } }
    var cameras: [CaptureDevice] { active.filter { $0.kind == .camera } }
    var isEmpty: Bool { active.isEmpty }
}

enum CaptureRules {
    /// Délai avant d'allumer l'intercalaire à partir de rien : une app qui ouvre le micro une demi-seconde (test,
    /// changement d'appareil par défaut) ne fait pas clignoter la notch. Extinction et changements d'un intercalaire
    /// déjà visible (un autre micro, la caméra en plus) sont immédiats.
    static let showDelay: TimeInterval = 0.8

    /// Les appareils en marche, micros d'abord puis caméras, par nom.
    static func state(_ devices: [CaptureDevice]) -> CaptureState {
        let running = devices.filter { $0.isRunning }
        let order: (CaptureDevice, CaptureDevice) -> Bool = {
            ($0.kind == .microphone ? 0 : 1, $0.name, $0.id) < ($1.kind == .microphone ? 0 : 1, $1.name, $1.id)
        }
        return CaptureState(active: running.sorted(by: order))
    }

    /// Un micro compte s'il a des entrées et AUCUNE sortie : sur un appareil entrée + sortie (casque, interface audio,
    /// pilote virtuel), « en marche » dit aussi bien « on écoute de la musique » que « on parle », et le système ne
    /// permet pas de les distinguer à ce niveau. On préfère manquer un casque que dire « micro actif » à tort.
    static func countsAsMicrophone(inputStreams: Int, outputStreams: Int) -> Bool {
        inputStreams > 0 && outputStreams == 0
    }

    /// Écouteurs à poser et à retirer quand la liste des appareils change (branchement, débranchement).
    static func listenerChanges(current: Set<String>, wanted: Set<String>) -> (add: Set<String>, remove: Set<String>) {
        (wanted.subtracting(current), current.subtracting(wanted))
    }
}

/// Ce que le module lit : chaque changement renvoie la liste complète des appareils. L'implémentation réelle
/// (`SystemCaptureSource`) pose des écouteurs Core Audio et Core Media I/O ; les tests injectent une source à la main.
protocol CaptureSource: AnyObject {
    /// Pose les écouteurs et appelle `onChange` (file principale) avec la liste initiale, puis à chaque changement.
    func start(_ onChange: @escaping ([CaptureDevice]) -> Void)
    /// Retire tous les écouteurs. Sans effet si la source est arrêtée.
    func stop()
}
