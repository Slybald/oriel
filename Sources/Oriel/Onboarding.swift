import AppKit
import SwiftUI

/// État des hooks Claude Code, partagé par le menu « … », Réglages › Claude et la fenêtre de bienvenue.
final class HookSetup: ObservableObject {
    static let shared = HookSetup()

    /// Fenêtre ouverte au lancement.
    enum LaunchWindow: Equatable {
        case none
        /// Hooks d'une version précédente que la mise à jour silencieuse n'a pas pu remplacer.
        case update
        /// Premier lancement : l'assistant de configuration (`claude` : Claude Code détecté, onglet proposé).
        case welcome(claude: Bool)
    }

    /// Relu au lancement (onglet Claude activé), à l'ouverture du panneau et après chaque action (jamais dans `init`).
    @Published private(set) var status: HookInstaller.Status = .notInstalled
    let installer: HookInstaller
    private var onboarding: OnboardingWindowController?
    private var assistant: OnboardingWindowController?

    init(installer: HookInstaller = .standard) {
        self.installer = installer
    }

    func refresh() {
        let current = installer.status()
        if current != status { status = current }
    }

    var isInApplications: Bool { AppIdentity.isInApplicationsFolder(Bundle.main.bundlePath) }

    /// Au lancement. Onglet Claude activé : des hooks déjà posés par une version précédente (entrées ou script) sont
    /// mis à jour sans rien demander, l'accord a été donné à l'installation (sauvegarde horodatée de settings.json,
    /// comme toujours). Onglet désactivé : `~/.claude` n'est même pas lu. Puis la fenêtre éventuelle.
    func showOnboardingIfNeeded(claudeEnabled: Bool, prefs: Preferences, registry: ModuleRegistry?) {
        if claudeEnabled {
            refresh()
            silentUpdate()
            StatusLineSetup.shared.updateScriptIfNeeded()
        }
        let window = Self.launchWindow(claudeEnabled: claudeEnabled, status: status, welcomeShown: prefs.welcomeShown)
        // L'assistant ne vient qu'une fois ; une mise à jour ratée le repousse au lancement suivant.
        if window != .update { prefs.welcomeShown = true }
        switch window {
        case .none: break
        case .update: showOnboarding()
        case .welcome(let claude):
            if let registry { showSetupAssistant(registry: registry, prefs: prefs, claudeDetected: claude, firstRun: true) }
        }
    }

    /// Mise à jour silencieuse ratée : on la propose. Sinon, l'assistant au premier lancement, sauf après une mise à
    /// jour depuis une version qui avait posé les hooks (ce n'est pas un premier lancement).
    static func launchWindow(claudeEnabled: Bool, status: HookInstaller.Status, welcomeShown: Bool) -> LaunchWindow {
        if claudeEnabled, status == .outdated || status == .scriptOutdated { return .update }
        if welcomeShown || (claudeEnabled && status == .installed) { return .none }
        return .welcome(claude: claudeEnabled)
    }

    /// Ce qu'il faut faire des hooks pour que les réponses marchent.
    enum Repair { case none, update, install }

    static func repairNeeded(for status: HookInstaller.Status) -> Repair {
        switch status {
        case .installed: return .none
        case .outdated, .scriptOutdated: return .update
        case .notInstalled, .unreadable: return .install
        }
    }

    /// `.scriptOutdated` : seul le script est réécrit. `.outdated` : entrées et script.
    func silentUpdate() {
        do {
            switch status {
            case .scriptOutdated: try installer.updateScript()
            case .outdated: try installer.install()
            default: return
            }
        } catch {
            NSLog("Oriel : mise à jour des hooks impossible (%@).", error.localizedDescription)
        }
        refresh()
    }

    // MARK: - Fenêtre

