import AppKit
import ImageIO

/// Morceau en cours, tel que le décrit mediaremote-adapter (`stream --micros`).
struct NowPlaying: Equatable {
    /// App qui publie la lecture (pour un lecteur web : le navigateur).
    var bundleIdentifier: String
    var appName: String?
    var title: String
    var artist: String?
    var isPlaying: Bool
    var duration: TimeInterval?
    /// Position à `timestamp` : la position courante s'en déduit sans relancer l'adaptateur.
    var elapsed: TimeInterval?
    var timestamp: Date?
    var rate: Double = 1

    /// Position à `date`, bornée par la durée.
    func position(at date: Date) -> TimeInterval? {
        guard var value = elapsed else { return nil }
        if isPlaying, let timestamp { value += date.timeIntervalSince(timestamp) * rate }
        return min(max(0, value), duration ?? .infinity)
    }

    /// Avance rapide possible : durée connue.
    var canSeek: Bool { (duration ?? 0) > 0 }
}

/// État reconstitué ligne à ligne : une charge complète (`diff: false`) remplace tout, une différence met à jour
/// les clés présentes (`null` = clé retirée). La pochette est réduite dès son arrivée, la donnée brute jetée.
struct NowPlayingState {
    private var fields: [String: Any] = [:]
    private(set) var info: NowPlaying?
    private(set) var artwork: NSImage?
    /// Dernier nom d'app résolu, pour ne pas interroger LaunchServices à chaque ligne.
    private var appName: (id: String, name: String?)?

    /// 160 px : pochette affichée à 72 pt au plus, en Retina.
    static let artworkPixels = 160

