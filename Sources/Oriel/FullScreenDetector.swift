import AppKit

/// Une app est-elle en plein écran sur l'écran de la notch ?
/// Critère : une fenêtre normale (couche 0) de l'app au premier plan couvre tout l'écran, barre des menus
/// comprise ; une fenêtre simplement agrandie s'arrête sous la barre des menus. Ni le titre ni le contenu des
/// fenêtres ne sont lus : pas besoin de l'autorisation d'enregistrement de l'écran.
enum FullScreenDetector {
    static func frontmostAppIsFullScreen(onDisplay display: CGDirectDisplayID) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return isFullScreen(windows: windows, pid: app.processIdentifier, displayBounds: CGDisplayBounds(display))
    }

    /// `windows` : entrées de CGWindowList ; `displayBounds` : coordonnées globales (origine en haut à gauche).
    static func isFullScreen(windows: [[String: Any]], pid: pid_t, displayBounds: CGRect) -> Bool {
        guard !displayBounds.isEmpty else { return false }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw) else { return false }
            // Un point de tolérance : arrondis des écrans à échelle non entière.
            return bounds.insetBy(dx: -1, dy: -1).contains(displayBounds)
        }
    }
}
