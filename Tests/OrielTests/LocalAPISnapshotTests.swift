import AppKit
import SwiftUI
import XCTest
@testable import Oriel

/// Rendus PNG de l'API locale : intercalaires posés par des scripts (au repos, carte déployée) et Réglages › Scripts.
/// Ne fait rien sans `ORIEL_SNAPSHOT_DIR`.
final class LocalAPISnapshotTests: XCTestCase {
    private static let wallpaper = Color(red: 0.36, green: 0.52, blue: 0.74)

    private func api() -> LocalAPI {
        let api = LocalAPI(defaults: makeEphemeralDefaults(self), tokenFile: nil,
                           appName: { $0 == "com.apple.Terminal" ? "Terminal" : nil })
        api.isEnabled = true
        let later = Date().addingTimeInterval(600)
        api.show(ExternalEar(id: "mail", title: "Courrier du serveur", text: "12", icon: "envelope.fill", color: "blue",
                             client: "imap-check", expires: later))
        api.show(ExternalEar(id: "render", title: "Rendu vidéo", text: "…", detail: "export 4K en cours",
                             icon: "hourglass", color: "yellow", client: "notch", expires: later))
        api.show(ExternalEar(id: "build", title: "Build fini", text: "2m14", detail: "make test : 412 tests, 0 échec",
                             icon: "checkmark.circle.fill", color: "green", app: "com.apple.Terminal",
                             appName: "Terminal", client: "make.sh", expires: later))
        return api
    }

    private func root(_ api: LocalAPI, hovered: String? = nil) -> some View {
        let harness = NotchHarness(self, store: .working(2))
        harness.model.hoveredTab = hovered
        let registry = ModuleRegistry(modules: [harness.claude], prefs: harness.prefs, external: api)
        registry.reconcile()
        return NotchRootView(model: harness.model, store: harness.store, registry: registry, prefs: harness.prefs,
                             actions: NotchActions())
    }

    func testRenderScriptEars() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let api = api()
        try TimerNotesSnapshot.render(root(api), "api-ears-rest", dir, size: CGSize(width: 800, height: 70),
                                      background: Self.wallpaper)
        try TimerNotesSnapshot.render(root(api, hovered: "api.build"), "api-ears-card", dir,
                                      size: CGSize(width: 800, height: 190), background: Self.wallpaper)
        try TimerNotesSnapshot.render(root(api, hovered: "api.render"), "api-ears-card-plain", dir,
                                      size: CGSize(width: 800, height: 190), background: Self.wallpaper)
    }

    func testRenderSettings() throws {
        guard let dir = TimerNotesSnapshot.outputDirectory else { throw XCTSkip("ORIEL_SNAPSHOT_DIR non défini") }
        let api = api()
        let destination = try makeTemporaryDirectory(self).appendingPathComponent(".local/bin/notch")
        let view = LocalAPISettings(api: api, bundled: repositoryRoot.appendingPathComponent("hooks/notch"),
                                    destination: destination)
        try TimerNotesSnapshot.render(view.frame(width: 530, height: SettingsWindow.size.height), "api-settings", dir,
                                      size: CGSize(width: 530, height: SettingsWindow.size.height), background: nil)

        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        let registry = ModuleRegistry(modules: [FakeModule(id: "claude")], prefs: prefs,
                                      external: LocalAPI(defaults: makeEphemeralDefaults(self), tokenFile: nil))
        try TimerNotesSnapshot.render(SettingsView(prefs: prefs, registry: registry, updater: Updater(),
                                                   selection: .scripts),
                                      "api-settings-off", dir, size: SettingsWindow.size, background: nil)
        try TimerNotesSnapshot.render(SettingsView(prefs: prefs, registry: registry, updater: Updater(),
                                                   selection: .general),
                                      "api-settings-sidebar", dir, size: SettingsWindow.size, background: nil)
    }
}
