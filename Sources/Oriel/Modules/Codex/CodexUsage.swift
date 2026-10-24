import Foundation

/// Quota du compte ChatGPT pour la jauge de l'onglet Codex. Une lecture = un processus `codex app-server` de 1 s environ
/// (mesuré : 1,2 s), donc jamais en boucle :
/// - seulement panneau ouvert (`start()` / `stop()` suivent le cycle de vie du module) ;
/// - mise en cache 60 s : ouvrir et fermer le panneau ne relance rien ;
/// - ensuite une relecture toutes les 5 min tant que le panneau reste ouvert, un seul minuteur, arrêté à la fermeture ;
/// - un échec (pas de compte ChatGPT, Codex introuvable) laisse la dernière mesure et attend 15 min.
/// Aucune lecture sans Codex activé et sans le réglage « Afficher le quota ».
final class CodexUsageStore: ObservableObject {
    static let cacheAge: TimeInterval = 60
    static let recheck: TimeInterval = 5 * 60
    static let failureBackoff: TimeInterval = 15 * 60

    @Published private(set) var snapshot: QuotaSnapshot?
    /// Dernière raison d'échec, pour `/state` (jamais affichée : une jauge absente suffit).
    private(set) var lastError: String?

    private let makeService: () -> CodexQuotaService?
    private let now: () -> Date
    private let queue = DispatchQueue(label: AppIdentity.bundleId + ".codex-quota", qos: .utility)
    private var isLoading = false
    private var nextAllowed = Date.distantPast
    /// Change à chaque `forget()` : le résultat d'une lecture lancée avant est jeté.
    private var generation = 0
    private var timer: Timer?

    init(service: @escaping () -> CodexQuotaService? = CodexUsageStore.standardService, now: @escaping () -> Date = Date.init) {
        makeService = service
        self.now = now
    }

    /// L'app Codex (ChatGPT) ou la commande `codex` du Mac, jamais sous XCTest : un test ne lance pas le vrai Codex.
    static func standardService() -> CodexQuotaService? {
        guard NSClassFromString("XCTestCase") == nil, let executable = CodexBinary.find() else { return nil }
        return CodexAppServer(executable: executable, home: CodexHookInstaller.standard.configDirectory)
    }

    var isTimerRunning: Bool { timer != nil }

    /// Panneau ouvert.
    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.recheck, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = Self.recheck / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Panneau fermé : plus de minuteur, la dernière mesure reste affichée dans l'intercalaire (qui en vérifie l'âge).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Onglet ou réglage désactivé : plus de chiffre, plus de lecture en cours qui compte.
    func forget() {
        stop()
        generation += 1
        snapshot = nil
        lastError = nil
        nextAllowed = .distantPast
        isLoading = false
    }

    func refresh() {
        guard !isLoading, now() >= nextAllowed, let service = makeService() else { return }
        isLoading = true
        let started = generation
        queue.async {
            let result = Result { try service.rateLimits() }
            DispatchQueue.main.async { [self] in
                guard started == generation else { return }
                isLoading = false
                switch result {
                case .success(let fresh):
                    snapshot = fresh
                    lastError = nil
                    nextAllowed = now().addingTimeInterval(Self.cacheAge)
                case .failure(let error):
                    lastError = error.localizedDescription
                    nextAllowed = now().addingTimeInterval(Self.failureBackoff)
                }
            }
        }
    }
}
