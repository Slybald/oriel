import SwiftUI

// MARK: - Couleurs d'état

extension AgendaPhase {
    /// Neutre loin, ambre à 5 minutes, vert pendant le rendez-vous.
    var tint: Color {
        switch self {
        case .soon: return Palette.secondary
        case .imminent: return Palette.amber
        case .running: return Palette.green
        }
    }
}

// MARK: - Onglet

/// Prochain rendez-vous en grand, le reste de la journée dessous, la semaine en haut.
struct AgendaPanel: View {
    @ObservedObject var module: AgendaModule

    var body: some View {
        Group {
            switch module.access {
            case .notDetermined:
                ModuleEmptyState(symbol: "calendar", title: L("Ton agenda dans la notch", table: "Agenda"),
                                 detail: L("Le prochain rendez-vous s'affiche à côté de la notch, avec un bouton pour le rejoindre.",
                                           table: "Agenda"),
                                 action: ModuleAction(title: L("Autoriser l'accès au calendrier", table: "Agenda"),
                                                      style: .prominent, run: module.requestAccess))
                    .padding(.vertical, 12)
            case .denied:
                ModuleEmptyState(symbol: "calendar.badge.exclamationmark", tint: Palette.amber,
                                 title: L("Accès au calendrier refusé", table: "Agenda"),
                                 detail: L("Autorise l'app dans Réglages Système › Confidentialité et sécurité › Calendriers.",
                                           table: "Agenda"),
                                 action: ModuleAction(title: L("Ouvrir Réglages Système", table: "Agenda"),
                                                      style: .warning, run: module.openPrivacySettings))
                    .padding(.vertical, 12)
            case .granted:
                day
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: module.panelAppeared)
    }

    // Relu chaque minute tant que l'onglet est à l'écran : « dans 4 min » ne reste pas figé.
    private var day: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let calendar = Calendar.current
            let isToday = calendar.isDateInToday(module.selectedDay)
            let next = isToday ? MediaCalendarMath.next(module.events, after: now) : nil
            let list = MediaCalendarMath.events(module.events, on: module.selectedDay).filter { $0.id != next?.id }
            VStack(alignment: .leading, spacing: 8) {
                AgendaWeekStrip(module: module)
                if let next {
                    AgendaHeroCard(module: module, event: next, now: now)
                }
                if list.isEmpty, next == nil {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar").font(.system(size: 11, weight: .medium))
                        Text(isToday ? L("Rien aujourd'hui", table: "Agenda") : L("Rien ce jour-là", table: "Agenda"))
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                } else if !list.isEmpty {
                    FadingScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(list) { event in
                                AgendaRow(event: event, now: now) { module.openCalendar(at: event.start) }
                            }
                        }
                    }
                    .frame(maxHeight: next == nil ? 230 : 150)
                }
            }
        }
    }
}

/// La semaine de `selectedDay`, un jour par case, avec une pastille quand il y a des rendez-vous.
struct AgendaWeekStrip: View {
    @ObservedObject var module: AgendaModule

    var body: some View {
        let days = MediaCalendarMath.week(containing: module.selectedDay)
        HStack(spacing: 2) {
            ModuleIconButton(symbol: "chevron.left", label: L("Semaine précédente", table: "Agenda"), box: 20, size: 10,
                             weight: .bold) { shift(-7) }
            ForEach(days, id: \.self) { day in
                dayButton(day, hasEvents: !MediaCalendarMath.events(module.events, on: day).isEmpty)
            }
            ModuleIconButton(symbol: "chevron.right", label: L("Semaine suivante", table: "Agenda"), box: 20, size: 10,
                             weight: .bold) { shift(7) }
        }
    }

