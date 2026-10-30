import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Oriel

/// Réglages de la notch : migration, persistance, bornes, masquage temporaire, règle de visibilité, raccourcis,
/// réinitialisation. Toujours sur un domaine UserDefaults jetable.
final class ShellPreferencesTests: XCTestCase {
    // MARK: - Visibilité

    func testAlwaysVisibleMigration() {
        let unset = makeEphemeralDefaults(self)
        XCTAssertEqual(Preferences(defaults: unset).visibility, .always, "jamais réglé : toujours")

        let on = makeEphemeralDefaults(self)
        on.set(true, forKey: "alwaysVisible")
        XCTAssertEqual(Preferences(defaults: on).visibility, .always)

        let off = makeEphemeralDefaults(self)
        off.set(false, forKey: "alwaysVisible")
        let migrated = Preferences(defaults: off)
        XCTAssertEqual(migrated.visibility, .whenClaudeOpen, "l'ancien comportement sans « Toujours visible »")

        // Le nouveau réglage l'emporte ensuite sur l'ancienne clé.
        migrated.visibility = .duringActivity
        XCTAssertEqual(Preferences(defaults: off).visibility, .duringActivity)
        off.set("n'importe quoi", forKey: "visibility.mode")
        XCTAssertEqual(Preferences(defaults: off).visibility, .whenClaudeOpen, "valeur illisible : migration")
    }

    /// Réparation unique de la 1.2.0, qui avait enregistré « quand Claude est ouvert » d'elle-même chez qui avait les
    /// hooks : sans l'ancienne clé, retour à « toujours », une seule fois. Un choix venu de la 1.1 reste.
    func testOneTimeRepairOfThe120VisibilityDefault() {
        let saved120 = makeEphemeralDefaults(self)
        saved120.set("whenClaudeOpen", forKey: "visibility.mode")
        XCTAssertEqual(Preferences(defaults: saved120).visibility, .always, "défaut posé par la 1.2.0 : réparé")
        XCTAssertEqual(saved120.string(forKey: "visibility.mode"), "always", "enregistré")
        XCTAssertEqual(saved120.object(forKey: "visibility.defaultFixed121") as? Bool, true, "témoin posé")
        // Choisi ensuite : la réparation ne repasse pas.
        Preferences(defaults: saved120).visibility = .whenClaudeOpen
        XCTAssertEqual(Preferences(defaults: saved120).visibility, .whenClaudeOpen, "une seule fois")

        // « Toujours visible » décoché en 1.1 : un vrai choix, gardé.
        let from11 = makeEphemeralDefaults(self)
        from11.set(false, forKey: "alwaysVisible")
        from11.set("whenClaudeOpen", forKey: "visibility.mode")
        XCTAssertEqual(Preferences(defaults: from11).visibility, .whenClaudeOpen)

        let activity = makeEphemeralDefaults(self)
        activity.set("duringActivity", forKey: "visibility.mode")
        XCTAssertEqual(Preferences(defaults: activity).visibility, .duringActivity, "autre mode : intact")

        let fresh = makeEphemeralDefaults(self)
        XCTAssertEqual(Preferences(defaults: fresh).visibility, .always, "installation neuve")
        XCTAssertNil(fresh.object(forKey: "visibility.mode"), "clé absente : toujours, rien à enregistrer")
    }

    /// Sans l'onglet Claude, « Quand Claude est ouvert » n'est plus proposé et vaut « Toujours ».
    func testVisibilityWithoutClaudeTab() {
        XCTAssertEqual(NotchVisibility.choices(claudeEnabled: true), [.always, .whenClaudeOpen, .duringActivity])
        XCTAssertEqual(NotchVisibility.choices(claudeEnabled: false), [.always, .duringActivity])
        XCTAssertEqual(NotchVisibility.whenClaudeOpen.effective(claudeEnabled: false), .always)
        XCTAssertEqual(NotchVisibility.whenClaudeOpen.effective(claudeEnabled: true), .whenClaudeOpen)
        XCTAssertEqual(NotchVisibility.duringActivity.effective(claudeEnabled: false), .duringActivity)
    }

