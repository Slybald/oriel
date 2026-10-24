import AppKit
import Darwin

/// Instantané d'un processus.
struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let name: String
    let path: String
    /// Heure de démarrage : distingue un pid réutilisé.
    let startTime: TimeInterval
}

enum SessionSource: Equatable {
    case cli
    case desktop
}

/// Ce qu'on sait du processus Claude qui a déclenché un hook.
struct ProcessContext {
    var claudePid: pid_t?
    var claudeStart: TimeInterval?
    var source: SessionSource = .cli
    var hostName: String?
    var hostBundleId: String?
    var taskListId: String?
    var configDir: String?
    var desktopSessionId: String?
}

struct HostApp: Equatable {
    let bundleId: String?
    let name: String
}

/// Accès bas niveau aux processus (sysctl, libproc) et identification de Claude et de son app hôte.
enum ProcessInspector {
    static let desktopBundleId = "com.anthropic.claudefordesktop"

    private static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu", "xonsh",
        "login", "env", "sudo", "nohup", "timeout", "script",
    ]

    // MARK: - Primitives

    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func startTime(_ info: kinfo_proc) -> TimeInterval {
        let time = info.kp_proc.p_un.__p_starttime
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
    }

    static func info(_ pid: pid_t) -> ProcInfo? {
        guard let k = kinfo(pid) else { return nil }
        var name = name(pid)
        if name.isEmpty {
            name = withUnsafeBytes(of: k.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        return ProcInfo(pid: pid, ppid: k.kp_eproc.e_ppid, name: name, path: path(pid), startTime: startTime(k))
    }

    static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return string(from: buffer)
    }

    static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return string(from: buffer)
    }

    /// argv du processus (KERN_PROCARGS2). Vide si inaccessible.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // chemin de l'exécutable
        while index < size, buffer[index] == 0 { index += 1 }   // bourrage

        var arguments: [String] = []
        while arguments.count < Int(argc), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Vivant, et c'est bien le même processus (pas un pid réutilisé).
    static func isAlive(_ pid: pid_t, startedAt start: TimeInterval?) -> Bool {
        guard isAlive(pid) else { return false }
        guard let start, let k = kinfo(pid) else { return true }
        return abs(startTime(k) - start) < 1
    }

    /// Le processus puis ses ancêtres, jusqu'à launchd exclu.
    static func ancestors(of pid: pid_t, limit: Int = 48) -> [ProcInfo] {
        var chain: [ProcInfo] = []
        var current = pid
        while current > 1, chain.count < limit, let process = info(current) {
            chain.append(process)
            if process.ppid == current { break }
            current = process.ppid
        }
        return chain
    }

    // MARK: - Reconnaître Claude

    /// Le CLI natif tourne sous le nom de sa version (« 2.1.296 »), lancé depuis ~/.local/share/claude/versions/.
    static func isVersionName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Filtre rapide sur le nom, avant de lire chemin et arguments.
    static func isCandidateName(_ name: String) -> Bool {
        name == "claude" || name == "node" || name == "bun" || isVersionName(name)
    }

    static func isClaude(_ process: ProcInfo) -> Bool {
        let base = (process.path as NSString).lastPathComponent
        if process.name == "claude" || base == "claude" { return true }
        if process.path.contains("/claude/versions/") { return true }
        if ["node", "bun"].contains(process.name) || ["node", "bun"].contains(base) {
            return arguments(process.pid).dropFirst().prefix(3).contains {
                $0.contains("claude-code") || ($0 as NSString).lastPathComponent == "claude"
            }
        }
        return false
    }

    static func isShell(_ process: ProcInfo) -> Bool {
        shellNames.contains(process.name) || shellNames.contains((process.path as NSString).lastPathComponent)
    }

    // MARK: - App hôte

    /// Bundle le plus externe : on coupe au premier « .app/ » (sinon VS Code donne « Code Helper »).
    static func outermostBundlePath(_ path: String) -> String? {
        if let range = path.range(of: ".app/") {
            return String(path[..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }

    private static let knownNames: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp",
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "dev.zed.Zed": "Zed",
        "com.github.wez.wezterm": "WezTerm",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
        "co.zeit.hyper": "Hyper",
        desktopBundleId: "Desktop",
    ]

    /// Repli quand aucun ancêtre n'est une app (tmux, screen…).
    private static let termPrograms: [String: HostApp] = [
        "Apple_Terminal": HostApp(bundleId: "com.apple.Terminal", name: "Terminal"),
        "iTerm.app": HostApp(bundleId: "com.googlecode.iterm2", name: "iTerm2"),
        "ghostty": HostApp(bundleId: "com.mitchellh.ghostty", name: "Ghostty"),
        "WarpTerminal": HostApp(bundleId: "dev.warp.Warp-Stable", name: "Warp"),
        "vscode": HostApp(bundleId: "com.microsoft.VSCode", name: "VS Code"),
        "WezTerm": HostApp(bundleId: "com.github.wez.wezterm", name: "WezTerm"),
        "zed": HostApp(bundleId: "dev.zed.Zed", name: "Zed"),
        "Hyper": HostApp(bundleId: "co.zeit.hyper", name: "Hyper"),
        "tmux": HostApp(bundleId: nil, name: "tmux"),
    ]

    static func hostApp(bundlePath: String) -> HostApp? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        let bundleId = bundle.bundleIdentifier
        let info = bundle.infoDictionary
        let name = bundleId.flatMap { knownNames[$0] }
            ?? info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return HostApp(bundleId: bundleId, name: name)
    }

    static func bundleIdentifier(atPath bundlePath: String) -> String? {
        Bundle(path: bundlePath)?.bundleIdentifier
    }

    private static func resolveHost(above chain: ArraySlice<ProcInfo>, skipping ownBundle: String?) -> HostApp? {
        for process in chain where !isClaude(process) {
            guard let bundlePath = outermostBundlePath(process.path), bundlePath != ownBundle else { continue }
            if let host = hostApp(bundlePath: bundlePath) { return host }
        }
        return nil
    }

    static func hostFromHeaders(_ headers: HookHeaders) -> HostApp? {
        if let bundleId = headers.bundleId {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
               let host = hostApp(bundlePath: url.path) {
                return host
            }
            return HostApp(bundleId: bundleId, name: knownNames[bundleId] ?? bundleId)
        }
        if let term = headers.termProgram {
            return termPrograms[term] ?? HostApp(bundleId: nil, name: term)
        }
        return nil
    }

    // MARK: - Contexte d'un hook

    private static let cacheLock = NSLock()
    private static var hostCache: [String: HostApp] = [:]

    /// À appeler pendant que le script de hook attend la réponse (ses parents sont vivants).
    static func context(for headers: HookHeaders) -> ProcessContext {
        var context = ProcessContext(taskListId: headers.taskListId, configDir: headers.configDir,
                                     desktopSessionId: headers.hostSessionId)
        let chain = headers.ppid.map { ancestors(of: $0) } ?? []

        // PID de Claude : premier ancêtre reconnu comme Claude, sinon premier qui n'est pas un shell.
        let claudeIndex = chain.firstIndex(where: isClaude) ?? chain.firstIndex { !isShell($0) }
        var host: HostApp?
        if let index = claudeIndex {
            let claude = chain[index]
            context.claudePid = claude.pid
            context.claudeStart = claude.startTime

            let key = "\(claude.pid)@\(claude.startTime)"
            cacheLock.lock()
            host = hostCache[key]
            cacheLock.unlock()

            // Le claude de Desktop vit dans son propre claude.app : on l'écarte pour trouver Claude.app.
            if host == nil,
               let found = resolveHost(above: chain[(index + 1)...], skipping: outermostBundlePath(claude.path)) {
                host = found
                cacheLock.lock()
                if hostCache.count > 256 { hostCache.removeAll() }
                hostCache[key] = found
                cacheLock.unlock()
            }
        }
        if host == nil { host = hostFromHeaders(headers) }

        let entrypoint = headers.entrypoint?.lowercased() ?? ""
        let isDesktop = host?.bundleId == desktopBundleId
            || headers.bundleId == desktopBundleId
            || entrypoint.contains("desktop")
        context.source = isDesktop ? .desktop : .cli
        context.hostBundleId = isDesktop ? desktopBundleId : host?.bundleId
        context.hostName = isDesktop ? "Desktop" : host?.name
        return context
    }

    // MARK: - Utilitaires

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