    /// Applique une ligne de `stream` ; faux si elle est illisible.
    @discardableResult
    mutating func apply(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return false }
        if (object["diff"] as? Bool) != true {
            fields = [:]
            artwork = nil
        }
        for (key, value) in payload {
            if key == "artworkData" {
                artwork = (value as? String).flatMap(Self.thumbnail)
            } else if key != "artworkMimeType" {
                fields[key] = value is NSNull ? nil : value
            }
        }
        info = makeInfo()
        if info == nil { artwork = nil }
        return true
    }

    private mutating func makeInfo() -> NowPlaying? {
        guard let id = fields["parentApplicationBundleIdentifier"] as? String ?? fields["bundleIdentifier"] as? String,
              let title = fields["title"] as? String, !title.isEmpty else { return nil }
        if appName?.id != id { appName = (id, Self.appName(id)) }
        func seconds(_ key: String) -> TimeInterval? { (fields[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } }
        /// Durée ou position hors de 0…10⁷ s (un direct peut annoncer n'importe quoi) : inconnue.
        func span(_ key: String) -> TimeInterval? { seconds(key).flatMap { (0...1e7).contains($0) ? $0 : nil } }
        let artist = (fields["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return NowPlaying(bundleIdentifier: id, appName: appName?.name, title: title, artist: artist,
                          isPlaying: fields["playing"] as? Bool ?? false, duration: span("durationMicros"),
                          elapsed: span("elapsedTimeMicros"),
                          timestamp: seconds("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) },
                          rate: (fields["playbackRate"] as? NSNumber)?.doubleValue ?? 1)
    }

    static func appName(_ bundleIdentifier: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }

    /// Miniature décodée directement à la bonne taille (l'image complète n'est jamais en mémoire).
    static func thumbnail(base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: artworkPixels,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}

/// Commandes `send` de l'adaptateur.
enum MediaCommand: Int {
    case togglePlayPause = 2
    case next = 4
    case previous = 5
}

/// mediaremote-adapter (Vendor/, BSD-3-Clause) : depuis macOS 15.4, MediaRemote ne répond plus aux apps tierces,
/// mais /usr/bin/perl (binaire Apple) y a droit ; il charge le framework embarqué et écrit du JSON ligne à ligne.
final class MediaRemoteAdapter {
    let executable: URL
    /// Script, framework, client de test : précèdent chaque commande.
    let baseArguments: [String]

    private var stream: Process?
    private var restartWork: DispatchWorkItem?
    private var restartDelay: TimeInterval = 1
    private var quickDeaths = 0
    private var onFailure: (() -> Void)?

    static let maxRestartDelay: TimeInterval = 60
    static let testTimeout: TimeInterval = 10
    /// Trois morts d'affilée à moins de 5 s de vie : le flux est cassé, pas seulement interrompu.
    static let quickDeath: TimeInterval = 5
    static let quickDeathLimit = 3

    /// Enveloppe de `stream` (`sh -c watchdog sh <commande…>`) : la commande tourne en arrière-plan et un
    /// sous-shell attend la fin de l'entrée standard, un tube dont seule l'app tient l'autre bout. L'app meurt
    /// (SIGKILL, plantage, pkill, launchctl bootout) : le noyau ferme ce bout, `read` rend la main et la commande
    /// est tuée. Sans cela perl survivait jusqu'à sa prochaine écriture (SIGPIPE), parfois des heures.
    static let watchdog = """
    exec 3<&0
    "$@" 3<&- </dev/null &
    child=$!
    { read -r line <&3; kill "$child" 2>/dev/null; } >/dev/null &
    watch=$!
    exec 3<&-
    trap 'kill "$child" "$watch" 2>/dev/null' TERM HUP INT
    wait "$child"
    status=$?
    kill "$watch" 2>/dev/null
    exit "$status"
    """

    init(executable: URL, baseArguments: [String]) {
        self.executable = executable
        self.baseArguments = baseArguments
    }

    /// L'adaptateur assemblé dans l'app par scripts/build.sh ; nil hors de l'app (swift run, tests).
    static func bundled(_ bundle: Bundle = .main) -> MediaRemoteAdapter? {
        let contents = bundle.bundleURL.appendingPathComponent("Contents")
        let parts = ["Resources/mediaremote-adapter.pl", "Frameworks/MediaRemoteAdapter.framework",
                     "Helpers/MediaRemoteAdapterTestClient"].map { contents.appendingPathComponent($0).path }
        guard parts.allSatisfy(FileManager.default.fileExists) else { return nil }
        return MediaRemoteAdapter(executable: URL(fileURLWithPath: "/usr/bin/perl"), baseArguments: parts)
    }

    deinit { stopStream() }

    private func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = baseArguments + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// `test` : code de sortie 0 = MediaRemote répond. Résultat sur le main thread.
    func test(_ done: @escaping (Bool) -> Void) {
        let process = process(["test"])
        process.standardOutput = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        process.terminationHandler = { process in
            timeout.cancel()
            let ok = process.terminationReason == .exit && process.terminationStatus == 0
            DispatchQueue.main.async { done(ok) }
        }
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.testTimeout, execute: timeout)
        } catch {
            DispatchQueue.main.async { done(false) }
        }
    }

    /// Commande ponctuelle (`send 2`, `seek 42000000`), sans attendre le résultat.
    func run(_ arguments: [String]) {
        let process = process(arguments)
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    /// `stream` : chaque ligne JSON part vers `onLine` (file d'arrière-plan, dans l'ordre). Relancé avec un délai
    /// croissant (1 s → 60 s) si le processus meurt ; après `quickDeathLimit` morts rapides, `onFailure` (sur le
    /// main thread) remplace la relance. `stopStream()` ou la fin de l'app (voir `watchdog`) l'arrêtent.
    func startStream(onFailure: (() -> Void)? = nil, _ onLine: @escaping (Data) -> Void) {
        guard stream == nil, restartWork == nil else { return }
        self.onFailure = onFailure
        quickDeaths = 0
        launchStream(onLine)
    }

    func stopStream() {
        restartWork?.cancel()
        restartWork = nil
        onFailure = nil
        guard let process = stream else { return }
        stream = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? (process.standardInput as? Pipe)?.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    var isStreaming: Bool { stream != nil }

    private func launchStream(_ onLine: @escaping (Data) -> Void) {
        restartWork = nil
        let process = process(["stream", "--micros", "--debounce=100"])
        process.arguments = ["-c", Self.watchdog, "sh", executable.path] + (process.arguments ?? [])
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.standardInput = Pipe()
        let pipe = Pipe()
        process.standardOutput = pipe
        // Lu seulement par le gestionnaire de lecture du tube, un appel à la fois.
        final class Buffer { var data = Data() }
        let buffer = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            buffer.data.append(chunk)
            while let end = buffer.data.firstIndex(of: 0x0A) {
                let line = buffer.data[buffer.data.startIndex..<end]
                buffer.data.removeSubrange(buffer.data.startIndex...end)
                if !line.isEmpty { onLine(Data(line)) }
            }
        }
        let started = Date()
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.streamEnded(ended, after: Date().timeIntervalSince(started), onLine) }
        }
        stream = process
        do {
            try process.run()
        } catch {
            streamEnded(process, after: 0, onLine)
        }
    }

    /// Mort inattendue : relance plus tard. Une minute de vie sans incident remet le délai à 1 s.
    private func streamEnded(_ process: Process, after lifetime: TimeInterval, _ onLine: @escaping (Data) -> Void) {
        guard process === stream else { return }
        stream = nil
        try? (process.standardInput as? Pipe)?.fileHandleForWriting.close()
        if lifetime > Self.maxRestartDelay { restartDelay = 1 }
        quickDeaths = lifetime < Self.quickDeath ? quickDeaths + 1 : 0
        if quickDeaths >= Self.quickDeathLimit, let onFailure {
            self.onFailure = nil
            return onFailure()
        }
        let work = DispatchWorkItem { [weak self] in self?.launchStream(onLine) }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
    }
}
