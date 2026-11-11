# Oriel

A native macOS app that turns your MacBook's notch into a small panel for everyone. Hover the notch and it unfolds
with a player, your agenda and its meetings, quick settings, a shelf, a clipboard history, a timer, quick notes, and,
if you want them, your messages and emails. If you use Claude Code or Codex, two optional tabs follow their sessions
and let you answer them from the notch. Neither is needed to use the app.

> **First time opening it?** macOS blocks the first launch: see [First launch](#first-launch) (30 seconds).
> **Formerly Claude Notch.** Updating from 2.1 or earlier: see [the note below](#updates).

<p align="center">
  <img src="docs/collapsed.png" width="380" alt="Collapsed notch: a raised hand on the left ear, 2·2 on the right ear">
</p>
<p align="center">
  <img src="docs/expanded.png" width="620" alt="Expanded panel with three sessions: one waiting for permission, one running a command with a task list, one done">
</p>

Interface in English and French (follows the system language). Screenshots use sample data.

*Not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.*

[Version française](README.fr.md) · [Full guide](docs/GUIDE.md)

## Features

- **Ten tabs, each one optional**: Player (with a week of your calendar), Agenda (your next meeting and its **Join**
  button), Quick Settings (Wi-Fi, Bluetooth, Focus, Low Power Mode, caffeine, fans, batteries, scenes), Shelf,
  Clipboard, Timer and Pomodoro, Quick notes, and, off by default, Messages, Mail and Microphone & Camera. Hide them,
  reorder them or pick the default one in Settings › Tabs, or right in the notch.
- **Index tabs on the collapsed notch**: the track playing, the timer, the next meeting, unread messages… each gets a
  small tab against the notch. Hover it for its details, click it to open its tab.
- **Pop-ups** for a message, an email, the end of a timer or an upcoming event. During a meeting or while a microphone
  is in use, they hide the sender and the text.
- **Command bar**: `t 25` starts a timer, `n idea` creates a note, `c link` searches your copies, `s presentation`
  applies a scene. Nothing runs before Return.
- **Bubble**: drag the corner of the open panel and the notch peels off into a bubble you can put anywhere.
- **Screens without a notch** (external display, Mac without one): a tiny pearl during an activity, which turns into a
  frosted-glass notch when the pointer comes close.
- **Your scripts** can show a short status beside the notch: `notch run -- make` shows an hourglass, then ✓ or ✗.
- **Health** (Settings › Health): what Oriel runs and costs. The notch calms its animations on its own in Low Power
  Mode or when the Mac runs hot.

Optional, if you use these coding agents:

- **Claude Code**: the state of each session at a glance (thinking, running a tool, waiting for you, done), its task
  list and subagents, and, if you turn it on, answers from the notch: allow or deny a permission, answer a question,
  approve a plan, write to a session.
- **Codex** (CLI or ChatGPT app): the same tracking, and approvals from the notch.
- **Quota gauges** for the 5-hour and 7-day windows of both.

Every tab and setting in detail: [docs/GUIDE.md](docs/GUIDE.md).

## Installation

1. Download `Oriel-<version>.dmg` from the [Releases](https://github.com/Slybald/oriel/releases) page.
2. Open it and drag **Oriel** onto **Applications**.
3. Optional: check the download against the `.sha256` file published next to it:
   `shasum -a 256 -c Oriel-<version>.dmg.sha256` (run it in the download folder).

### First launch

Oriel is not notarized (there is no Apple Developer account behind it; releases are signed with a
self-signed certificate), so macOS blocks it the first time you open it. This is not malware: you only have to
tell macOS once. The same steps are in a text file inside the DMG.

- **macOS 13 and 14**: right-click (or Control-click) **Oriel** in Applications › **Open** › **Open**.
- **macOS 15 and later**: open Oriel, dismiss the alert, go to **System Settings › Privacy & Security**,
  scroll down and click **Open Anyway** next to the message about Oriel, then confirm.
- Or, in Terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Oriel.app
  ```

The certificate is the same for every release, so macOS recognises each update as the same app and keeps the
accesses you granted (calendar, Bluetooth, Automation, folders). Older versions were signed ad hoc, a signature
that changes with every build: when you move to the first release signed with the certificate, macOS asks for
these accesses one last time, then no longer.

On first launch, a short setup assistant lets you pick your tabs and how the panel opens. **Skip** is always there
and changes nothing. Details: [Setup assistant](docs/GUIDE.md#setup-assistant).

### Requirements

- macOS 13 Ventura or later, Apple silicon or Intel.
- For the Claude tab only: Claude Code (CLI, or the Code tab of Claude Desktop).
- For the Codex tab only: Codex (the ChatGPT app, or the `codex` command), versions 0.154 (command) and 0.162 (app)
  tested, with hooks on (the default).
- Claude Code configuration in `~/.claude`. `CLAUDE_CONFIG_DIR` is not supported by the app: the hooks are
  always installed in `~/.claude`.

## Updates

Oriel updates itself from the [Releases](https://github.com/Slybald/oriel/releases) page.

- 60 seconds after launch, then every 6 hours, the app asks GitHub for the latest release
  (`api.github.com`; only the app version is sent, in the User-Agent). Drafts and pre-releases are ignored.
- A newer version is downloaded with its signature (`Oriel-<version>.dmg.sig`) and installed only if
  its Ed25519 signature matches the public key built into the app. A DMG without a signature, or with an
  invalid one, is refused and nothing is installed.
- At launch, a new version is installed right away; later on, only when no session is running or waiting
  for you (otherwise the app tries again every 10 minutes). The app then restarts by itself and the **…** menu
  shows "Updated to X".
- Automatic installation needs the app in `/Applications` or `~/Applications`, in a folder you can write to.
  Otherwise the **…** menu offers to open the release page.
- To turn it off: **…** menu › uncheck **Automatic Updates**. New versions are then only announced in the
  menu, with an **Install** button. **Check for Updates** checks right away.
- Apps built from source (`scripts/build.sh`, `scripts/install.sh`) never update themselves: the menu shows
  "Development build: updates disabled".
- **Updating from 2.1 or earlier** (when the app was still called Claude Notch): the automatic update cannot
  cross the rename. Download `Oriel-<version>.dmg` once by hand and drag **Oriel** onto Applications (it replaces
  the old app), then grant again the macOS accesses it asks for. Your settings, notes and hooks are picked up
  at the first launch (the data folder, the open-at-login option and the Claude Code hooks are
  moved to the new names; the Codex hooks keep their approval). From then on, updates are automatic again. If you had turned on the fan or low-power
  authorization, do it again in Settings; the old rules can be removed with
  `sudo rm /etc/sudoers.d/claude-notch-*` and `sudo rm /Library/PrivilegedHelperTools/io.github.slybald.claudenotch.fanctl`.

## Privacy

- Everything stays on your Mac: no account, no analytics. The only outgoing requests are the update check and the
  download of new versions from GitHub.
- The app listens on `127.0.0.1` only, and every request needs a token that only your account can read.
- Nothing is approved by default: when the notch does not answer a Claude or Codex request, it goes back to the
  terminal.
- Clipboard: copies from password managers are never recorded, and the history stays in memory unless you choose to
  keep it.
- macOS permissions are asked only when you use the feature that needs them, never at launch.

What the app reads and writes, and each permission: [Privacy](docs/GUIDE.md#privacy) and
[macOS permissions](docs/GUIDE.md#macos-permissions) in the guide.

## Uninstall

**…** menu › **Uninstall Oriel…** removes the hooks (Claude Code's, and Codex's if you installed them) and what the app
installed, then quits.
Then drag `Oriel.app` from Applications to the Trash.

## Documentation

- [Guide](docs/GUIDE.md): every tab and setting, privacy and permissions in detail, how it works, limitations.
- [Local API](docs/API.md): the `notch` command and the HTTP API for your scripts.
- [Development](docs/DEVELOPMENT.md): build, tests, release.
- [Architecture](docs/ARCHITECTURE.md): code map and design decisions.

## License

[MIT](LICENSE).

Third-party code: `Vendor/mediaremote-adapter` (ungive/mediaremote-adapter, BSD-3-Clause, copied without changes).
Its notice is listed in **About › Licenses**.