    /// Table de vérité de la règle, mode par mode.
    func testVisibilityRuleTruthTable() {
        typealias Inputs = NotchVisibilityRule.Inputs
        func show(_ mode: NotchVisibility, _ inputs: Inputs) -> Bool { NotchVisibilityRule.shouldShow(mode, inputs) }

        let idle = Inputs()
        let claudeOpen = Inputs(claudeOpen: true)
        let working = Inputs(claudeOpen: true, claudeActive: true)
        let timer = Inputs(moduleEars: true)
        // (situation, toujours, quand Claude est ouvert, pendant une activité)
        let rows: [(Inputs, Bool, Bool, Bool, String)] = [
            (idle, true, false, false, "rien"),
            (claudeOpen, true, true, false, "Claude ouvert, au repos"),
            (working, true, true, true, "session au travail ou qui attend"),
            (timer, true, true, true, "oreilles d'un module"),
            (Inputs(expanded: true), true, true, true, "panneau déplié : jamais retiré sous la souris"),
            (Inputs(onDemand: true), true, true, true, "glisser vers l'Étagère, raccourci"),
            (Inputs(claudeActive: true, hiddenByUser: true), false, false, false, "masquée par l'utilisateur"),
            (Inputs(claudeActive: true, expanded: true, hiddenForFullScreen: true), false, false, false,
             "plein écran « masquée »"),
            (Inputs(onDemand: true, hiddenByUser: true), true, true, true, "raccourci malgré le masquage"),
        ]
        for (inputs, always, open, activity, label) in rows {
            XCTAssertEqual(show(.always, inputs), always, "toujours · \(label)")
            XCTAssertEqual(show(.whenClaudeOpen, inputs), open, "Claude ouvert · \(label)")
            XCTAssertEqual(show(.duringActivity, inputs), activity, "activité · \(label)")
        }
    }

    // MARK: - Masquage temporaire

