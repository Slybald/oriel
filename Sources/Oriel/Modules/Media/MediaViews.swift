import SwiftUI

// MARK: - Onglet

/// Lecteur à gauche, calendrier à droite ; chacun se masque dans les réglages et l'autre prend la place.
struct MediaPanel: View {
    @ObservedObject var module: MediaModule
    @Environment(\.notchContentWidth) private var width

    static let height: CGFloat = 150
    static let spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.spacing) {
            if module.showPlayer {
                PlayerCard(module: module)
            }
            if module.showCalendar {
                CalendarCard(module: module)
                    .frame(width: module.showPlayer ? ((width - Self.spacing) * 0.46).rounded() : nil)
            }
            if !module.showPlayer, !module.showCalendar {
                cardMessage(symbol: "eye.slash", title: L("Lecteur et calendrier masqués", table: "Media"),
                            detail: L("Réglages › Lecteur", table: "Media"))
                    .modifier(MediaCard())
            }
        }
        .frame(height: Self.height)
    }
}

/// Carte arrondie, comme les cartes de session.
struct MediaCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Palette.card))
    }
}

/// État vide ou d'erreur d'une demi-carte : centré, un cran plus petit que dans les autres onglets.
private func cardMessage(symbol: String, tint: Color = Palette.accent, title: String, detail: String? = nil,
                         progress: Bool = false, action: ModuleAction? = nil) -> some View {
    ModuleEmptyState(symbol: symbol, tint: tint, title: title, detail: detail, progress: progress, compact: true,
                     action: action)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}

// MARK: - Lecteur

struct PlayerCard: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        Group {
            if module.playerStatus == .unavailable {
                cardMessage(symbol: "speaker.slash", tint: Palette.amber,
                            title: L("Lecture en cours indisponible", table: "Media"),
                            detail: L("macOS ne donne pas accès au morceau en cours.", table: "Media"),
                            action: ModuleAction(title: L("Réessayer", table: "Media"), style: .warning,
                                                 run: module.retryPlayer))
            } else if let info = module.nowPlaying {
                playing(info)
            } else if module.playerStatus == .checking {
                cardMessage(symbol: "music.note", title: L("Connexion au lecteur…", table: "Media"), progress: true)
            } else {
                cardMessage(symbol: "music.note", title: L("Aucune lecture", table: "Media"),
                            detail: L("Lance un morceau dans Musique, Spotify ou ton navigateur.", table: "Media"))
            }
        }
        .modifier(MediaCard())
    }

    private func playing(_ info: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: module.openSourceApp) {
                    ArtworkView(image: module.artwork, size: 60)
                }
                .buttonStyle(.plain)
                .help(String(format: L("Ouvrir %@", table: "Media"), info.appName ?? info.bundleIdentifier))
                .accessibilityLabel(String(format: L("Ouvrir %@", table: "Media"), info.appName ?? info.bundleIdentifier))
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.primary)
                    if let artist = info.artist {
                        Text(artist)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.secondary)
                    }
                    if let app = info.appName {
                        Text(app)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 1)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            if info.duration != nil {
                PlaybackProgress(info: info, seek: module.seek)
            }
            Spacer(minLength: 0)
            HStack(spacing: 26) {
                MediaControlButton(symbol: "backward.fill", size: 14, label: L("Précédent", table: "Media")) {
                    module.send(.previous)
                }
                MediaControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 20,
                                   label: info.isPlaying ? L("Pause", table: "Media") : L("Lecture", table: "Media")) {
                    module.send(.togglePlayPause)
                }
                MediaControlButton(symbol: "forward.fill", size: 14, label: L("Suivant", table: "Media")) {
                    module.send(.next)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Pochette réduite ; sans pochette, un dégradé de la couleur d'accent et une note.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Palette.accent.opacity(0.6), Palette.accent.opacity(0.18)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

/// Temps écoulé, barre (glisser pour avancer si la durée est connue), temps restant. Rafraîchie chaque seconde
/// pendant la lecture seulement, et seulement panneau ouvert (la vue n'existe pas sinon).
struct PlaybackProgress: View {
    let info: NowPlaying
    let seek: (TimeInterval) -> Void
    @State private var dragFraction: Double?

    /// Même branche pendant un glissement : changer de branche annulerait le geste.
    var body: some View {
        if info.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { context in row(at: context.date) }
        } else {
            row(at: Date())
        }
    }

    private func row(at date: Date) -> some View {
        let duration = info.duration ?? 0
        let position = dragFraction.map { $0 * duration } ?? info.position(at: date) ?? 0
        let fraction = duration > 0 ? min(1, position / duration) : 0
        return HStack(spacing: 8) {
            Text(verbatim: MediaFormat.clock(position))
                .frame(width: 36, alignment: .trailing)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Palette.accent).frame(width: proxy.size.width * fraction)
                }
                .frame(height: dragFraction == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in dragFraction = min(1, max(0, value.location.x / proxy.size.width)) }
                    .onEnded { _ in
                        if let dragFraction { seek(dragFraction * duration) }
                        dragFraction = nil
                    })
                .allowsHitTesting(info.canSeek)
            }
            .frame(height: 12)
            Text(verbatim: "-" + MediaFormat.clock(max(0, duration - position)))
                .frame(width: 40, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundColor(Palette.secondary)
        .animation(ModuleStyle.hover, value: dragFraction == nil)
    }
}

