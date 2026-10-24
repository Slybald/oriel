import Foundation

// Traductions de l'interface. La clé est le texte français ; Resources/en.lproj/Localizable.strings donne
// l'anglais, Resources/fr.lproj le français (identité). scripts/build.sh copie ces dossiers dans l'app.
// Hors de l'app (swift test), Bundle.main n'a aucune traduction : la clé, donc le français, est rendue.
//
// Text("littéral") de SwiftUI se traduit seul. Tout texte visible construit en String passe par L(…).
// LocalizationTests vérifie que chaque clé utilisée a sa traduction anglaise, table par table.
//
// Chaque module a sa propre table (Resources/<langue>.lproj/<Module>.strings) : L("Lecteur", table: "Media"),
// ou Text("…", tableName: "Media") en SwiftUI. Sans table : Localizable.

/// Texte traduit dans la langue de l'interface, lu dans `table` (nil = Localizable).
func L(_ key: String, table: String? = nil) -> String {
    NSLocalizedString(key, tableName: table, comment: "")
}

/// Clé au singulier ou au pluriel selon `count`, traduite mais pas encore formatée :
/// `String(format: L(n, one: "%d agent", other: "%d agents"), n)`.
func L(_ count: Int, one: String, other: String, table: String? = nil) -> String {
    L(Localization.usesSingular(count) ? one : other, table: table)
}

enum Localization {
    /// Langue retenue par macOS parmi les traductions de l'app (« en » ou « fr »).
    static let isEnglish = Bundle.main.preferredLocalizations.first == "en"

    /// Règle du pluriel : en français 0 et 1 sont au singulier, en anglais seul 1 l'est.
    static func usesSingular(_ count: Int, english: Bool = isEnglish) -> Bool {
        english ? count == 1 : count <= 1
    }
}
