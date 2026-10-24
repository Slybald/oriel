import SwiftUI

// Barre de commande : « s présentation » applique une scène. Textes dans la table « Command ».

extension QuickSettingsModule {
    var commandVerb: CommandVerb? { CommandVerb(key: "s", title: L("scène", table: "Command")) }

    func commands(for query: CommandQuery) -> [NotchCommand] {
        // Sans verbe, il faut au moins trois lettres : « no » ne doit pas changer l'état du Mac.
        guard query.verb != nil || query.argument.count >= 3 else { return [] }
        var commands: [NotchCommand] = []
        for (index, scene) in QuickScene.allCases.enumerated() where scene != .normal || canRestoreNormal {
            let match = query.argument.isEmpty ? 500 - index : FuzzyMatch.score(query.argument, in: scene.title)
            guard let score = match else { continue }
            commands.append(NotchCommand(
                id: "quicksettings.scene.\(scene.rawValue)", symbol: scene.symbol, title: scene.title,
                detail: QuickSettingsView.sceneSubtitle(scene, lowPowerSupported: lowPowerSupported,
                                                        noBluetooth: prefs.autonomyBluetoothOff,
                                                        withFocus: prefs.presentationFocus, canRestore: canRestoreNormal),
                tint: Self.tint(of: scene), score: score,
                run: { [weak self] in
                    self?.applyScene(scene)
                    return nil
                }))
        }
        // Vitesse fixe active : la rendre à macOS (« s ventil »). Le passage en vitesse fixe reste dans l'onglet.
        if fans.isFixed {
            let title = L("Rendre la main à macOS", table: "QuickSettings")
            let detail = L("Ventilateurs : fin de la vitesse fixe", table: "Command")
            if let score = query.argument.isEmpty ? 400 : FuzzyMatch.score(query.argument, in: title + " " + detail) {
                commands.append(NotchCommand(id: "quicksettings.fans.automatic", symbol: "fanblades.fill", title: title,
                                             detail: detail, tint: Palette.green, score: score,
                                             run: { [weak self] in
                                                 self?.fans.returnToAutomatic()
                                                 return nil
                                             }))
            }
        }
        return commands
    }

    private static func tint(of scene: QuickScene) -> Color {
        switch scene {
        case .autonomy: return Palette.green
        case .normal: return Palette.secondary
        case .presentation: return Color(red: 0.4, green: 0.6, blue: 1)
        }
    }
}
