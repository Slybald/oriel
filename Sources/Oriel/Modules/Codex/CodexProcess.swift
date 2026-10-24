import Foundation

/// Identifie le processus Codex et l'app qui l'héberge, pendant que le script de hook attend la réponse (ses parents
/// sont vivants). `$PPID` du hook est le processus `codex` lui-même (CLI ou serveur de l'app Codex), mesuré sur 0.154.
enum CodexProcess {
    private static let cacheLock = NSLock()
    private static var hostCache: [String: HostApp] = [:]

    static func context(for headers: HookHeaders) -> CodexContext {
        var context = CodexContext()
        let chain = headers.ppid.map { ProcessInspector.ancestors(of: $0) } ?? []
        // Le premier ancêtre qui n'est pas un shell (un shell intermédiaire n'est pas Codex).
        guard let index = chain.firstIndex(where: { !ProcessInspector.isShell($0) }) else {
            return fallback(context, headers)
        }
        let codex = chain[index]
        context.pid = codex.pid
        context.start = codex.startTime

        let key = "\(codex.pid)@\(codex.startTime)"
        cacheLock.lock()
        var host = hostCache[key]
        cacheLock.unlock()
        if host == nil {
            // Le binaire de l'app Codex vit dans son propre .app : il est lui-même l'hôte, sinon on remonte.
            host = hostApp(in: chain[index...])
            if let host {
                cacheLock.lock()
                if hostCache.count > 256 { hostCache.removeAll() }
                hostCache[key] = host
                cacheLock.unlock()
            }
        }
        return fallback(context, headers, host: host)
    }

    private static func hostApp(in chain: ArraySlice<ProcInfo>) -> HostApp? {
        for process in chain {
            guard let bundlePath = ProcessInspector.outermostBundlePath(process.path) else { continue }
            if let host = ProcessInspector.hostApp(bundlePath: bundlePath) { return host }
        }
        return nil
    }

    private static func fallback(_ context: CodexContext, _ headers: HookHeaders, host: HostApp? = nil) -> CodexContext {
        var context = context
        let found = host ?? ProcessInspector.hostFromHeaders(headers)
        context.hostName = found?.name
        context.hostBundleId = found?.bundleId
        return context
    }
}
