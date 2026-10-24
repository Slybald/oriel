import Foundation

/// LaunchAgent `~/Library/LaunchAgents/io.github.slybald.oriel.plist` : lancement à l'ouverture de session.
/// Le dossier est injectable pour les tests.
enum LaunchAgent {
    static var label: String { AppIdentity.bundleId }
    /// Labels d'avant le renommage en Oriel (2.1 et avant, premières versions de scripts/install.sh).
    static var legacyLabels: [String] { AppIdentity.legacyBundleIds }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    static func plistURL(label: String = label, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(label).plist")
    }

    static var plistURL: URL { plistURL() }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool, in directory: URL = directory,
                           executable: String? = Bundle.main.executablePath) {
        if enabled {
            guard let executable else { return }
            do {
                try write(executable: executable, in: directory)
            } catch {
                NSLog("Oriel : écriture du LaunchAgent impossible (%@).", String(describing: error))
            }
        } else {
            // Pas de `launchctl bootout` ici : si launchd a lancé l'app, il la tuerait.
            // Sans le fichier, rien ne sera relancé à la prochaine ouverture de session.
            for url in [plistURL(in: directory)] + legacyLabels.map({ plistURL(label: $0, in: directory) }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Anciens plists (`io.github.slybald.claudenotch.plist`, `local.claudenotch.plist`) : remplacés par le nouveau pour
    /// garder « Lancer à l'ouverture de session », puis supprimés, sans `launchctl bootout` (il tuerait l'app si
    /// launchd l'a lancée). Rend vrai si une migration a eu lieu.
    @discardableResult
    static func migrateLegacy(in directory: URL = directory,
                              executable: String? = Bundle.main.executablePath) -> Bool {
        let legacy = legacyLabels.map { plistURL(label: $0, in: directory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !legacy.isEmpty, let executable else { return false }
        do {
            try write(executable: executable, in: directory)
            for url in legacy { try FileManager.default.removeItem(at: url) }
        } catch {
            NSLog("Oriel : migration du LaunchAgent impossible (%@).", String(describing: error))
            return false
        }
        return true
    }

    /// LaunchAgent présent mais tourné vers un autre exécutable (app renommée en Oriel.app, ou réinstallée
    /// ailleurs) : réécrit vers `executable`. Absent (option décochée) ou illisible : rien. Rend vrai s'il a changé.
    @discardableResult
    static func refresh(in directory: URL = directory, executable: String? = Bundle.main.executablePath) -> Bool {
        guard let executable, let data = try? Data(contentsOf: plistURL(in: directory)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["ProgramArguments"] as? [String] != [executable] else { return false }
        do {
            try write(executable: executable, in: directory)
        } catch {
            NSLog("Oriel : mise à jour du LaunchAgent impossible (%@).", String(describing: error))
            return false
        }
        return true
    }

    private static func write(executable: String, in directory: URL) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL(in: directory), options: .atomic)
    }
}