    /// Assistant de configuration : au premier lancement (`firstRun`), ou relancé depuis Réglages › Général, auquel
    /// cas il part des réglages actuels. `~/.claude` n'est lu que si l'onglet Claude est proposé.
    func showSetupAssistant(registry: ModuleRegistry, prefs: Preferences,
                            claudeDetected: Bool = HookInstaller.claudeCodeOnThisMac,
                            codexDetected: Bool = CodexHookInstaller.codexOnThisMac, firstRun: Bool = false) {
        DispatchQueue.main.async { [self] in
            if let assistant {
                assistant.showWindow(nil)
                Self.activateApp()
                return
            }
            let claudeOffered = claudeDetected || registry.isClaudeEnabled
            if claudeOffered { refresh() }
            let model = SetupAssistantModel(
                registry: registry, prefs: prefs, claudeDetected: claudeDetected, codexDetected: codexDetected,
                hookStatus: claudeOffered ? status : .notInstalled, firstRun: firstRun, inApplications: isInApplications,
                installHooks: { [weak self] in self?.installHooks() },
                applyLaunchAtLogin: { [weak self] in self?.applyLaunchAtLogin($0) },
                close: { [weak self] in self?.assistant?.close() })
            let controller = OnboardingWindowController(rootView: SetupAssistantView(model: model))
            controller.onClose = { [weak self] in self?.assistant = nil }
            assistant = controller
            controller.window?.center()
            controller.showWindow(nil)
            Self.activateApp()
        }
    }