    private func shift(_ days: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: days, to: module.selectedDay) {
            module.selectedDay = day
        }
    }

    private func dayButton(_ day: Date, hasEvents: Bool) -> some View {
        let calendar = Calendar.current
        let today = calendar.isDateInToday(day)
        let selected = calendar.isDate(day, inSameDayAs: module.selectedDay)
        return Button {
            module.selectedDay = day
        } label: {
            VStack(spacing: 1) {
                Text(verbatim: MediaFormat.weekday(day))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                Text(verbatim: "\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: today ? .bold : .medium).monospacedDigit())
                    .foregroundColor(Palette.primary)
                    .frame(width: 24, height: 24)
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

/// « Prochain » : le rendez-vous à venir (ou en cours) en grand, avec « Rejoindre » quand il a un lien.
struct AgendaHeroCard: View {
    @ObservedObject var module: AgendaModule
    let event: MediaEvent
    let now: Date

    private var phase: AgendaPhase? { AgendaMath.phase(of: event, at: now) }
    private var running: Bool { event.start <= now }
    private var tint: Color { running ? Palette.green : (phase == .imminent ? Palette.amber : Palette.secondary) }
    /// Cadre coloré seulement quand il faut s'y mettre : à 5 minutes (ambre) et en cours (vert).
    private var outlined: Bool { running || phase == .imminent }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(running ? L("En cours", table: "Agenda") : L("Prochain", table: "Agenda"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(outlined ? tint : Palette.secondary)
                Spacer(minLength: 6)
                if !running {
                    Text(verbatim: AgendaFormat.until(event.start, from: now))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(outlined ? tint : Palette.secondary)
                }
            }
            Text(event.title.isEmpty ? L("Sans titre", table: "Agenda") : event.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Palette.primary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Label(AgendaFormat.range(event), systemImage: "clock")
                if let meeting = event.meeting {
                    Label(meeting.provider.name, systemImage: "video")
                } else if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin.and.ellipse")
                }
            }
            .labelStyle(AgendaDetailLabelStyle())
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(Palette.secondary)
            .lineLimit(1)
            HStack(spacing: 10) {
                if event.meeting != nil {
                    AgendaJoinButton(title: L("Rejoindre", table: "Agenda")) { module.join(event) }
                    Text("Ouvre le lien du rendez-vous", tableName: "Agenda")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { module.openCalendar(at: event.start) } label: {
                    Text("Voir dans Calendrier", tableName: "Agenda")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModuleStyle.shape(ModuleStyle.cardRadius).fill(Palette.card))
        .overlay(ModuleStyle.shape(ModuleStyle.cardRadius)
            .strokeBorder(outlined ? tint.opacity(0.75) : .clear, lineWidth: 1))
    }
}

/// Icône et texte d'une ligne de détail, serrés.
private struct AgendaDetailLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}

/// Bouton « Rejoindre » : le seul qui ouvre un lien de réunion.
struct AgendaJoinButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        ModuleCapsuleButton(title: title, symbol: "video.fill", style: .prominent, action: action)
            .accessibilityLabel(title)
    }
}

/// Une ligne de la journée : heure, couleur du calendrier, titre et lieu ; estompée une fois terminée.
struct AgendaRow: View {
    let event: MediaEvent
    let now: Date
    let open: () -> Void
    @State private var hovering = false

    private var ended: Bool { event.end <= now && !event.isAllDay }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(event.isAllDay ? L("Journée", table: "Agenda") : MediaFormat.time(event.start))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 46, alignment: .leading)
                Capsule().fill(event.color).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title.isEmpty ? L("Sans titre", table: "Agenda") : event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.primary)
                        .lineLimit(1)
                    if let detail = detail {
                        Text(verbatim: detail)
                            .font(.system(size: 10.5))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(ModuleStyle.shape(ModuleStyle.itemRadius).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
            .opacity(ended ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(ModuleStyle.hover, value: hovering)
        .help(L("Ouvrir dans Calendrier", table: "Agenda"))
    }

    private var detail: String? {
        if let meeting = event.meeting { return meeting.provider.name }
        return event.location.isEmpty ? nil : event.location
    }
}

/// « Aujourd'hui » à droite de la barre d'onglets, quand un autre jour est choisi.
struct AgendaTodayButton: View {
    @ObservedObject var module: AgendaModule

    var body: some View {
        if module.access == .granted, !Calendar.current.isDateInToday(module.selectedDay) {
            Button {
                module.selectedDay = Calendar.current.startOfDay(for: Date())
            } label: {
                Text("Aujourd'hui", tableName: "Agenda")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Intercalaire déployé et mode compact

/// Contenu de l'intercalaire déployé (survol, notch repliée) : le rendez-vous en vue et « Rejoindre ».
struct AgendaCardView: View {
    @ObservedObject var module: AgendaModule

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let focus = AgendaMath.focus(module.events, at: context.date) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(focus.event.title.isEmpty ? L("Sans titre", table: "Agenda") : focus.event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.primary)
                        .lineLimit(2)
                    Text(verbatim: detail(focus.event))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                    if focus.event.meeting != nil {
                        AgendaJoinButton(title: L("Rejoindre", table: "Agenda")) { module.join(focus.event) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func detail(_ event: MediaEvent) -> String {
        let range = AgendaFormat.range(event)
        if let meeting = event.meeting { return "\(range) · \(meeting.provider.name)" }
        return event.location.isEmpty ? range : "\(range) · \(event.location)"
    }
}

/// Plein écran compact : une ligne avec le prochain rendez-vous ; rien s'il n'y en a pas.
struct AgendaCompactView: View {
    @ObservedObject var module: AgendaModule

    var body: some View {
        if module.access == .granted {
            // Relu chaque minute : un rendez-vous terminé laisse la place au suivant.
            TimelineView(.everyMinute) { context in
                if let next = MediaCalendarMath.next(module.events, after: context.date) {
                    ModuleSummaryRow {
                        ModuleSummaryIcon(symbol: "calendar")
                        Text(verbatim: MediaFormat.upcoming(next))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Palette.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if next.meeting != nil, AgendaMath.phase(of: next, at: context.date) != nil {
                            AgendaJoinButton(title: L("Rejoindre", table: "Agenda")) { module.join(next) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Réglages

/// Réglages › Agenda : l'intercalaire et les calendriers lus.
struct AgendaSettingsView: View {
    @ObservedObject var module: AgendaModule
    @State private var calendars: [MediaCalendarInfo] = []

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: $module.showEars) { Text("Intercalaire avant un rendez-vous", tableName: "Agenda") }
            } header: {
                Text("Notch repliée", tableName: "Agenda")
            } footer: {
                SettingsNote(L("Un intercalaire compte à rebours 15 minutes avant, passe à l'ambre à 5 minutes, dit « en cours » puis disparaît.",
                               table: "Agenda"))
            }
            Section {
                switch module.access {
                case .notDetermined:
                    Button(action: module.requestAccess) {
                        Text("Autoriser l'accès au calendrier", tableName: "Agenda")
                    }
                case .denied:
                    LabeledContent {
                        Button(action: module.openPrivacySettings) {
                            Text("Ouvrir Réglages Système", tableName: "Agenda")
                        }
                    } label: {
                        Text("Accès au calendrier refusé", tableName: "Agenda").foregroundColor(Palette.amber)
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
                Text("Calendriers", tableName: "Agenda")
            } footer: {
                SettingsNote(L("Le lien d'un rendez-vous ne s'ouvre que quand tu cliques sur « Rejoindre ».", table: "Agenda"))
            }
        }
        .onAppear { module.refreshAccess() }
        .onDisappear { module.releaseCalendarIfIdle() }
        .task(id: module.access) {
            module.calendar.calendars { calendars = $0 }
        }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { !module.hiddenCalendars.contains(id) },
                set: { isOn in
                    if isOn { module.hiddenCalendars.remove(id) } else { module.hiddenCalendars.insert(id) }
                })
    }
}