/// Bouton de contrôle : symbole seul, halo au survol.
struct MediaControlButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Palette.primary)
                .frame(width: size + 16, height: size + 12)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Calendrier

struct CalendarCard: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        Group {
            switch module.calendarAccess {
            case .notDetermined:
                cardMessage(symbol: "calendar", title: L("Ton agenda dans la notch", table: "Media"),
                            action: ModuleAction(title: L("Autoriser l'accès au calendrier", table: "Media"),
                                                 style: .prominent, run: module.requestCalendarAccess))
            case .denied:
                cardMessage(symbol: "calendar.badge.exclamationmark", tint: Palette.amber,
                            title: L("Accès au calendrier refusé", table: "Media"),
                            action: ModuleAction(title: L("Ouvrir Réglages Système", table: "Media"), style: .warning,
                                                 run: module.openCalendarPrivacySettings))
            case .granted:
                week
            }
        }
        .modifier(MediaCard())
        .onAppear(perform: module.calendarAppeared)
        .onDisappear(perform: module.calendarDisappeared)
    }

    private var week: some View {
        let days = MediaCalendarMath.week(containing: module.selectedDay)
        let dayEvents = MediaCalendarMath.events(module.events, on: module.selectedDay)
        return VStack(alignment: .leading, spacing: 6) {
            header(days)
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    dayButton(day, hasEvents: !MediaCalendarMath.events(module.events, on: day).isEmpty)
                }
            }
            if dayEvents.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").font(.system(size: 11, weight: .medium))
                    Text(Calendar.current.isDateInToday(module.selectedDay)
                         ? L("Rien aujourd'hui", table: "Media") : L("Rien ce jour-là", table: "Media"))
                }
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(dayEvents) { event in
                            EventRow(event: event) { module.openCalendar(at: module.selectedDay) }
                        }
                    }
                }
                // Plus de trois événements : la liste défile, le bas s'estompe pour le montrer.
                .bottomFade(dayEvents.count > 3, height: 16)
            }
        }
    }

    private func header(_ days: [Date]) -> some View {
        HStack(spacing: 2) {
            Text(MediaFormat.month(module.selectedDay))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !days.contains(where: Calendar.current.isDateInToday) {
                Button {
                    module.selectedDay = Calendar.current.startOfDay(for: Date())
                } label: {
                    Text("Aujourd'hui", tableName: "Media")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 2)
            }
            weekButton("chevron.left", label: L("Semaine précédente", table: "Media"), by: -7)
            weekButton("chevron.right", label: L("Semaine suivante", table: "Media"), by: 7)
        }
    }

    private func weekButton(_ symbol: String, label: String, by days: Int) -> some View {
        ModuleIconButton(symbol: symbol, label: label, box: 20, size: 10, weight: .bold) {
            if let day = Calendar.current.date(byAdding: .day, value: days, to: module.selectedDay) {
                module.selectedDay = day
            }
        }
    }

    private func dayButton(_ day: Date, hasEvents: Bool) -> some View {
        let calendar = Calendar.current
        let today = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: module.selectedDay)
        return Button {
            module.selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: MediaFormat.weekday(day))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.system(size: 11.5, weight: today ? .bold : .medium).monospacedDigit())
                    .foregroundColor(Palette.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(today ? Palette.accent : Color.white.opacity(selected ? 0.16 : 0)))
                Circle()
                    .fill(Color.white.opacity(hasEvents ? 0.5 : 0))
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(notchSpring, value: selected)
        .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Événement : couleur du calendrier, heure (ou « Journée »), titre. Un clic ouvre Calendrier à ce jour.