    /// nil si les hooks sont posés, sinon le message d'erreur (assistant de configuration).
    private func installHooks() -> String? {
        defer { refresh() }
        do {
            try installer.install()
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    /// Installer ou mettre à jour les hooks (Réglages › Claude, menu « … », mise à jour ratée).
    func showOnboarding() {
        DispatchQueue.main.async { [self] in
            refresh()
            if let onboarding {
                onboarding.showWindow(nil)
                Self.activateApp()
                return
            }
            var error: String?
            if case .unreadable(let message) = status { error = message }
            let view = OnboardingView(
                mode: status == .outdated || status == .scriptOutdated ? .update : .install,
                inApplications: isInApplications,
                launchAtLogin: status == .notInstalled || Preferences.shared.launchAtLogin,
                error: error,
                onInstall: { [weak self] launchAtLogin in self?.installFromWindow(launchAtLogin: launchAtLogin) },
                onClose: { [weak self] _ in self?.onboarding?.close() }
            )
            let controller = OnboardingWindowController(rootView: view)
            controller.onClose = { [weak self] in self?.onboarding = nil }
            onboarding = controller
            controller.window?.center()
            controller.showWindow(nil)
            Self.activateApp()
        }
    }

    /// nil si tout s'est bien passé, sinon le message d'erreur. Fenêtre refermée seule peu après un succès.
    private func installFromWindow(launchAtLogin: Bool) -> String? {
        defer { refresh() }
        do {
            try installer.install()
        } catch {
            return error.localizedDescription
        }
        applyLaunchAtLogin(launchAtLogin)
        let controller = onboarding
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { controller?.close() }
        return nil
    }

    /// Hors Applications, le LaunchAgent pointerait vers le DMG ou une copie temporaire.
    private func applyLaunchAtLogin(_ isOn: Bool) {
        if isInApplications, Preferences.shared.launchAtLogin != isOn { Preferences.shared.launchAtLogin = isOn }
    }

    // MARK: - Menu « … »

    /// Hooks anciens : réinstallés directement (l'accord a déjà été donné à l'installation).
    func update() {
        DispatchQueue.main.async { [self] in
            do {
                try installer.install()
            } catch {
                Self.activateApp()
                Self.showError(error, title: L("Mise à jour des hooks impossible"))
            }
            refresh()
        }
    }

    /// Confirmation, puis retrait des hooks, du script de hook et du LaunchAgent, puis Quitter. Sans hooks, le texte
    /// ne parle pas de Claude Code.
    func confirmAndUninstall() {
        DispatchQueue.main.async { [self] in
            Self.activateApp()
            refresh()
            let hooks = status != .notInstalled
            // Les hooks de Oriel dans ~/.codex/hooks.json partent aussi (si lisibles : un fichier cassé
            // n'empêche pas la désinstallation).
            let codexInstaller = CodexHookInstaller.standard
            let codexHooks = [.installed, .outdated, .scriptOutdated].contains(codexInstaller.status())
            // Le relais de statusLine des jauges de quota part aussi, et la commande d'origine revient.
            let relayInstaller = StatusLineInstaller.standard
            let quotaRelay = [.installed, .scriptOutdated].contains(relayInstaller.status())
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("Désinstaller Oriel ?")
            alert.informativeText = hooks
                ? L("Les hooks d'Oriel seront retirés de ~/.claude/settings.json (sauvegarde "
                    + "horodatée à côté, tes autres hooks restent en place), ainsi que ~/.claude/hooks/oriel-hook.sh "
                    + "et le lancement à l'ouverture de session. L'app se fermera ensuite.")
                : L("Le lancement à l'ouverture de session sera retiré. L'app se fermera ensuite.")
            if codexHooks {
                alert.informativeText += "\n\n" + L("Les hooks de Codex seront aussi retirés de ~/.codex/hooks.json "
                                                      + "(sauvegarde horodatée à côté).", table: "Codex")
            }
            if quotaRelay {
                alert.informativeText += "\n\n" + L("Le relais de statusLine des jauges de quota sera aussi retiré de "
                                                      + "~/.claude/settings.json, et ta commande d'origine remise.", table: "Claude")
            }
            alert.addButton(withTitle: L("Désinstaller"))
            alert.addButton(withTitle: L("Annuler"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            do {
                try installer.uninstall()
                if quotaRelay { try relayInstaller.uninstall() }
                if codexHooks { try codexInstaller.uninstall() }
            } catch {
                refresh()
                Self.showError(error, title: L("Désinstallation interrompue"))
                return
            }
            LaunchAgent.setEnabled(false)
            // Règle « économie d'énergie sans mot de passe » (Réglages rapides) : retirée aussi ; sans règle, rien
            // n'est demandé.
            LowPowerAuthorization.remove { result in
                if case .failure = result, LowPowerAuthorization.isInstalled {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L("La règle d'économie d'énergie reste en place")
                    alert.informativeText = L("Pour la retirer : sudo rm /etc/sudoers.d/oriel-lowpower")
                    alert.runModal()
                }
                // Outil des ventilateurs et sa règle : retirés aussi (après avoir rendu la main à macOS).
                FanAuthorization.remove { result in
                    if case .failure = result {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L("L'outil des ventilateurs reste en place")
                        alert.informativeText = String(format: L("Pour le retirer : sudo rm %@ %@"),
                                                       FanAuthorization.rulePath, FanAuthorization.helperPath)
                        alert.runModal()
                    }
                    Self.finishUninstall(hooks: hooks)
                }
            }
        }
    }

    private static func finishUninstall(hooks: Bool) {
        let done = NSAlert()
        done.messageText = L("Oriel est désinstallé")
        done.informativeText = hooks
            ? L("Il ne reste qu'à jeter Oriel à la Corbeille, depuis le dossier Applications. "
                + "Les sessions Claude Code déjà ouvertes l'oublieront à leur redémarrage.")
            : L("Il ne reste qu'à jeter Oriel à la Corbeille, depuis le dossier Applications.")
        done.addButton(withTitle: L("Afficher dans le Finder"))
        done.addButton(withTitle: L("Quitter"))
        if done.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        NSApp.terminate(nil)
    }

    // MARK: - Outils

    /// L'app reste `.accessory` (pas d'icône dans le Dock) : on l'active pour montrer une fenêtre ou une alerte.
    static func activateApp() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// Fenêtre classique (titre transparent, fond noir) qui héberge la vue SwiftUI.
/// Le contrôleur SwiftUI ajuste la taille de la fenêtre quand un message apparaît.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init<Content: View>(rootView: Content) {
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Oriel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Vue

struct OnboardingView: View {
    /// Hooks seuls, depuis les réglages (`install`) ou après une mise à jour ratée (`update`). Le premier lancement
    /// passe par l'assistant de configuration (`SetupAssistant`).
    enum Mode { case install, update }

    private enum Phase: Equatable {
        case idle
        case done
        case failed(String)
    }

    let mode: Mode
    let inApplications: Bool
    /// nil si tout s'est bien passé, sinon le message d'erreur.
    let onInstall: (_ launchAtLogin: Bool) -> String?
    /// Reçoit l'état de la case « Lancer à l'ouverture de session ».
    let onClose: (_ launchAtLogin: Bool) -> Void

    @State private var launchAtLogin: Bool
    @State private var phase: Phase

    init(mode: Mode, inApplications: Bool, launchAtLogin: Bool, error: String? = nil,
         onInstall: @escaping (_ launchAtLogin: Bool) -> String?, onClose: @escaping (_ launchAtLogin: Bool) -> Void) {
        self.mode = mode
        self.inApplications = inApplications
        self.onInstall = onInstall
        self.onClose = onClose
        _launchAtLogin = State(initialValue: inApplications && launchAtLogin)
        _phase = State(initialValue: error.map(Phase.failed) ?? .idle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !inApplications { ApplicationsWarning() }
            changes
            loginToggle
            switch phase {
            case .idle: EmptyView()
            case .done: message(success, icon: "checkmark.circle.fill", color: Palette.green)
            case .failed(let text): message(text, icon: "xmark.octagon.fill", color: Palette.red)
            }
            buttons
        }
        // Le haut est sous la barre de titre transparente (zone sûre) : 6 pt suffisent.
        .padding(.horizontal, 26)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .frame(width: 470, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black.ignoresSafeArea())
        .foregroundColor(Palette.primary)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.accent.opacity(0.16))
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(Palette.accent)
                }
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .update ? L("Mettre à jour Oriel") : L("Bienvenue dans Oriel"))
                        .font(.system(size: 17, weight: .semibold))
                    Text("Tes sessions Claude Code, d'un coup d'œil.")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
            }
            Text(mode == .update
                 ? L("Les hooks installés viennent d'une version précédente de l'app. Mets-les à jour pour que la notch "
                    + "continue de suivre tes sessions.")
                 : L("Survole la notch : chaque session Claude Code (terminal, éditeur ou Claude Desktop) y affiche son "
                    + "état, l'outil en cours, ses tâches et les permissions qui t'attendent. Tout reste sur ton Mac."))
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hooks : ce qui sera modifié.
    private var changes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CE QUI SERA MODIFIÉ")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Palette.secondary)
            InfoRow(icon: "doc.text", title: "~/.claude/settings.json", monospaced: true,
                    detail: L("Ajout des hooks d'Oriel. Tes hooks restent en place ; une sauvegarde horodatée "
                        + "est faite à côté."))
            InfoRow(icon: "terminal", title: "~/.claude/hooks/oriel-hook.sh", monospaced: true,
                    detail: L("Petit script qui relaie chaque événement à l'app, en local (127.0.0.1)."))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
    }

    private var loginToggle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Lancer à l'ouverture de session", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .disabled(!inApplications || phase == .done)
            if !inApplications {
                Text("Disponible une fois l'app dans Applications.")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private var success: String {
        mode == .update
            ? L("Hooks à jour. Les sessions déjà ouvertes apparaîtront à leur prochain message.")
            : L("Hooks installés. Les sessions déjà ouvertes apparaîtront à leur prochain message.")
    }

    private var installTitle: String {
        switch mode {
        case .install: return L("Installer les hooks Claude Code")
        case .update: return L("Mettre à jour les hooks")
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            if phase == .done {
                Button("Fermer") { onClose(launchAtLogin) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Plus tard") { onClose(launchAtLogin) }
                    .keyboardShortcut(.cancelAction)
                Button(installTitle) {
                    if let error = onInstall(launchAtLogin) {
                        phase = .failed(error)
                    } else {
                        phase = .done
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
            }
        }
        .controlSize(.large)
    }
}

/// « Glisse d'abord Oriel dans Applications » : l'app tourne depuis l'image disque ou une copie temporaire.
struct ApplicationsWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(Palette.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text("Glisse d'abord Oriel dans Applications")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(L("L'app tourne depuis l'image disque ou une copie temporaire. Quitte-la, glisse-la dans le dossier "
                       + "Applications, puis rouvre-la depuis là."))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.amber.opacity(0.12)))
    }
}

/// Ligne icône + titre + détail (fichiers modifiés par les hooks, où retrouver les réglages).
struct InfoRow: View {
    let icon: String
    let title: String
    var monospaced = false
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Palette.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Menu

/// Entrées du menu « … » du panneau : état des hooks (onglet Claude activé seulement) et désinstallation.
struct HookMenuItems: View {
    @ObservedObject var setup: HookSetup
    let claudeEnabled: Bool

    var body: some View {
        if claudeEnabled {
            switch setup.status {
            case .installed:
                Button("Hooks Claude Code installés ✓") {}
                    .disabled(true)
            case .outdated, .scriptOutdated:
                Button("Mettre à jour les hooks Claude Code", action: setup.update)
            case .notInstalled, .unreadable:
                Button("Installer les hooks Claude Code", action: setup.showOnboarding)
            }
        }
        Button("Désinstaller Oriel…", action: setup.confirmAndUninstall)
    }
}
