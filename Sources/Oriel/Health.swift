import Darwin
import Foundation

// Réglages › Santé : ce qui tourne vraiment, en langage simple. Modèle pur (testé sans fenêtre) ; les mesures sont
// lues une seule fois à l'ouverture de la page ou au clic sur « Actualiser » : rien ne tourne page fermée.

/// Mode sobre : économie d'énergie ou chaleur forte → animations réduites (barres d'égaliseur, spinners figés).
enum SoberMode {
    static func isSober(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        lowPower || thermal == .serious || thermal == .critical
    }

    /// Valeur courante, lue sur le système.
    static var current: Bool {
        isSober(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
    }

    /// Pourquoi il est actif (nil = inactif), pour la page Santé.
    static func reason(lowPower: Bool, thermal: ProcessInfo.ThermalState) -> String? {
        if lowPower { return L("économie d'énergie", table: "Health") }
        if thermal == .serious || thermal == .critical { return L("Mac très chaud", table: "Health") }
        return nil
    }
}

struct HealthModuleRow: Equatable {
    var title: String
    var enabled: Bool
    var running: Bool
}

enum HealthPermissionState: Equatable {
    case granted, missing, notAsked
    /// Pas vérifiable sans lancer le module (la lecture se fait à son démarrage).
    case unknown
}

struct HealthPermissionRow: Equatable {
    var title: String
    var state: HealthPermissionState
}

/// Valeurs mesurées sur l'app depuis son lancement.
struct HealthProcess: Equatable {
    var memoryBytes: UInt64
    var cpuSeconds: Double
    var uptimeSeconds: Double

    /// Mesure réelle : `phys_footprint` (comme le Moniteur d'activité), temps CPU utilisateur + système, durée depuis le lancement.
    static func measure() -> HealthProcess? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        guard status == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0,
              let started = ProcessInspector.kinfo(getpid()).map(ProcessInspector.startTime) else { return nil }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return HealthProcess(memoryBytes: info.phys_footprint, cpuSeconds: seconds(usage.ru_utime) + seconds(usage.ru_stime),
                             uptimeSeconds: max(Date().timeIntervalSince1970 - started, 0))
    }
}

struct HealthReport: Equatable {
    var version: String
    var modules: [HealthModuleRow]
    var permissions: [HealthPermissionRow]
    var soberReason: String?
    var process: HealthProcess?

    var runningCount: Int { modules.filter { $0.running }.count }

    /// Un module activé mais arrêté est normal (panneau fermé) ; un module « en marche » est celui qui travaille.
    static func moduleStatus(_ row: HealthModuleRow) -> String {
        if !row.enabled { return L("désactivé", table: "Health") }
        return row.running ? L("en marche", table: "Health") : L("au repos", table: "Health")
    }

    static func permissionStatus(_ state: HealthPermissionState) -> String {
        switch state {
        case .granted: return L("accordée", table: "Health")
        case .missing: return L("manquante", table: "Health")
        case .notAsked: return L("pas encore demandée", table: "Health")
        case .unknown: return L("non vérifiée", table: "Health")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: L("%d h %02d min", table: "Health"), s / 3600, s % 3600 / 60)
            : s >= 60 ? String(format: L("%d min", table: "Health"), s / 60)
            : String(format: L("%d s", table: "Health"), s)
    }

    /// Texte à coller dans un ticket : ni chemin, ni nom de session.
    var text: String {
        var lines = ["Oriel \(version)"]
        lines.append(L("Mode sobre : ", table: "Health") + (soberReason.map { String(format: L("actif (%@)", table: "Health"), $0) } ?? L("inactif", table: "Health")))
        if let process {
            lines.append(String(format: L("Mémoire : %.0f Mo · CPU depuis le lancement : %.1f s sur %@", table: "Health"),
                                Double(process.memoryBytes) / 1_048_576, process.cpuSeconds, Self.duration(process.uptimeSeconds)))
        }
        lines += modules.map { "\($0.title) : \(Self.moduleStatus($0))" }
        lines += permissions.map { "\($0.title) : \(Self.permissionStatus($0.state))" }
        return lines.joined(separator: "\n")
    }
}

extension ModuleRegistry {
    /// Lecture unique de l'état réel (aucun abonnement, aucune minuterie).
    func healthReport(version: String) -> HealthReport {
        var permissions: [HealthPermissionRow] = []
        if isEnabled("agenda") || isEnabled("media") {
            let state: HealthPermissionState
            switch EventKitCalendar.currentAccess {
            case .granted: state = .granted
            case .denied: state = .missing
            case .notDetermined: state = .notAsked
            }
            permissions.append(HealthPermissionRow(title: L("Calendriers", table: "Health"), state: state))
        }
        if isEnabled("messages") {
            let state: HealthPermissionState
            switch (module("messages") as? MessagesModule)?.access {
            case .ready?: state = .granted
            case .needsFullDiskAccess?: state = .missing
            default: state = .unknown
            }
            permissions.append(HealthPermissionRow(title: L("Accès complet au disque (Messages)", table: "Health"), state: state))
        }
        let info = ProcessInfo.processInfo
        return HealthReport(
            version: version,
            modules: ordered.map { HealthModuleRow(title: $0.title, enabled: isEnabled($0.id), running: running.contains($0.id)) },
            permissions: permissions,
            soberReason: SoberMode.reason(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState),
            process: HealthProcess.measure())
    }
}