    func testTemporaryHideWithInjectedClock() throws {
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Paris"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 14, minute: 30)))

        XCTAssertFalse(prefs.isHidden(at: now))
        prefs.hide(.oneHour, now: now, calendar: calendar)
        XCTAssertEqual(prefs.hiddenUntil, now.addingTimeInterval(3600))
        XCTAssertTrue(prefs.isHidden(at: now.addingTimeInterval(3599)))
        XCTAssertFalse(prefs.isHidden(at: now.addingTimeInterval(3600)), "échu pile à l'heure")

        // « Jusqu'à demain » : 8 h le lendemain, pas minuit (masquée à 23 h 30, elle serait revenue 30 min après).
        prefs.hide(.untilTomorrow, now: now, calendar: calendar)
        let tomorrowMorning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 8)))
        XCTAssertEqual(prefs.hiddenUntil, tomorrowMorning)
        XCTAssertTrue(prefs.isHidden(at: tomorrowMorning.addingTimeInterval(-1)))
        XCTAssertFalse(prefs.isHidden(at: tomorrowMorning))
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23,
                                                                           minute: 30)))
        XCTAssertEqual(HideDuration.untilTomorrow.end(from: lateEvening, calendar: calendar), tomorrowMorning)

        prefs.hide(.untilReactivated, now: now, calendar: calendar)
        XCTAssertEqual(prefs.hiddenUntil, .distantFuture)
        XCTAssertTrue(prefs.isHidden(at: now.addingTimeInterval(365 * 86_400)))
        prefs.showAgain()
        XCTAssertNil(prefs.hiddenUntil)
        XCTAssertFalse(prefs.isHidden(at: now))
    }

    func testTemporaryHidePersistsAndNoticeText() throws {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        prefs.hide(.oneHour, now: now)
        XCTAssertEqual(Preferences(defaults: defaults).hiddenUntil, now.addingTimeInterval(3600))
        prefs.showAgain()
        XCTAssertNil(Preferences(defaults: defaults).hiddenUntil)
        XCTAssertNil(defaults.object(forKey: "visibility.hiddenUntil"), "clé retirée")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9)))
        XCTAssertEqual(HiddenNotice.text(until: .distantFuture, now: morning, calendar: calendar),
                       "Notch masquée jusqu'à réactivation")
        let sameDay = HiddenNotice.text(until: morning.addingTimeInterval(3600), now: morning, calendar: calendar)
        XCTAssertTrue(sameDay.hasPrefix("Notch masquée jusqu'à "), sameDay)
        XCTAssertFalse(sameDay.contains("demain"), sameDay)
        XCTAssertTrue(sameDay.contains("10"), "heure de fin affichée : \(sameDay)")
        // 23 h 30 + 1 h : le lendemain à 0 h 30, avec l'heure (pas un simple « demain »).
        let late = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 30)))
        let pastMidnight = HiddenNotice.text(until: late.addingTimeInterval(3600), now: late, calendar: calendar)
        XCTAssertTrue(pastMidnight.hasPrefix("Notch masquée jusqu'à demain, "), pastMidnight)
        XCTAssertTrue(pastMidnight.contains("30"), "heure de fin affichée : \(pastMidnight)")
        let tomorrow = HiddenNotice.text(until: HideDuration.untilTomorrow.end(from: morning, calendar: calendar),
                                         now: morning, calendar: calendar)
        XCTAssertTrue(tomorrow.hasPrefix("Notch masquée jusqu'à demain, "), tomorrow)
        XCTAssertTrue(tomorrow.contains("8"), "heure de fin affichée : \(tomorrow)")
        // Plus loin (horloge changée, valeur écrite à la main) : la date aussi.
        let later = HiddenNotice.text(until: morning.addingTimeInterval(3 * 86_400), now: morning, calendar: calendar)
        XCTAssertTrue(later.hasPrefix("Notch masquée jusqu'à "), later)
        XCTAssertFalse(later.contains("demain"), later)
        XCTAssertTrue(later.contains("23"), "jour affiché : \(later)")
    }

    // MARK: - Taille, couleurs, comportement

    func testCustomWidthIsClampedAndStepped() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertNil(prefs.customPanelWidth)
        XCTAssertEqual(prefs.expandedWidth(compact: false), PanelSize.standard.width)

        prefs.customPanelWidth = 633
        XCTAssertEqual(prefs.customPanelWidth, 630, "pas de 10")
        XCTAssertEqual(prefs.expandedWidth(compact: false), 630)
        XCTAssertEqual(prefs.expandedWidth(compact: true), Preferences.compactPanelWidth, "plein écran compact")
        XCTAssertEqual(Preferences(defaults: defaults).customPanelWidth, 630)

        prefs.customPanelWidth = 2000
        XCTAssertEqual(prefs.customPanelWidth, 720)
        prefs.customPanelWidth = 100
        XCTAssertEqual(prefs.customPanelWidth, 460)
        XCTAssertEqual(Preferences(defaults: defaults).customPanelWidth, 460)

        defaults.set(9999.0, forKey: "appearance.customPanelWidth")
        XCTAssertEqual(Preferences(defaults: defaults).customPanelWidth, 720, "defaults write hors bornes")
        defaults.set(Double.nan, forKey: "appearance.customPanelWidth")
        XCTAssertNil(Preferences(defaults: defaults).customPanelWidth)

        prefs.customPanelWidth = nil
        prefs.panelSize = .large
        XCTAssertEqual(Preferences(defaults: defaults).expandedWidth(compact: false), PanelSize.large.width)
    }

    /// Fond libre clair : assombri (même teinte) pour que le texte blanc du panneau garde un contraste ≥ 9:1.
    func testLightCustomBackgroundIsDarkened() throws {
        func luminance(_ color: Color) throws -> Double {
            let srgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            func linear(_ c: CGFloat) -> Double {
                let c = Double(c)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(srgb.redComponent) + 0.7152 * linear(srgb.greenComponent)
                + 0.0722 * linear(srgb.blueComponent)
        }
        let prefs = Preferences(defaults: makeEphemeralDefaults(self))
        prefs.panelBackground = .custom
        for hex in ["F2F2F2", "FFFFFF", "FFE066", "8FD3FF"] {
            prefs.customBackgroundHex = hex
            let light = try luminance(prefs.panelColor)
            XCTAssertLessThanOrEqual(light, Preferences.maxBackgroundLuminance + 0.002, hex)
            XCTAssertGreaterThanOrEqual((1 + 0.05) / (light + 0.05), 9, "contraste du texte blanc · \(hex)")
            XCTAssertGreaterThan(light, Preferences.maxBackgroundLuminance - 0.02, "assombri juste ce qu'il faut · \(hex)")
        }
        // Même teinte : le jaune reste plus rouge que bleu.
        prefs.customBackgroundHex = "FFE066"
        let yellow = try XCTUnwrap(NSColor(prefs.panelColor).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(yellow.redComponent, yellow.blueComponent + 0.2)
        // Fonds sombres inchangés.
        for hex in ["3A1F5D", "1C1C1E", "000000"] {
            prefs.customBackgroundHex = hex
            XCTAssertEqual(prefs.panelColor.hexString, hex)
        }
    }

    func testColorsAndBehaviorPersist() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.panelBackground, .black)
        XCTAssertEqual(prefs.panelColor.hexString, "000000")
        XCTAssertFalse(prefs.tintCollapsed)
        XCTAssertEqual(prefs.virtualNotchStyle, .notch)
        XCTAssertTrue(prefs.panelShadow)
        XCTAssertEqual(prefs.animationSpeed, .normal)
        XCTAssertEqual(prefs.openTrigger, .hover)
        XCTAssertFalse(prefs.closeOnClickOutside)
        XCTAssertEqual(prefs.screenChoice, ScreenChoice.builtin)
        XCTAssertFalse(prefs.hideFromCapture)

        prefs.panelBackground = .graphite
        XCTAssertEqual(prefs.panelColor.hexString, PanelBackground.graphite.hex)
        prefs.panelBackground = .midnight
        XCTAssertEqual(prefs.panelColor.hexString, PanelBackground.midnight.hex)
        prefs.panelBackground = .custom
        prefs.customBackgroundHex = "3A1F5D"
        prefs.tintCollapsed = true
        prefs.virtualNotchStyle = .pill
        prefs.panelShadow = false
        prefs.animationSpeed = .gentle
        prefs.openTrigger = .click
        prefs.closeOnClickOutside = true
        prefs.screenChoice = "DELL U2720Q"
        prefs.hideFromCapture = true

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.panelBackground, .custom)
        XCTAssertEqual(reloaded.customBackgroundHex, "3A1F5D")
        XCTAssertEqual(reloaded.panelColor.hexString, "3A1F5D")
        XCTAssertEqual(defaults.string(forKey: "appearance.customBackground"), "3A1F5D", "rangée en hexadécimal")
        XCTAssertTrue(reloaded.tintCollapsed)
        XCTAssertEqual(reloaded.virtualNotchStyle, .pill)
        XCTAssertFalse(reloaded.panelShadow)
        XCTAssertEqual(reloaded.animationSpeed, .gentle)
        XCTAssertEqual(reloaded.openTrigger, .click)
        XCTAssertTrue(reloaded.closeOnClickOutside)
        XCTAssertEqual(reloaded.screenChoice, "DELL U2720Q")
        XCTAssertTrue(reloaded.hideFromCapture)

        // Valeurs illisibles : valeurs par défaut.
        defaults.set("violet", forKey: "appearance.customBackground")
        defaults.set("arc-en-ciel", forKey: "appearance.background")
        defaults.set("éclair", forKey: "appearance.animationSpeed")
        defaults.set("", forKey: "display.screen")
        let fallback = Preferences(defaults: defaults)
        XCTAssertEqual(fallback.customBackgroundHex, Preferences.defaultCustomBackground)
        XCTAssertEqual(fallback.panelBackground, .black)
        XCTAssertEqual(fallback.animationSpeed, .normal)
        XCTAssertEqual(fallback.screenChoice, ScreenChoice.builtin)
    }

    func testAnimationSpeedAndReduceMotion() {
        XCTAssertEqual(NotchMotion.animation(.normal, reduceMotion: false), notchSpring, "Normale = ressort validé")
        XCTAssertNotEqual(NotchMotion.animation(.fast, reduceMotion: false), notchSpring)
        XCTAssertNotEqual(NotchMotion.animation(.gentle, reduceMotion: false), notchSpring)
        for speed in AnimationSpeed.allCases {
            XCTAssertEqual(NotchMotion.animation(speed, reduceMotion: true), .easeInOut(duration: 0.18), "fondu simple")
        }
    }

    // MARK: - Raccourcis

    func testHotKeyCarbonMapping() {
        XCTAssertNil(HotKeyChoice.none.carbon)
        let cmd = UInt32(cmdKey), option = UInt32(optionKey), control = UInt32(controlKey)
        XCTAssertEqual(HotKeyChoice.optionCommandN.carbon?.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(HotKeyChoice.optionCommandN.carbon?.modifiers, option | cmd)
        XCTAssertEqual(HotKeyChoice.controlOptionSpace.carbon?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(HotKeyChoice.controlOptionSpace.carbon?.modifiers, control | option)
        XCTAssertEqual(HotKeyChoice.controlCommandN.carbon?.keyCode, UInt32(kVK_ANSI_N))
        XCTAssertEqual(HotKeyChoice.controlCommandN.carbon?.modifiers, control | cmd)
        XCTAssertEqual(HotKeyChoice.optionCommandJ.carbon?.keyCode, UInt32(kVK_ANSI_J))
        XCTAssertEqual(HotKeyChoice.optionCommandJ.carbon?.modifiers, option | cmd)
        // Valeurs Carbon attendues (HIToolbox) : N = 45, J = 38, Espace = 49 ; ⌘ = 256, ⌥ = 2048, ⌃ = 4096.
        XCTAssertEqual(HotKeyChoice.optionCommandN.carbon?.keyCode, 45)
        XCTAssertEqual(HotKeyChoice.optionCommandJ.carbon?.keyCode, 38)
        XCTAssertEqual(HotKeyChoice.controlOptionSpace.carbon?.keyCode, 49)
        XCTAssertEqual(HotKeyChoice.optionCommandN.carbon?.modifiers, 2048 + 256)
        XCTAssertEqual(HotKeyChoice.controlOptionSpace.carbon?.modifiers, 4096 + 2048)
        XCTAssertEqual(Set(HotKeyChoice.allCases.compactMap { $0.carbon.map { "\($0.keyCode)-\($0.modifiers)" } }).count,
                       HotKeyChoice.allCases.count - 1, "combinaisons distinctes")
    }

    func testHotKeysPersistAndNeverShareACombination() {
        let defaults = makeEphemeralDefaults(self)
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.toggleHotKey, .none)
        XCTAssertEqual(prefs.hideHotKey, .none)

        prefs.toggleHotKey = .optionCommandN
        prefs.hideHotKey = .controlCommandN
        XCTAssertEqual(Preferences(defaults: defaults).toggleHotKey, .optionCommandN)
        XCTAssertEqual(Preferences(defaults: defaults).hideHotKey, .controlCommandN)

        prefs.hideHotKey = .optionCommandN
        XCTAssertEqual(prefs.toggleHotKey, .none, "une combinaison ne sert qu'à une chose")
        prefs.toggleHotKey = .optionCommandN
        XCTAssertEqual(prefs.hideHotKey, .none)

        // Même combinaison écrite à la main dans les deux clés : la seconde est ignorée.
        defaults.set("optionCommandJ", forKey: "keyboard.togglePanel")
        defaults.set("optionCommandJ", forKey: "keyboard.toggleHidden")
        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.toggleHotKey, .optionCommandJ)
        XCTAssertEqual(reloaded.hideHotKey, .none)
    }

    func testPanelKeyCommands() {
        func parse(_ key: Int, _ flags: NSEvent.ModifierFlags = [], editing: Bool = false) -> NotchKeyCommand? {
            NotchKeyCommand.parse(keyCode: UInt16(key), modifiers: flags, editingText: editing)
        }
        XCTAssertEqual(parse(kVK_Escape), .close)
        XCTAssertEqual(parse(kVK_LeftArrow, [.function, .numericPad]), .previousTab, "flèches : fn + pavé")
        XCTAssertEqual(parse(kVK_RightArrow, [.function, .numericPad]), .nextTab)
        XCTAssertEqual(parse(kVK_ANSI_1, .command), .tab(0))
        XCTAssertEqual(parse(kVK_ANSI_9, .command), .tab(8))
        XCTAssertNil(parse(kVK_ANSI_1), "chiffre seul : au champ de texte")
        XCTAssertNil(parse(kVK_ANSI_1, [.command, .shift]))
        XCTAssertNil(parse(kVK_LeftArrow, .shift), "sélection au clavier")
        XCTAssertNil(parse(kVK_Escape, editing: true), "Échap dans un champ : au champ")
        XCTAssertNil(parse(kVK_LeftArrow, editing: true))
        XCTAssertEqual(parse(kVK_ANSI_2, .command, editing: true), .tab(1), "⌘2 marche même dans un champ")

        XCTAssertEqual(NotchKeyCommand.nextTab.target(current: 6, count: 7), 0, "boucle")
        XCTAssertEqual(NotchKeyCommand.previousTab.target(current: 0, count: 7), 6)
        XCTAssertEqual(NotchKeyCommand.tab(3).target(current: 0, count: 7), 3)
        XCTAssertNil(NotchKeyCommand.tab(8).target(current: 0, count: 7), "⌘9 sans neuvième onglet")
        XCTAssertNil(NotchKeyCommand.close.target(current: 0, count: 7))
        XCTAssertNil(NotchKeyCommand.nextTab.target(current: 0, count: 0))
    }

    // MARK: - Réinitialisation

    func testResetRestoresNotchSettingsOnly() {
        let defaults = makeEphemeralDefaults(self)
        defaults.set(false, forKey: "alwaysVisible")
        let prefs = Preferences(defaults: defaults)
        prefs.visibility = .duringActivity
        prefs.hide(.untilReactivated)
        prefs.openTrigger = .click
        prefs.closeOnClickOutside = true
        prefs.openDelay = 0.4
        prefs.closeDelay = 1.2
        prefs.hapticFeedback = false
        prefs.toggleHotKey = .optionCommandN
        prefs.hideHotKey = .controlCommandN
        prefs.fullScreenBehavior = .hidden
        prefs.screenChoice = ScreenChoice.mouse
        prefs.hideFromCapture = true
        prefs.accentHex = "4C8DFF"
        prefs.panelSize = .large
        prefs.customPanelWidth = 700
        prefs.panelBackground = .custom
        prefs.customBackgroundHex = "112233"
        prefs.tintCollapsed = true
        prefs.virtualNotchStyle = .chameleon
        prefs.backgroundOpacity = 0.7
        prefs.panelShadow = false
        prefs.animationSpeed = .fast
        prefs.showEars = false
        prefs.earTabsMode = .retracted
        // Hors périmètre : onglets et réglages des modules.
        prefs.tabOrder = ["timer", "claude"]
        prefs.tabEnabled = ["notes": false]
        prefs.defaultTab = "timer"
        prefs.replyFromNotch = true
        prefs.autoUpdate = false

        prefs.resetNotchSettings()

        let fresh = Preferences(defaults: makeEphemeralDefaults(self))
        for current in [prefs, Preferences(defaults: defaults)] {
            XCTAssertEqual(current.visibility, fresh.visibility)
            XCTAssertEqual(current.visibility, .always, "l'ancienne clé alwaysVisible ne revient pas")
            XCTAssertNil(current.hiddenUntil)
            XCTAssertEqual(current.openTrigger, fresh.openTrigger)
            XCTAssertEqual(current.closeOnClickOutside, fresh.closeOnClickOutside)
            XCTAssertEqual(current.openDelay, fresh.openDelay)
            XCTAssertEqual(current.closeDelay, fresh.closeDelay)
            XCTAssertEqual(current.hapticFeedback, fresh.hapticFeedback)
            XCTAssertEqual(current.toggleHotKey, .none)
            XCTAssertEqual(current.hideHotKey, .none)
            XCTAssertEqual(current.fullScreenBehavior, fresh.fullScreenBehavior)
            XCTAssertEqual(current.screenChoice, fresh.screenChoice)
            XCTAssertEqual(current.hideFromCapture, fresh.hideFromCapture)
            XCTAssertEqual(current.accentHex, fresh.accentHex)
            XCTAssertEqual(current.panelSize, fresh.panelSize)
            XCTAssertNil(current.customPanelWidth)
            XCTAssertEqual(current.panelBackground, fresh.panelBackground)
            XCTAssertEqual(current.customBackgroundHex, fresh.customBackgroundHex)
            XCTAssertEqual(current.tintCollapsed, fresh.tintCollapsed)
            XCTAssertEqual(current.virtualNotchStyle, fresh.virtualNotchStyle)
            XCTAssertEqual(current.backgroundOpacity, fresh.backgroundOpacity)
            XCTAssertEqual(current.panelShadow, fresh.panelShadow)
            XCTAssertEqual(current.animationSpeed, fresh.animationSpeed)
            XCTAssertEqual(current.showEars, fresh.showEars)
            XCTAssertEqual(current.earTabsMode, fresh.earTabsMode)
            XCTAssertEqual(current.earTabsMode, .visible)

            XCTAssertEqual(current.tabOrder, ["timer", "claude"])
            XCTAssertEqual(current.tabEnabled, ["notes": false])
            XCTAssertEqual(current.defaultTab, "timer")
            XCTAssertTrue(current.replyFromNotch)
            XCTAssertFalse(current.autoUpdate)
        }
    }
}
