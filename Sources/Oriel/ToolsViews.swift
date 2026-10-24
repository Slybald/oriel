import SwiftUI

/// Volet déplié dans la section outils : un seul à la fois, pour tenir dans le panneau.
enum ToolsPane: Equatable {
    case files
    case git
}

/// Section compacte sous la liste des sessions : fichiers récents, état git, usage du jour.
struct ToolsSection: View {
    @ObservedObject var feed: ToolsFeed
    @Binding var pane: ToolsPane?
    let reveal: (String) -> Void

    static let maxRepos = 5

    private var now: Date { feed.lastRefresh ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !feed.recentFiles.isEmpty {
                filesHeader
                if pane == .files {
                    VStack(spacing: 1) {
                        ForEach(feed.recentFiles) { file in
                            RecentFileRow(file: file, now: now) { reveal(file.path) }
                        }
                    }
                    .padding(.horizontal, -6)
                    .padding(.top, 5)
                }
            }
            if feed.git != nil || feed.usage != nil {
                if !feed.recentFiles.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.vertical, 7)
                }
                statusRow
                if pane == .git, let git = feed.git, !git.repos.isEmpty {
                    repoList(git)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
    }

    private func toggle(_ target: ToolsPane) {
        withAnimation(notchSpring) { pane = pane == target ? nil : target }
    }

    // MARK: Fichiers

    private var filesHeader: some View {
        let open = pane == .files
        return HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Palette.secondary)
                .frame(width: 14)
            Text("Fichiers récents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.primary)
                .fixedSize()
            if !open, let last = feed.recentFiles.first {
                Text(verbatim: "\(last.name) · \(SessionCard.relative(now.timeIntervalSince(last.date)))")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            ToolsChevron(open: open)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(.files) }
    }

    // MARK: Git et usage

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let git = feed.git {
                GitPill(status: git, open: pane == .git) { toggle(.git) }
                Spacer(minLength: 8)
                if let usage = feed.usage { usageLabel(usage) }
            } else if let usage = feed.usage {
                usageLabel(usage)
                Spacer(minLength: 0)
            }
        }
    }

    private func usageLabel(_ usage: ToolsFeed.Usage) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 10.5, weight: .medium))
            Text(usage.text)
                .font(.system(size: 11).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundColor(Palette.secondary)
        .help(usage.topProjectsText ?? "")
    }

    private func repoList(_ git: ToolsFeed.GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(git.repos.prefix(Self.maxRepos)) { repo in
                RepoRow(repo: repo) { reveal(repo.path) }
            }
            if git.repos.count > Self.maxRepos {
                let rest = git.repos.count - Self.maxRepos
                Text(String(format: L(rest, one: "et %d autre", other: "et %d autres"), rest))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 28)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, -6)
        .padding(.top, 6)
    }
}

struct ToolsChevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Palette.secondary)
            .rotationEffect(.degrees(open ? 180 : 0))
            .frame(width: 20, height: 16)
    }
}

struct RecentFileRow: View {
    let file: ToolsFeed.RecentFile
    let now: Date
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 10.5))
                .foregroundColor(Palette.secondary.opacity(file.exists ? 1 : 0.5))
                .frame(width: 14)
            Text(file.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(file.exists ? Palette.primary : Color.white.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(file.project)
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary.opacity(file.exists ? 1 : 0.6))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !file.exists {
                Text("supprimé")
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.secondary.opacity(0.8))
            }
            Text(SessionCard.relative(now.timeIntervalSince(file.date)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Palette.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(file.path)
    }
}

struct GitPill: View {
    let status: ToolsFeed.GitStatus
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let clean = status.needsAttention == 0
        let color = clean ? Palette.green : Palette.amber
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
            if !clean {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .contentShape(Capsule())
        .onTapGesture { if !clean { toggle() } }
        .help(String(format: L(status.total, one: "%d dépôt suivi par git-radar",
                               other: "%d dépôts suivis par git-radar"), status.total))
    }
}

struct RepoRow: View {
    let repo: ToolsFeed.GitRepo
    let onTap: () -> Void

    @State private var hovering = false

    private var changes: Int { repo.dirty + repo.untracked }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10.5))
                .foregroundColor(Palette.secondary)
                .frame(width: 14)
            Text(repo.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Text(repo.branch)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                if repo.error != nil {
                    badge(L("erreur"), Palette.red)
                }
                if repo.noUpstream {
                    badge(L("sans upstream"), Palette.secondary)
                }
                if repo.ahead > 0 { badge("↑\(repo.ahead)", Palette.accent) }
                if repo.behind > 0 { badge("↓\(repo.behind)", Palette.amber) }
                if changes > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Palette.amber)
                            .frame(width: 6, height: 6)
                        badge("\(changes)", Palette.amber)
                    }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.08 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(helpText)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(color)
    }

    private var helpText: String {
        var parts = [repo.path]
        func count(_ n: Int, one: String, other: String) {
            if n > 0 { parts.append(String(format: L(n, one: one, other: other), n)) }
        }
        count(repo.ahead, one: "%d commit à pousser", other: "%d commits à pousser")
        count(repo.behind, one: "%d commit à récupérer", other: "%d commits à récupérer")
        count(repo.dirty, one: "%d modifié", other: "%d modifiés")
        count(repo.untracked, one: "%d non suivi", other: "%d non suivis")
        if let error = repo.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}