struct EventRow: View {
    let event: MediaEvent
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3, height: 13)
                Text(event.isAllDay ? L("Journée", table: "Media") : MediaFormat.time(event.start))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 42, alignment: .leading)
                Text(event.title.isEmpty ? L("Sans titre", table: "Media") : event.title)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(ModuleStyle.shape(ModuleStyle.itemRadius)
                .fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .help(L("Ouvrir dans Calendrier", table: "Media"))
    }
}

// MARK: - Plein écran compact

/// Morceau en cours sur une ligne, prochain événement sur une autre ; rien si rien à dire.
struct MediaCompactView: View {
    @ObservedObject var module: MediaModule

    private var showsPlayer: Bool { module.showPlayer && module.nowPlaying != nil }
    private var showsCalendar: Bool { module.showCalendar && module.calendarAccess == .granted }

    /// Rien à dire : aucune vue, donc pas d'espace vide dans le panneau compact.
    var body: some View {
        if showsPlayer || showsCalendar {
            summary
                .onAppear(perform: module.calendarAppeared)
                .onDisappear(perform: module.calendarDisappeared)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if module.showPlayer, let info = module.nowPlaying {
                ModuleSummaryRow {
                    ArtworkView(image: module.artwork, size: 20)
                    Text(info.artist.map { "\(info.title) — \($0)" } ?? info.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Palette.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    MediaControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 11,
                                       label: info.isPlaying ? L("Pause", table: "Media") : L("Lecture", table: "Media")) {
                        module.send(.togglePlayPause)
                    }
                }
            }
            if showsCalendar {
                // Relu chaque minute : un événement terminé laisse la place au suivant.
                TimelineView(.everyMinute) { context in
                    let next = MediaCalendarMath.next(module.events, after: context.date)
                    ModuleSummaryRow {
                        ModuleSummaryIcon(symbol: "calendar")
                        Text(next.map(MediaFormat.upcoming) ?? L("Aucun événement à venir", table: "Media"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(next == nil ? Palette.secondary : Palette.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .onTapGesture { if let next { module.openCalendar(at: next.start) } }
                }
            }
        }
    }
}

/// Intercalaire de lecture déployé (survol, notch repliée) : pochette, titre, artiste et les trois commandes.
struct MediaTabDetailView: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        if let info = module.nowPlaying {
            ModuleSummaryRow {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        ArtworkView(image: module.artwork, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: info.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Palette.primary)
                            if let artist = info.artist {
                                Text(verbatim: artist)
                                    .font(.system(size: 11))
                                    .foregroundColor(Palette.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        MediaControlButton(symbol: "backward.fill", size: 11, label: L("Précédent", table: "Media")) {
                            module.send(.previous)
                        }
                        MediaControlButton(symbol: info.isPlaying ? "pause.fill" : "play.fill", size: 14,
                                           label: info.isPlaying ? L("Pause", table: "Media") : L("Lecture", table: "Media")) {
                            module.send(.togglePlayPause)
                        }
                        MediaControlButton(symbol: "forward.fill", size: 11, label: L("Suivant", table: "Media")) {
                            module.send(.next)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Réglages

/// Réglages › Lecteur : lecteur, oreilles, calendrier et calendriers affichés.
struct MediaSettingsView: View {
    @ObservedObject var module: MediaModule
    @State private var calendars: [MediaCalendarInfo] = []

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $module.showPlayer) { Text("Afficher le lecteur", tableName: "Media") }
                Toggle(isOn: $module.playerEars) { Text("Oreilles pendant la lecture", tableName: "Media") }
                    .disabled(!module.showPlayer)
                LabeledContent {
                    Text(playerStatus)
                        .foregroundColor(module.playerStatus == .unavailable ? Palette.amber : .secondary)
                } label: {
                    Text("État", tableName: "Media")
                }
            } header: {
                Text("Lecture en cours", tableName: "Media")
            } footer: {
                SettingsNote(L("Notch repliée : pochette et égaliseur tant qu'un morceau joue.", table: "Media"))
            }
            Section {
                Toggle(isOn: Binding(get: { module.showCalendar }, set: { isOn in
                    module.showCalendar = isOn
                    if isOn { module.requestCalendarAccess() }
                })) {
                    Text("Afficher le calendrier", tableName: "Media")
                }
                switch module.calendarAccess {
                case .notDetermined:
                    Button(action: module.requestCalendarAccess) {
                        Text("Autoriser l'accès au calendrier", tableName: "Media")
                    }
                case .denied:
                    LabeledContent {
                        Button(action: module.openCalendarPrivacySettings) {
                            Text("Ouvrir Réglages Système", tableName: "Media")
                        }
                    } label: {
                        Text("Accès au calendrier refusé", tableName: "Media").foregroundColor(Palette.amber)
                    }
                case .granted:
                    ForEach(calendars) { calendar in
                        Toggle(isOn: shown(calendar.id)) {
                            HStack(spacing: 8) {
                                Circle().fill(calendar.color).frame(width: 9, height: 9)
                                Text(calendar.title)
                                Text(calendar.source).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Calendrier", tableName: "Media")
            } footer: {
                SettingsNote(L("Lu seulement quand l'onglet est affiché. Un clic ouvre l'événement.", table: "Media"))
            }
        }
        .onAppear { module.refreshCalendarAccess() }
        .onDisappear { module.releaseCalendarIfIdle() }
        .task(id: module.calendarAccess) {
            module.calendar.calendars { calendars = $0 }
        }
    }

    private var playerStatus: String {
        switch module.playerStatus {
        case .checking: return L("Vérification…", table: "Media")
        case .ready: return L("Disponible", table: "Media")
        case .unavailable: return L("Indisponible", table: "Media")
        }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { !module.hiddenCalendars.contains(id) },
                set: { isOn in
                    if isOn { module.hiddenCalendars.remove(id) } else { module.hiddenCalendars.insert(id) }
                })
    }
}

// MARK: - Formats

enum MediaFormat {
    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let monthFormatter = formatter("LLLLyyyy")
    private static let timeFormatter = formatter("jmm")
    private static let dayTimeFormatter = formatter("EEEjmm")
    private static let weekdayFormatter = formatter("EEEEE")

    /// « Octobre 2026 ».
    static func month(_ date: Date) -> String {
        let text = monthFormatter.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// « 14:30 » (ou « 2:30 PM » selon le Mac).
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// Initiale du jour de la semaine (« L », « M »…).
    static func weekday(_ date: Date) -> String { weekdayFormatter.string(from: date).uppercased() }

    /// Prochain événement du mode compact : « 14:30 · Revue », « jeu. 09:00 · Revue » s'il n'est pas aujourd'hui.
    static func upcoming(_ event: MediaEvent) -> String {
        let when = Calendar.current.isDateInToday(event.start) ? time(event.start) : dayTimeFormatter.string(from: event.start)
        return "\(when) · \(event.title.isEmpty ? L("Sans titre", table: "Media") : event.title)"
    }

    /// « 3:07 », « 1:02:45 ».
    static func clock(_ seconds: TimeInterval) -> String {
        // Borné : `Int(1e308)` arrêterait l'app.
        let total = seconds.isFinite ? Int(min(max(0, seconds), 1e9)) : 0
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
