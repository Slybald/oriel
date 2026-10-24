# Oriel

A native macOS app that turns your MacBook's notch into a small panel for everyone. Hover the notch and it
unfolds with a player, your agenda and its meetings, quick settings, a shelf, a clipboard history, a timer and quick notes.
If you use Claude Code or Codex, two optional tabs follow their sessions too: state, current tool, task list,
subagents, and permissions you can answer from the notch. Neither is needed to use the app.

> **First time opening it?** macOS blocks the first launch: see [First launch](#first-launch) (30 seconds).
> **Formerly Claude Notch.** Updating from 2.1 or earlier: see [the note below](#updates).

<p align="center">
  <img src="docs/collapsed.png" width="380" alt="Collapsed notch: a raised hand on the left ear, 2·2 on the right ear">
</p>
<p align="center">
  <img src="docs/expanded.png" width="620" alt="Expanded panel with three sessions: one waiting for permission, one running a command with a task list, one done">
</p>

Interface available in English and French (follows the system language). Screenshots use sample data.

*Not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.*

[Version française plus bas](#français)

## Features

- **Session states at a glance**: ready, thinking, running a tool (with the command or the file),
  waiting for your permission, waiting for your answer, plan to review, done, error, compacting the context.
  Sessions that need you are listed first, with an amber outline.
- **Collapsed notch with index tabs**: every activity (Claude, now playing, timer, Codex, unread messages…) gets
  its own small tab against the notch, on the left and the right, the most important one closest to it (up to three
  per side, then a "+N"). Claude's tab shows its state (a raised hand when a session needs you, a spinner while Claude
  works, a check mark when a turn ends) and `active sessions·running subagents`, for example `1·6`, or the progress
  of the task list (`2/5`). The tabs fan out like cards spread on a table: the most important one on top, against the
  notch, each of the others slid under the previous one and showing only its slice with its icon. Hover a tab and it
  opens wide with its details (the track and its controls, the timer, the sessions and their state); click it to open
  the panel on that tab. Settings › Appearance: always visible, or retracted to a thin sliver each until you hover (an
  alert, like Claude waiting for you, always stays visible).
- **Permissions**: the card shows what Claude is asking for (`Terminal · rm -rf build`, the file to edit,
  the question asked).
- **Reply from the notch** (off by default; a card at the top of the Claude tab offers to turn it on, and so does
  Settings › Claude): allow or deny a permission (with an optional reason for Claude), answer a question
  (single or multiple choice, or your own text), approve a plan or ask for changes, and talk to a session
  (hover its card: **Chat**): what Claude just said, your own messages, and a field to write. It works for the
  CLI and for the Code tab of Claude Desktop. The terminal dialog (or Claude Desktop) stays usable at the same
  time: the first answer wins. Never "always allow" from the notch. Return sends, Esc closes.
- **Codex tab** (optional, see [Codex tab](#codex-tab)): the sessions of OpenAI's Codex (CLI or app), working, waiting for
  an approval or done, with the last message; allow or deny a command or a patch from the notch.
- **Quota gauges** (optional, see [Quota gauges](#quota-gauges)): a thin ring and the percentage used of the 5-hour and
  7-day windows in the Claude and Codex tabs, with the time they reset. Amber from 80 %, red from 95 %.
- **Tasks**: progress bar and current task of Claude Code's task list; the chevron unfolds the whole list.
- **Subagents**: number of subagents running in each session.
- **Click to go back**: clicking a card brings the host app to the front (Terminal, iTerm2, Ghostty, VS Code,
  Claude Desktop…). For a session in the Code tab of Claude Desktop, the click opens that exact session.
- **Claude Desktop**: a row shows whether Claude Desktop is open, with a button to bring it to the front.
- **Optional tools section**: files recently written by Claude, Git status of your repositories, today's usage.
  It only appears when its data files exist (see [Tools section](#tools-section)).
- **Seven more tabs**: Player, Agenda, Quick Settings, Shelf, Clipboard, Timer and Quick notes (see [Tabs](#tabs)).
- **Your own index tabs** (optional, see [Scripts](#scripts-local-api-and-notch-command)): `notch run -- make` shows an
  hourglass, then ✓ or ✗ with the duration; any script can show a short status through a local API.
- **Command bar**: one field, one-key prefixes (see [Command bar](#command-bar)): `t 25` starts a timer, `n idea`
  creates a note, `c link` searches your copies, `s presentation` applies a scene, `> message` writes to Claude.
- Works on screens without a notch too (external display, closed lid): a small notch is drawn at the top
  center of the screen.

<p align="center">
  <img src="docs/tools.png" width="620" alt="Expanded panel with the tools section: recent files, two Git repositories to deal with, today's usage">
</p>

## Tabs

The expanded notch is a row of tabs. Click a tab, or hover it for a moment. All tabs are on by default, except Claude
and Codex when they are not found on the Mac, and Messages and Mail, which stay off until you turn them on. In **Settings › Tabs** you can hide a tab (a hidden tab does no work),
change the order, or pick the tab that opens by default. You can also do it in the notch, like apps on an iPhone:
press and hold the tab bar, then drag the icons, hide a tab with **−** or bring one back with **+**, and click **Done**
(or press Esc, or click outside the bar). The panel reopens on the last tab you used, or on Claude (or Codex) when a session
needs you.

- **Claude**: your sessions, with their state, permissions, questions and plans. Optional: on first launch it is
  on only if Claude Code is found on the Mac (`~/.claude` or `$CLAUDE_CONFIG_DIR`). Off, nothing Claude-related
  runs: no process scan, no session tracking, hook events ignored.
- **Codex**: your Codex sessions, with their state and approvals (see [Codex tab](#codex-tab)). Optional like Claude: on at
  first launch only if Codex is found on the Mac (`~/.codex`, the Codex app, or the `codex` command). Off, nothing
  Codex-related runs.
- **Player**: the track playing in Music, Spotify or your browser, with artwork, progress (drag to seek) and
  controls. Below it, a week view of your calendar: click an event to open it in Calendar.
- **Agenda**: your next appointment, large, with a **Join** button that opens its Zoom, Meet, Teams, Webex or FaceTime
  link, and the rest of the day below. On the collapsed notch it becomes an index tab that counts down (discreet from
  15 minutes before, amber at 5, green `now` while it runs); no polling, nothing runs between two thresholds. A link is
  only opened when you click **Join**.
- **Quick Settings**: Wi-Fi, Bluetooth, Focus, Low Power Mode, caffeine (keeps the Mac awake for 1 h, 2 h or
  without limit), the battery of the Mac and of your AirPods, and three scenes: Battery, Normal and Presentation.
- **Shelf**: files and folders to keep at hand. Drop them on the notch, even when it is collapsed, and drag them
  out to Finder or another app. The shelf keeps a reference to each item: nothing is copied.
- **Clipboard**: your recent copies (text, links, images, files, colors). Click one to copy it again; nothing is
  pasted for you. Copies made in password managers are not recorded.
- **Timer**: a countdown, or a Pomodoro cycle with the focus and break lengths you set. It keeps counting through
  sleep and restarts.
- **Quick notes**: plain-text notes. Pin the ones you use, delete with undo, and search once you have more than
  eight.
- **Messages** (off by default): your recent iMessage and SMS conversations, an unread badge on the collapsed notch
  and a quick reply. It reads the Messages database on your Mac, which needs Full Disk Access; nothing is stored or
  sent anywhere. Limits: the unread badge covers the last 30 days and can differ from the Dock's; a group
  conversation only opens the Messages app.
- **Mail** (off by default): the unread count of Apple Mail and your latest 3 to 5 received emails (sender, subject,
  the start of the text, time, a dot when unread). Click one to open it in Mail; hover it and click **Reply** to
  write an answer right in the notch. The reply is sent only when you click **Send** (or press Return), and **Continue
  in Mail** opens Mail's own reply window with your text already typed. If Mail does not confirm within 60 s, the
  notch says so and asks you to check before trying again. Oriel never launches Mail: it only reads it while it is
  open.

## Command bar

A field in the notch to do things without looking for the right tab. Open it with its shortcut (Settings › General ›
Shortcuts, none by default) or from **…** › **Command Bar…**, type, press Return. Nothing runs before Return (or a
click on the row), and Esc closes it.

| Type | What it does |
|---|---|
| `t 25`, `t 1h30`, `25 min` | Starts a timer (`t` alone: 25, 5 and 10 minutes, and the Pomodoro) |
| `n some idea` | Creates a quick note |
| `c link` | Searches the clipboard history; Return copies the entry again |
| `s presentation` | Applies a Quick Settings scene (Battery Saver, Presentation, Normal); with a fixed fan speed, `s fans` gives the fans back to macOS |
| `m invoice` | Searches the latest emails of the Mail tab; Return opens the email in Mail |
| `a team` | Lists today's and tomorrow's appointments; Return joins the meeting (known link) or opens Calendar on that day |
| `i backup` | Removes an index tab put up by one of your scripts (or all of them) |
| `> run the tests again` | Writes to a Claude session (the same channel as the chat field; needs "Reply from the notch") |

The prefixes are listed under the field and clickable. A prefix is one letter followed by a space (`>` needs no space);
anything else is plain text, which only a duration with its unit (`25 min`), or a scene, an email or an appointment
with three letters or more, can answer. When the names do not fit, only the keys are shown. The search ignores case and accents and forgives missing letters in short texts (`prsnt` finds
Presentation). The bar asks only the tabs that are on and running: a hidden tab is not woken up, a turned-off Claude tab
has no `>`. The clipboard and your scripts' tabs are never searched without
their prefix. No natural language, no permission, nothing leaves your Mac.

## Reply from the notch

Off by default: the Claude tab shows a card (**Turn On** / **Later**) and **Settings › Claude** has the switch.
Then Claude Code waits for your answer in the notch as well as in the terminal or in Claude Desktop:

- **Permissions**: allow or deny a tool call, with an optional reason that Claude reads. The notch never offers
  "always allow".
- **Questions**: pick one answer or several, or write your own.
- **Plans**: approve a plan, or ask for changes.
- **Conversation**: hover a session card and click **Chat**. You see Claude's last messages (what it said when it
  stopped, what its subagents reported), what you wrote, and a field to write to Claude. The message reaches
  Claude after the current action, or starts a new turn (about 3 s) if Claude was waiting. Click a long message
  to unfold it.

The terminal dialog stays usable: the first answer wins. If the notch gives no answer in time (4 seconds when its
card never appeared, about 590 seconds otherwise), the request goes back to the terminal. The same happens when the
app is closed or the setting is off, so nothing is ever approved by default.

**Claude Desktop (Code tab).** Checked with Claude Code 2.1.304, started the way the Code tab starts it: the
permission hook is called and its decision applied (in "bypass permissions" mode nothing asks for permission, but
questions still reach the notch), a question answered from the notch is received by Claude, and a message sent
from the notch wakes Claude (a new turn about 3 s later, or read after the current action). Plans were not checked
with Desktop. How the Desktop window shows a turn started from the notch was not checked either.

When the notch cannot write to a session (`claude -p`, the Agent SDK, an IDE, or a session opened before the hook
script was updated) the conversation says "Answer in *app*" with an **Open** button instead of a field. A session
opened before the update gets replies only after it restarts.

## Codex tab

Codex has hooks of its own, so the tab works like Claude's. It follows Codex wherever it runs: the **ChatGPT app**
(which now contains Codex), the `codex` command in a terminal, or an editor.

1. **Settings › Codex › Install Codex hooks** (the tab's button opens it). This adds one entry per event to
   `~/.codex/hooks.json` (timestamped backup first, your own hooks stay) and copies `codex-notch-hook.sh` to
   `~/.codex/hooks/`. Your `notify` is never touched.
2. **Approve the hooks in Codex.** Codex ignores a new hook until it is approved, and says nothing about it. The tab and
   Settings › Codex show where you are (*not installed*, *waiting for approval in Codex*, *active*). While approval is
   pending, click **Approve in Codex**: the app asks Codex itself to trust the 8 Oriel hooks, and only those (the
   request behind the **Review hooks** button of the ChatGPT app). You can also review them yourself there, or with
   `/hooks` in a terminal. The tab updates on its own as soon as they are approved.
3. **Start a new conversation** in the ChatGPT app (or run `codex`). Conversations that were already open when the hooks
   were approved are not tracked.
4. Each card shows the project, the app (ChatGPT, Terminal, VS Code…), the model, what Codex is doing (the command or
   the file), and its last message. Click a card to bring that app to the front; for a ChatGPT app session it opens
   the conversation itself.

**Approve from the notch** (Settings › Codex, off by default): when Codex asks to run a command or apply a patch, the
card shows it, with **Allow**, **Deny** and **In the terminal**. Unlike Claude Code, Codex waits for the notch before
asking in the terminal, so the hold is short: 4 seconds if the card never appeared, 60 seconds otherwise, then Codex asks
you itself. Nothing is approved by default, and there is no "always allow". Not possible: writing a message to a
running Codex session, or answering Codex's own questions.

## Scripts: local API and `notch` command

Off by default (**Settings › Scripts**). Once on, your scripts and programs can put up to three small index tabs of
their own beside the collapsed notch, with a short text, an icon and a color from fixed lists, for up to an hour. Install
the `notch` command from the same pane (it goes to `~/.local/bin`, only on your click):

```sh
notch show --title "Backup done" --text OK --icon externaldrive.fill --color green
notch run -- make test
```

No code is loaded into the app and nothing is run from a tab: the only action is a button that opens an app you named.
Only programs of your account that read the token file can call it, never a web page; a script's tab always says which
program sent it and can never pass for a Claude or Codex request. HTTP details, limits and the security model:
[docs/API.md](docs/API.md).

## Quota gauges

A thin ring, the percentage used and the time of the next reset, for the 5-hour and 7-day windows, under the sessions of
the **Claude** tab and of the **Codex** tab (and in the summary that unfolds when you hover their collapsed tab). Amber
from 80 %, red from 95 %. Nothing is shown when a tab is off, or when the agent gives no figure.

- **Claude** (Settings › Claude › Show quota, off by default). Claude Code gives the quota (`rate_limits`) to its
  `statusLine` and nowhere else, and allows one `statusLine` command only. So the switch puts a small relay in its place in
  `~/.claude/settings.json` (timestamped backup first). The relay sends the data to the app (127.0.0.1, with the token),
  then runs **your previous command** with the same data, so your status line does not change (without one, it prints
  `5h 39% · 7d 63%`). Turning the switch off, or uninstalling Oriel, puts your command back. Only for claude.ai Pro
  and Max subscribers, and only after the first answer of a session. The figures belong to the account, so any session
  updates them. The app keeps the percentages and reset times in memory; the rest of what the status line receives
  (folder, model, session) is dropped. Measured with Claude Code 2.1.304: nothing before the first answer, then both windows.
- **Codex** (Settings › Codex › Show quota, on by default). Nothing to install: while the panel is open, the app asks Codex
  itself (`codex app-server`, request `account/rateLimits/read`, about 1 s) at most once a minute, then every 5 minutes.
  Measured with the Codex command 0.154 and the ChatGPT app's Codex 0.162. It needs a ChatGPT sign-in: with an API key Codex
  answers with an error and no gauge shows. A summary seen on a collapsed tab hides a figure older than 15 minutes.

## Notch settings

Open **…** › **Settings…** (⌘,).

- **Visibility**: always visible (the default), only while Claude is open (offered with the Claude tab on), or
  only during an activity: a session working, waiting or just finished, or a tab showing ears (a timer, the
  player).
- **Hide the notch** for 1 hour, until tomorrow, or until you show it again. The same options are in the **…** menu
  and in the right-click menu of the collapsed notch.
- **Opening**: on hover (with an opening delay) or on click. **Close on click outside** keeps the panel open until
  you click elsewhere, instead of closing it when the mouse leaves.
- **Shortcuts** (none by default): one opens or closes the panel, one hides or shows the notch, one opens the
  [command bar](#command-bar). They work everywhere, without the Accessibility permission. Once the panel is open from the keyboard, ← and → switch tabs,
  ⌘1 to ⌘9 jump to a tab, and Esc closes it.
- **Size and look**: panel width (compact, standard, large, or a custom width from 460 to 720 pt), background (black,
  graphite, midnight blue or a custom color), opacity, shadow, accent color and animation speed. With "Reduce
  motion" on in macOS, the animations become a simple fade.
- **Screen**: the built-in display (the default), the main display, the display under the mouse, or a display
  picked by name. A screen without a notch gets a virtual one at the top center.
- **Bubble**: drag the bottom right corner of the open panel, and the notch peels off into a bubble you can put
  anywhere, its tabs in a revolver cylinder (scroll or click to turn, click the centre to open; the back button, Esc,
  a click outside or a pinch brings you back to the cylinder). Bring it close to the notch, which pulls it in like
  ferrofluid, double-click its edge or choose **Reattach to Notch**. It can be turned off, and can return to the notch at
  each relaunch.
- **Privacy**: hide the notch from screenshots and screen sharing. This depends on the app that captures the screen.
- **Profile**: **Change Profile…** starts you from a profile (Developer, Student, Creative or Minimal): it shows
  the tabs it will show and hide, the opening mode and the ears, and changes nothing until you confirm. Your tab
  data and the hooks are never touched; hidden tabs come back from **Settings › Tabs**. The pane names the profile
  that matches your tabs, or "Custom".
- **Setup assistant**: **Run the Setup Assistant Again** goes through the first-launch steps again, starting from
  your current settings.
- **Reset to defaults**, after a confirmation. Tabs, their data and the hooks are not changed.

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

On first launch, a setup assistant lets you pick what you need, in four short steps. **Skip** is always there and
changes nothing; nothing is written before you click **Apply**.

1. **Welcome and profile**: what the notch is, and an optional profile: Developer (Claude and Codex if found,
   clipboard, timer, notes), Student (agenda, player and calendar, timer, notes, quick settings), Creative (player and
   calendar, shelf, clipboard) or Minimal (player and calendar, quick settings). It ticks the tabs, sets how the
   panel opens and the ears; the next steps start from it, and everything stays editable. Without a choice,
   nothing changes.
2. **Tabs**: one card per tab, tick the ones you want (at least one stays on). The Claude card is offered only when
   Claude Code is found on the Mac, and with it an unticked option to install the Claude Code hooks: they add
   Oriel's entries to `~/.claude/settings.json` (a timestamped backup is written next to it first, and your
   existing hooks are kept) and install the hook script in `~/.claude/hooks/`. Without Claude Code, a line says
   where to turn the Claude tab on later (**Settings › Tabs**).
3. **Behavior**: open on hover or on click, an optional keyboard shortcut, and open at login.
4. **Done**: a preview of your notch with the chosen tabs, and where to find everything (the **…** menu, Settings).

The assistant never asks for a macOS permission (calendar, Bluetooth…): macOS asks only when you use the tab that
needs one. It is shown once, and not after an update from a version that was already set up. To run it again:
**Settings › General › Run the Setup Assistant Again**. The hooks can also be installed later from
**Settings › Claude**; sessions that were already open show up at their next message.

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

- Everything stays on your Mac. Oriel sends no data about you or your sessions: no analytics. Its only
  outgoing requests are the update check to `api.github.com` and the download of new versions from GitHub
  (see [Updates](#updates)).
- The app listens on `127.0.0.1:47823` only, on the loopback interface: it cannot be reached from the network.
- The hook script only talks to that local address, with `curl`. Every request carries a token that the app
  generates at each launch and writes to `~/Library/Application Support/Oriel/hook-token` (readable by
  your account only); curl reads it from that file, so it never shows in the process list. The app refuses any
  request without it, with another `Host` than `127.0.0.1:47823`, or with an `Origin` header (a web page).
  The other way round, a decision or a message from the app carries a second secret (`hook-proof`, same
  folder, never sent by the script): without it, the script ignores the answer, so a program that takes the
  port while the app is closed (another account on a shared Mac) decides nothing.
- Replies from the notch: the app only ever answers a request made by a Claude Code hook, after a click in the
  notch. No route lets another program decide in your place, and there is no "always allow". When anything
  fails (app not running, setting off, delay over), the hook hands control back to the terminal: never an
  approval by default.
- **Clipboard**: while the app runs, the Clipboard tab checks the clipboard once a second, and reads its content only
  when it has changed and passes the privacy checks. Copies marked as concealed, transient or auto-generated by a
  password manager are never recorded, nor are copies made from Keychain Access, Passwords, 1Password, Bitwarden,
  Dashlane or KeePassXC (the list can be edited). By default the history stays in memory and is cleared when you
  quit the app or turn the tab off. If you keep it across restarts, only text and links are written, never images
  or files. Pausing the capture stops the checks until the next launch.
- What the app reads: the hook events (Claude Code and Codex), the end of the transcript of a running session (to detect Esc),
  Claude Code's task files, the process list (to find the host app), the track playing and its artwork (Player),
  the events of the calendars you chose to show, the state of Wi-Fi and Bluetooth, and the battery level. With the quota on:
  the percentages and reset times that Claude Code gives to its status line (relayed, kept in memory) and that Codex
  returns when asked.
- What the app writes: the logs and token files in `~/Library/Application Support/Oriel/` (see
  [Shared logs](#shared-logs)), and the data of the tabs in the same folder: `shelf.json` (references to your
  files), `notes.json`, `timer.json`, and `clipboard-history.json` only if you keep the history. These files are
  readable by your account only. Also the hooks in `~/.claude` when you ask for it, and the Codex hooks (`~/.codex/hooks.json` and
  `~/.codex/hooks/codex-notch-hook.sh`) when you ask for it, and, when you turn the Claude quota on, `oriel-statusline.sh`
  and a copy of your previous status line command (readable by you only) in `~/.claude/hooks/` and the `statusLine` of
  `~/.claude/settings.json`; `~/.codex/config.toml` is only read (to show the state of the
  hooks), never written by the app: the approval of the hooks, when you click **Approve in Codex**, is written by Codex
  itself (the app starts `codex app-server` for a moment, with a minimal environment). During an update the DMG in
  `~/Library/Caches/io.github.slybald.oriel/updates/` (deleted afterwards) and the new app in place of
  the old one. The messages you type are sent to the Claude Code session only, never stored.

## macOS permissions

Oriel asks for a permission only when you use the feature that needs it. Nothing is requested at launch.

- **Calendars** (full access): your week and events in the Player tab, and the next appointment of the Agenda tab
  (including its countdown on the collapsed notch). Asked when you press the calendar's button, **Allow Calendar
  Access** or turn the option on.
- **Automation: Calendar** (Apple Events): to open a day or an event in Calendar. macOS asks the first time.
- **Bluetooth**: to read the state of Bluetooth and switch it from Quick Settings. Asked when you first use the
  Bluetooth tile, or a scene that changes it.
- **Notifications**: to announce the end of a timer. Asked when you start your first timer. Without it, the sound
  and the "Done" ear still signal the end.
- **Paste from other apps** (macOS 15.4 and later): so the Clipboard tab can read what you copy. macOS may ask each
  time, or block it. When it is blocked, nothing is recorded, and the tab and the settings link to System Settings.
- **Full Disk Access** (Messages tab, off by default): to read the Messages database. macOS has no dialog for it: add
  Oriel yourself in System Settings › Privacy & Security › Full Disk Access, then relaunch the app. Without it
  the tab says so and links to System Settings.
- **Contacts** (Messages tab): to show contact names instead of numbers. Asked when you click **Allow** in the tab.
- **Automation: Messages** (Apple Events): to send a quick reply. macOS asks the first time you send.
- **Automation: Mail** (Apple Events): to read the latest emails and to send the reply you write. Asked when you click
  **Allow** in the Mail tab.
- **Desktop, Documents, Downloads**: only for the optional companion tools (see [Tools section](#tools-section)).
- Wi-Fi: the network name is not read, so Location is not requested. If macOS refuses to change the Wi-Fi state,
  the tile says so.
- Low Power Mode needs administrator rights (`pmset`). The first change asks for your password or Touch ID once
  and, in the same prompt, adds a system rule limited to turning this mode on and off
  (`/etc/sudoers.d/oriel-lowpower`); later changes need no password. "Remove the authorization" in Settings
  or uninstalling removes it.
- Fixed fan speed needs root to write to the SMC. The first fixed speed asks for your password once and installs a
  small helper (`/Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl`) and a system rule that allows
  only this helper (`/etc/sudoers.d/oriel-fans`). Reading speeds and temperatures needs nothing. "Remove the
  authorization" in Settings or uninstalling removes both.

## How it works

- Each hook event is relayed by `curl` to `http://127.0.0.1:47823/hook`, along with the hook's parent process
  ID and a few environment variables. These hooks are declared `async: true`: they add no latency to Claude.
- Two more kinds of hooks serve "Reply from the notch":
  - `PermissionRequest` also runs the script synchronously (`permission` mode, 600 s timeout). The terminal
    dialog shows up at the same time and stays usable; the first answer wins. The app holds the request until
    you click, and otherwise answers "no decision": after 4 s if you have not opened its card in the notch,
    after about 590 s if you have, as soon as the tool runs or the turn moves on, or when you answer in the
    terminal. With the setting off, the hook returns at once.
  - `SessionStart` and `Stop` start a waiting hook (`inbox` mode, `asyncRewake`): it waits in the background
    for a message typed in the notch, then hands it to Claude, who starts a turn (about 3 s). During a turn, the
    message is read after the current action. Without a waiting hook (session opened before the hooks were
    updated, app restarted), the message is queued until the end of the turn. Messages are capped at
    1,800 bytes and control characters are removed. Sessions without a terminal (`claude -p`, the Agent SDK,
    IDEs) do not get messages from the notch: there, Claude waits for this hook before reading the prompt (or
    before exiting), so the app lets it go at once. The Code tab of Claude Desktop is the exception, at the end of
    a turn only (`Stop`; the script sends the Desktop session ID): the turn result has already gone out and the
    next prompt does not wait, whereas held at `SessionStart` the hook delayed the first prompt by the whole wait
    (measured with Claude Code 2.1.304). When a Desktop session is closed, SIGTERM ends it at once; closing its
    input leaves Claude up to about 30 s.
- Codex: its hooks use the same local server (`/codex/hook`, and `/codex/permission` for the synchronous
  `PermissionRequest` hook), the same token and the same proof. Codex runs that hook *before* its own prompt and
  waits for it, so the app holds a request for 4 s if its card was never shown and for 60 s once it was, then
  answers "no decision" and Codex asks in the terminal (hook timeout: 75 s).
- After an update of the app, hooks installed by a previous version are updated silently, with the usual
  timestamped backup of `settings.json`.
- From that process ID, the app walks up the process tree to find the Claude process (to detect the end of
  the session) and the host app (Terminal, iTerm2, Ghostty, VS Code, Claude Desktop…). A session with Claude
  Desktop among its ancestors is a Desktop session; the click opens it with
  `claude://code/continue?session=local_…` (the ID comes from `CLAUDE_CODE_HOST_SESSION_ID`).
- If the app is not running, the hook relaunches it on the next `SessionStart` or `UserPromptSubmit`.
- Interrupting with Esc fires no hook: during a turn, the app reads the end of the transcript every second and
  switches the session back to "ready" when it finds the interruption.
- Diagnostics: `GET http://127.0.0.1:47823/state` returns the state of the sessions and of the notch as JSON
  (read only, local only, with the token:
  `curl -H @"$HOME/Library/Application Support/Oriel/hook-token" http://127.0.0.1:47823/state`).

## Tools section

A compact card between the session list and the Claude Desktop row. Each part only shows up when its file exists:

- **Recent files** (folded by default, the header shows the latest one): the last 5 distinct paths of
  `files.jsonl`, excluding temporary folders (`/tmp`, `/var/folders`, scratch spaces). A deleted file is greyed
  out. Click: Finder selects the file (or its parent folder if it is gone).
- **Git**, from `~/Library/Application Support/GitRadar/state.json` when it is less than 2 hours old:
  "everything pushed" or "N repositories to deal with", with branch, commits to push or pull, local changes.
- **Usage**, from `~/Library/Application Support/ClaudeUsage/today.json` when it is dated today: active time
  and number of sessions.

The files are only read while the panel is open (every 15 s, on a background queue); nothing runs while it is
folded. The Git and usage files are produced by separate command-line tools that are not part of this repository.

### Companion tool jobs

If companion tools are installed in `~/.local/share/<tool>/` (`git-radar`, `claude-usage`, `course-sorter`,
`claude-recap`), Oriel runs their background jobs itself instead of LaunchAgents: macOS denies
`~/Documents`, `~/Desktop` and `~/Downloads` to scripts started by launchd, while the access granted once to
an app is inherited by the processes it starts. A missing tool is skipped. Logs:
`~/Library/Logs/Oriel/<tool>.log`; state: `jobs` key of `/state`. Releases keep the same signing
certificate, so these accesses survive updates. An app built from source is signed ad hoc and loses them at
each build.

## Shared logs

The app appends one JSON line per event to two files in `~/Library/Application Support/Oriel/`, from
hooks it already receives:

- `files.jsonl`: every file written by Claude (successful `PostToolUse` of Write, Edit, MultiEdit,
  NotebookEdit): `{"ts", "path", "tool", "session_id", "project", "cwd", "source"}`.
- `permissions.jsonl`: every permission request: `{"ts", "session_id", "project", "tool", "detail"}`, where
  `detail` is the first line of the command for Bash, the file path for an edit, otherwise the tool's short
  description, truncated to 200 characters.

## Limitations

- Chat conversations in Claude Desktop do not go through hooks: for them, only "Claude Desktop open /
  frontmost" is shown.
- A session opened before the hooks were installed only appears at its next message.
- After a permission is granted in the terminal, the card stays on "waiting for your permission" until the
  tool finishes: no hook reports the approval itself. (Granted from the notch, the card updates at once.)
- Reply from the notch: a session opened before the hooks were updated receives replies only after it
  restarts. Sessions without a terminal other than the Code tab of Claude Desktop (`claude -p`, SDK, IDEs)
  cannot receive a message: the conversation offers to open the session instead. With Claude Desktop, plans were
  not checked, nor how its window shows a turn started from the notch. The conversation keeps the last 6 lines
  per session, in memory only. After the app restarts (update, relaunch) a session that is idle has no waiting
  hook until its next turn ends: the held hooks reconnect by themselves when the app comes back within 30 seconds
  (hooks started by an older script do not), and otherwise a message is queued and the conversation says it will
  go on Claude's next turn, with an **Open** button.
- Codex: a new hook only runs after it is approved (**Approve in Codex**, or **Review hooks** in the ChatGPT app, or `/hooks`
  in a terminal), and only in conversations started after that. Changing a hook (an update of Oriel) makes Codex ask
  again. `codex exec` never asks for approvals, so nothing is held there; the interactive CLI and the ChatGPT app's engine
  do (measured with the app's own Codex 0.162). The ChatGPT app window itself was not driven; the link that opens a
  conversation (`codex://threads/<id>`) comes from the app's own routing. No free message to a running session, no answer to Codex's own questions (no hook for them), and a card
  stays on "needs your approval" after an approval given in the terminal until the tool ends.
- Quota gauges: Claude's figure only arrives when a session that has the relay answers (Pro and Max, terminal sessions;
  whether the Code tab of Claude Desktop runs the `statusLine` was not checked, the documentation only describes it for
  the terminal), and is lost when the app restarts until the next answer. A project or local `settings.json` that sets its
  own `statusLine` bypasses the relay. Codex's figure is read when the panel opens, so it can be a few minutes old.
- Esc while Claude is thinking, before any text: Claude writes nothing to the transcript, so the card stays on
  "thinking" until the next event.
- A `claude` session started from a terminal opened inside Claude Desktop is classified as Desktop (Claude.app
  is among its ancestors).
- Logs are only written while the app runs (the hook relaunches the app only at the start of a session or a
  turn). They are never rotated (about 250 bytes per line); beyond 16 MB, the app only reads the end of
  `files.jsonl`.
- `permissions.jsonl` also contains AskUserQuestion and ExitPlanMode: Claude Code routes them through
  `PermissionRequest`.
- Task list: the TaskCreate/TaskUpdate tools are only enabled by default on some models. Otherwise, set
  `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`. Claude Code deletes the task files once the whole list is done: the
  progress bar then disappears.
- Player: the track comes from `mediaremote-adapter`, an open-source helper (BSD-3-Clause) that runs through Apple's
  `/usr/bin/perl`, because since macOS 15.4 MediaRemote no longer answers third-party apps. If the helper cannot
  run, the tab shows "Now playing unavailable" and a **Try Again** button.
- Low Power Mode asks for your administrator password or Touch ID once, on the first change (or at each change
  if you removed the authorization in Settings). The tile is hidden on Macs that do not offer this mode.
- Focus: macOS offers no API to read or set Focus. The tile runs a shortcut that you create in the Shortcuts app
  (the tile explains how). The state it shows is the one set by your last click.
- Bluetooth uses a private API of `IOBluetooth`, loaded at runtime. Apple may change it without notice.
- Wi-Fi: the name of the network is not shown.
- Clipboard: images over 5 MB are not kept, and the history holds 25, 50 or 100 items. Pinned items are added to
  that number and never removed.
- Quick notes: 200 notes at most, 100,000 characters per note, plain text only.
- Timer: the end of a timer is announced by the sound and the "Done" ear. The notification needs your permission.

## Uninstall

**…** menu › **Uninstall Oriel…** removes the hooks (Claude Code's, and Codex's if you installed them) and what the app
installed, then quits.
Then drag `Oriel.app` from Applications to the Trash.

## Development

Swift Package (no Xcode project), Swift 5.10 tools, macOS 13+.
Code map and design decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```sh
swift build
swift test
scripts/build.sh      # universal (arm64 + x86_64) build/Oriel.app, signed ad hoc by default
scripts/make-dmg.sh   # build/Oriel-<version>.dmg and its .sha256, checked after creation
```

- `VERSION=1.2.3 scripts/build.sh` sets the app version (default: `CFBundleShortVersionString` of
  `Resources/Info.plist`). `RELEASE_CHANNEL=1` marks the app as a release build
  (`OrielUpdateChannel = release` in its Info.plist): only those update themselves.
- `SIGN_KEYCHAIN=<keychain> SIGN_IDENTITY=<certificate name> scripts/build.sh` signs with that certificate
  instead of ad hoc (both variables or neither). This is what the release workflow does; local builds stay ad
  hoc, and macOS asks again for its accesses after each one.
- `scripts/test-local.sh [swift test options]` runs `swift test --parallel` without the test classes that put windows on
  your screen (the full suite runs in CI).
- `scripts/install.sh` builds and installs from source; `scripts/uninstall.sh` removes it.
- Translations: `Resources/en.lproj` and `Resources/fr.lproj`. The French text in the code is the key;
  `LocalizationTests` checks that every key used in the code has an English translation.
- PNG snapshots of the panel, with sample data: `ORIEL_SNAPSHOT_DIR=/some/folder swift test --filter SnapshotTests`.
- **Publishing a release** = pushing a `vX.Y.Z` tag. GitHub Actions runs the tests, builds the universal app
  in version X.Y.Z with `RELEASE_CHANNEL=1`, makes the DMG, signs it with the `UPDATE_SIGNING_KEY` secret
  (`scripts/update-signing.swift`, the job fails if signing fails or if the key does not match the one built
  into the app) and creates the release with the DMG, its SHA-256 and its signature. Installed copies pick it
  up on their own.

  ```sh
  git tag v1.2.0
  git push origin v1.2.0
  ```

  The private signing key is also in the maintainer's keychain. Losing it breaks automatic updates for every
  existing installation: they only accept DMGs signed with that key.
- **Code signature**: the release workflow signs the app with a self-signed certificate (CN `Claude Notch
  Self-Signed`, code signing, 10 years) so that its designated requirement stays the same from one version to
  the next and macOS keeps the accesses granted to the app (TCC). Two more repository secrets are needed:
  `SIGNING_CERT_P12` (the `.p12`, base64) and `SIGNING_CERT_PASSWORD`; the job fails right away without them.
  The workflow imports the certificate into a temporary keychain and deletes it at the end. Backup in the
  maintainer's login keychain, as generic passwords with service `io.github.slybald.claudenotch.code-signing`
  and accounts `p12-base64` and `p12-password`. To put the secrets back from it:

  ```sh
  S=io.github.slybald.claudenotch.code-signing
  printf %s "$(security find-generic-password -s $S -a p12-base64 -w)" | gh secret set SIGNING_CERT_P12 -R Slybald/oriel
  printf %s "$(security find-generic-password -s $S -a p12-password -w)" | gh secret set SIGNING_CERT_PASSWORD -R Slybald/oriel
  ```

  Do not replace this certificate lightly: a new one changes the requirement and every user gets the access
  prompts again.

## License

[MIT](LICENSE).

Third-party code: `Vendor/mediaremote-adapter` (ungive/mediaremote-adapter, BSD-3-Clause, copied without changes).
Its notice is listed in **About › Licenses**.

---

## Français

App macOS native qui transforme la notch du MacBook en petit panneau pour tout le monde. Survole la notch : elle
se déplie avec un lecteur, ton agenda et ses réunions, des réglages rapides, une étagère, l'historique du presse-papiers, un
minuteur et des notes rapides. Si tu utilises Claude Code ou Codex, deux onglets optionnels suivent aussi leurs
sessions : état, outil en cours, liste de tâches, sous-agents, et permissions auxquelles tu réponds depuis la
notch. Ni l'un ni l'autre n'est nécessaire pour utiliser l'app. Interface disponible en anglais et en
français (suit la langue du système). Les captures ci-dessus utilisent des données fictives.

> **Première ouverture ?** macOS bloque le premier lancement : voir [Premier lancement](#premier-lancement) (30 secondes).
> **Anciennement Claude Notch.** Mise à jour depuis la 2.1 ou avant : voir [la note plus bas](#mises-à-jour).

*Projet indépendant, ni affilié à Anthropic ni approuvé par Anthropic. Claude est une marque d'Anthropic.*

### Fonctionnalités

- **États des sessions** : prête, réfléchit, outil en cours (avec la commande ou le fichier), attend ta
  permission, attend ta réponse, plan à valider, terminé, erreur, compacte le contexte. Les sessions qui
  t'attendent passent en tête, avec un contour ambre.
- **Notch repliée avec des intercalaires** : chaque activité (Claude, lecture en cours, minuteur, Codex, messages non
  lus…) a son petit onglet contre la notch, à gauche et à droite, le plus important au plus près d'elle (trois par
  côté au plus, puis un « +N »). Celui de Claude montre son état (main levée quand une session t'attend, un spinner
  pendant que Claude travaille, une coche à la fin d'un tour) et `sessions actives·sous-agents en cours`, par exemple
  `1·6`, ou l'avancement de la liste de tâches (`2/5`). Les intercalaires s'étalent en éventail, comme des cartes
  décalées sur une table : le plus important au-dessus, contre la notch, chacun des autres glissé sous le précédent et
  n'en montrant que la tranche avec son icône. Passe la souris sur un intercalaire : il s'ouvre en grand avec son détail
  (le morceau et ses commandes, le minuteur, les sessions et leur état) ; un clic ouvre le panneau sur son onglet.
  Réglages › Apparence : toujours visibles, ou rétractés en fine languette chacun jusqu'au survol (une alerte, comme
  Claude qui attend ta réponse, reste toujours visible).
- **Permissions** : la carte montre ce que Claude demande (`Terminal · rm -rf build`, le fichier à modifier,
  la question posée).
- **Répondre depuis la notch** (désactivé par défaut ; une carte en haut de l'onglet Claude propose de
  l'activer, comme Réglages › Claude) : autoriser ou refuser une permission (avec un motif facultatif pour
  Claude), répondre à une question (choix unique ou multiple, ou texte libre), approuver un plan ou demander des
  changements, et discuter avec une session (survole sa carte : **Converser**) : ce que Claude vient de dire,
  tes messages et un champ pour écrire. Ça marche pour le CLI et pour l'onglet Code de Claude Desktop. Le
  dialogue du terminal (ou de Claude Desktop) reste utilisable en même temps : la première réponse gagne.
  Jamais de « toujours autoriser » depuis la notch. Entrée envoie, Échap ferme.
- **Onglet Codex** (optionnel, voir [Onglet Codex](#onglet-codex)) : les sessions de Codex (OpenAI, CLI ou app), qui travaillent,
  attendent une approbation ou ont fini, avec le dernier message ; autoriser ou refuser une commande ou un patch depuis la notch.
- **Jauges de quota** (optionnelles, voir [Jauges de quota](#jauges-de-quota)) : un anneau fin et le pourcentage utilisé des
  fenêtres de 5 heures et de 7 jours dans les onglets Claude et Codex, avec l'heure de remise à zéro. Ambre dès 80 %, rouge dès 95 %.
- **Tâches** : barre de progression et tâche en cours de la liste de Claude Code ; le chevron déplie la liste.
- **Sous-agents** : nombre de sous-agents en cours dans chaque session.
- **Clic → retour à la session** : un clic sur une carte ramène l'app hôte au premier plan (Terminal, iTerm2,
  Ghostty, VS Code, Claude Desktop…). Pour une session de l'onglet Code de Claude Desktop, le clic ouvre
  cette session précise.
- **Claude Desktop** : une ligne indique si Claude Desktop est ouvert, avec un bouton pour le ramener devant.
- **Section outils (optionnelle)** : fichiers récemment écrits par Claude, état Git de tes dépôts, usage du
  jour. Elle n'apparaît que si ses fichiers de données existent (voir [Section outils](#section-outils)).
- **Sept autres onglets** : Lecteur, Agenda, Réglages rapides, Étagère, Presse-papiers, Minuteur et Notes rapides (voir [Onglets](#onglets)).
- **Tes propres intercalaires** (en option, voir [Scripts](#scripts--api-locale-et-commande-notch)) : `notch run -- make`
  affiche un sablier, puis ✓ ou ✗ avec la durée ; n'importe quel script peut afficher un état court par une API locale.
- **Barre de commande** : un champ, des préfixes d'une touche (voir [Barre de commande](#barre-de-commande)) : `t 25`
  lance un minuteur, `n idée` crée une note, `c lien` cherche dans tes copies, `s présentation` applique une scène,
  `> message` écrit à Claude.
- Marche aussi sur un écran sans notch (écran externe, capot fermé) : une petite notch est dessinée en haut
  au centre de l'écran.

### Onglets

La notch déployée est une rangée d'onglets. Clique sur un onglet, ou survole-le un instant. Tous les onglets sont
activés par défaut, sauf Claude et Codex s'ils ne sont pas sur le Mac, et Messages et Mail, qui restent désactivés tant
que tu ne les actives pas. Dans **Réglages › Onglets**, tu peux masquer
un onglet (un onglet masqué ne fait aucun travail), changer leur ordre ou choisir celui qui s'ouvre par défaut. Tu
peux aussi le faire dans la notch, comme les apps sur iPhone : appui long sur la barre d'onglets, puis glisse les
icônes, masque un onglet avec **−** ou remets-en un avec **+**, et clique sur **OK** (ou Échap, ou un clic hors de la
barre). Le panneau se rouvre sur le dernier onglet utilisé, ou sur Claude (ou Codex) quand une session a besoin de toi.

- **Claude** : tes sessions, avec leur état, leurs permissions, leurs questions et leurs plans. En option : au
  premier lancement, il n'est activé que si Claude Code est sur le Mac (`~/.claude` ou `$CLAUDE_CONFIG_DIR`).
  Désactivé, rien de Claude ne tourne : ni scan des processus, ni suivi des sessions, événements des hooks ignorés.
- **Lecteur** : le morceau en cours dans Musique, Spotify ou ton navigateur, avec la pochette, la progression
  (glisse pour avancer) et les commandes. Dessous, une vue de la semaine de ton calendrier : un clic sur un
  événement l'ouvre dans Calendrier.
- **Agenda** : ton prochain rendez-vous en grand, avec un bouton **Rejoindre** qui ouvre son lien Zoom, Meet, Teams,
  Webex ou FaceTime, et le reste de la journée dessous. Notch repliée, il devient un intercalaire qui compte à rebours
  (discret à 15 minutes, ambre à 5, « en cours » en vert pendant le rendez-vous) ; aucun sondage, rien ne tourne entre
  deux échéances. Un lien ne s'ouvre que sur un clic sur **Rejoindre**.
- **Réglages rapides** : Wi-Fi, Bluetooth, Concentration, Économie d'énergie, caféine (empêche la mise en veille
  pendant 1 h, 2 h ou sans limite), batterie du Mac et des AirPods, et trois scènes : Autonomie, Normal et
  Présentation.
- **Étagère** : des fichiers et des dossiers à garder sous la main. Dépose-les sur la notch, même repliée, et
  glisse-les vers le Finder ou une autre app. L'étagère garde un lien vers chaque élément : rien n'est copié.
- **Presse-papiers** : tes copies récentes (texte, liens, images, fichiers, couleurs). Un clic les recopie ; rien
  n'est collé à ta place. Les copies faites dans les gestionnaires de mots de passe ne sont pas enregistrées.
- **Minuteur** : un compte à rebours, ou un cycle Pomodoro avec les durées de concentration et de pause que tu
  règles. Il continue de compter après une mise en veille ou un redémarrage.
- **Notes rapides** : des notes en texte brut. Épingle celles que tu utilises, supprime avec annulation, et cherche
  dès que tu en as plus de huit.
- **Messages** (désactivé par défaut) : tes conversations iMessage et SMS récentes, une pastille de non-lus sur la
  notch repliée et une réponse rapide. Il lit la base de Messages sur ton Mac, ce qui exige l'Accès complet au
  disque ; rien n'est enregistré ni envoyé ailleurs. Limites : la pastille compte les non-lus des 30 derniers jours
  et peut différer de celle du Dock ; une conversation de groupe ouvre seulement l'app Messages.
- **Mail** (désactivé par défaut) : le nombre de messages non lus d'Apple Mail et tes 3 à 5 derniers mails reçus
  (expéditeur, objet, début du texte, heure, pastille s'il n'est pas lu). Un clic en ouvre un dans Mail ; au survol,
  **Répondre** ouvre un champ pour écrire la réponse dans la notch. Elle ne part que sur ton clic sur **Envoyer** (ou
  Entrée) ; **Continuer dans Mail** ouvre la fenêtre de réponse de Mail avec ton texte déjà tapé. Si Mail ne
  confirme pas en 60 s, la notch le dit et te demande de vérifier avant de réessayer. Oriel ne lance jamais Mail : il
  ne le lit que pendant qu'il est ouvert.

### Barre de commande

Un champ dans la notch pour agir sans chercher le bon onglet. Ouvre-le avec son raccourci (Réglages › Général ›
Raccourcis, aucun par défaut) ou par **…** › **Barre de commande…**, tape, appuie sur Entrée. Rien ne part avant
Entrée (ou un clic sur la ligne), et Échap la ferme.

| Tape | Effet |
|---|---|
| `t 25`, `t 1h30`, `25 min` | Lance un minuteur (`t` seul : 25, 5 et 10 minutes, et le Pomodoro) |
| `n une idée` | Crée une note rapide |
| `c lien` | Cherche dans l'historique du presse-papiers ; Entrée recopie l'élément |
| `s présentation` | Applique une scène des Réglages rapides (Autonomie, Présentation, Normal) ; avec une vitesse fixe des ventilateurs, `s ventil` la rend à macOS |
| `m facture` | Cherche dans les derniers mails de l'onglet Mail ; Entrée ouvre le mail dans Mail |
| `a équipe` | Liste les rendez-vous d'aujourd'hui et de demain ; Entrée rejoint la réunion (lien reconnu) ou ouvre Calendrier à ce jour |
| `i sauvegarde` | Retire un intercalaire posé par un de tes scripts (ou tous) |
| `> relance les tests` | Écrit à une session Claude (le même canal que le champ de la conversation ; demande « Répondre depuis la notch ») |

Les préfixes sont listés sous le champ, et cliquables. Un préfixe est une lettre suivie d'une espace (`>` n'en demande
pas) ; le reste est du texte libre, auquel seule une durée avec son unité (`25 min`), ou une scène, un mail ou un rendez-vous d'au
moins trois lettres, peut répondre. Quand les noms ne tiennent pas, seules les touches sont montrées. La recherche ignore la casse et les accents et pardonne des lettres manquantes dans un texte court
(`prsnt` trouve Présentation). La barre n'interroge que les onglets activés et en marche : un onglet masqué n'est pas
réveillé, un onglet Claude coupé n'a pas de `>`. Le presse-papiers et les intercalaires de tes scripts ne sont
jamais cherchés sans leur préfixe. Pas de langage
naturel, aucune permission, rien ne quitte ton Mac.

### Répondre depuis la notch

Désactivé par défaut : l'onglet Claude affiche une carte (**Activer** / **Plus tard**) et **Réglages › Claude**
a l'interrupteur. Claude Code attend alors ta réponse dans la notch comme dans le terminal ou dans Claude Desktop :

- **Permissions** : autoriser ou refuser un appel d'outil, avec un motif facultatif que Claude lit. La notch ne
  propose jamais « toujours autoriser ».
- **Questions** : choisir une ou plusieurs réponses, ou écrire la tienne.
- **Plans** : approuver un plan, ou demander des changements.
- **Conversation** : survole la carte d'une session et clique sur **Converser**. Tu vois les derniers messages
  de Claude (ce qu'il a dit en s'arrêtant, ce que ses sous-agents ont rapporté), ce que tu as écrit, et un champ
  pour écrire à Claude. Le message lui parvient après l'action en cours, ou démarre un tour (3 s environ) s'il
  attendait. Un clic sur un long message le déplie.

Le dialogue du terminal reste utilisable : la première réponse gagne. Si la notch ne répond pas à temps (4 secondes
si sa carte n'a jamais été affichée, environ 590 secondes sinon), la demande revient au terminal. Il en va de même
quand l'app est fermée ou le réglage coupé : rien n'est jamais approuvé par défaut.

**Claude Desktop (onglet Code).** Vérifié avec Claude Code 2.1.304 lancé comme le lance l'onglet Code : le hook de
permission est appelé et sa décision appliquée (en mode « ignorer les autorisations », rien ne demande de
permission, mais les questions arrivent bien dans la notch), une question répondue depuis la notch est reçue par
Claude, et un message envoyé depuis la notch réveille Claude (un nouveau tour 3 s plus tard, ou lu après l'action
en cours). Les plans n'ont pas été vérifiés avec Desktop, ni la façon dont la fenêtre de Desktop montre un tour
démarré depuis la notch.

Quand la notch ne peut pas écrire à une session (`claude -p`, SDK Agent, IDE, ou session ouverte avant la mise à jour
du script de hook), la conversation affiche « Réponds dans *app* » avec un bouton **Ouvrir** à la place du champ.
Une session ouverte avant la mise à jour ne reçoit les réponses qu'après son redémarrage.

### Onglet Codex

Codex a ses propres hooks : l'onglet marche comme celui de Claude. Il suit Codex où qu'il tourne : l'**app ChatGPT**
(qui contient maintenant Codex), la commande `codex` dans un terminal, ou un éditeur.

1. **Réglages › Codex › Installer les hooks Codex** (le bouton de l'onglet l'ouvre). Une entrée par événement est ajoutée à
   `~/.codex/hooks.json` (sauvegarde horodatée d'abord, tes hooks restent) et `codex-notch-hook.sh` est copié dans
   `~/.codex/hooks/`. Ton `notify` n'est jamais touché.
2. **Approuve les hooks dans Codex.** Codex ignore un hook neuf tant qu'il n'est pas approuvé, sans rien dire.
   L'onglet et Réglages › Codex montrent où tu en es (*non posés*, *en attente d'approbation dans Codex*, *actifs*).
   Tant que l'approbation attend, clique sur **Approuver dans Codex** : l'app demande à Codex lui-même de faire confiance
   aux 8 hooks d'Oriel, et seulement à eux (la requête du bouton **Review hooks** de l'app ChatGPT). Tu peux aussi
   les revoir toi-même là, ou avec `/hooks` dans un terminal. L'onglet se met à jour tout seul dès qu'ils sont approuvés.
3. **Ouvre une nouvelle conversation** dans l'app ChatGPT (ou lance `codex`). Les conversations déjà ouvertes quand les
   hooks ont été approuvés ne sont pas suivies.
4. Chaque carte montre le projet, l'app (ChatGPT, Terminal, VS Code…), le modèle, ce que fait Codex (la commande ou le
   fichier) et son dernier message. Un clic sur la carte ramène cette app devant ; pour une session de l'app ChatGPT,
   il ouvre la conversation elle-même.

**Approuver depuis la notch** (Réglages › Codex, désactivé par défaut) : quand Codex demande à lancer une commande ou à
appliquer un patch, la carte l'affiche, avec **Autoriser**, **Refuser** et **Dans le terminal**. Contrairement à Claude
Code, Codex attend la notch avant de demander dans le terminal : l'attente est courte, 4 secondes si la carte n'a jamais
été affichée, 60 secondes sinon, puis Codex te demande lui-même. Rien n'est approuvé par défaut, jamais de « toujours
autoriser ». Impossible : écrire à une session Codex en cours, ou répondre aux questions propres de Codex.

### Scripts : API locale et commande `notch`

Désactivée par défaut (**Réglages › Scripts**). Une fois activée, tes scripts et tes programmes peuvent poser jusqu'à
trois intercalaires à eux à côté de la notch repliée, avec un texte court, une icône et une couleur prises dans des
listes, pour une heure au plus. La commande `notch` s'installe depuis le même volet (dans `~/.local/bin`, seulement sur
ton clic) :

```sh
notch show --title "Sauvegarde finie" --text OK --icon externaldrive.fill --color green
notch run -- make test
```

Aucun code n'est chargé dans l'app et un intercalaire ne lance rien : la seule action est un bouton qui ouvre l'app que
tu as nommée. Seuls les programmes de ton compte qui lisent le fichier du jeton peuvent l'appeler, jamais une page web ;
l'intercalaire d'un script dit toujours de quel programme il vient et ne peut pas se faire passer pour une demande de
Claude ou de Codex. Détails HTTP, limites et modèle de sécurité : [docs/API.md](docs/API.md).

### Jauges de quota

Un anneau fin, le pourcentage utilisé et l'heure de la prochaine remise à zéro, pour les fenêtres de 5 heures et de 7 jours,
sous les sessions de l'onglet **Claude** et de l'onglet **Codex** (et dans le résumé qui se déplie quand tu survoles leur
intercalaire). Ambre dès 80 %, rouge dès 95 %. Rien n'apparaît quand un onglet est désactivé, ni quand l'agent ne donne aucun
chiffre.

- **Claude** (Réglages › Claude › Afficher le quota, désactivé par défaut). Claude Code donne le quota (`rate_limits`) à sa
  `statusLine` et nulle part ailleurs, et n'accepte qu'une seule commande de `statusLine`. Le réglage met donc un petit relais à
  sa place dans `~/.claude/settings.json` (sauvegarde horodatée d'abord). Le relais envoie les données à l'app (127.0.0.1, avec
  le jeton), puis relance **ta commande précédente** avec les mêmes données : ta ligne d'état ne change pas (sans commande, il
  affiche `5h 39% · 7d 63%`). Couper le réglage, ou désinstaller Oriel, remet ta commande. Seulement pour les abonnés
  Pro et Max de claude.ai, et seulement après la première réponse d'une session. Les chiffres sont ceux du compte : n'importe
  quelle session les met à jour. L'app garde les pourcentages et les heures en mémoire ; le reste de ce que reçoit la ligne
  d'état (dossier, modèle, session) est jeté. Mesuré avec Claude Code 2.1.304 : rien avant la première réponse, puis les deux fenêtres.
- **Codex** (Réglages › Codex › Afficher le quota, activé par défaut). Rien à installer : panneau ouvert, l'app interroge
  Codex lui-même (`codex app-server`, requête `account/rateLimits/read`, environ 1 s) au plus une fois par minute, puis toutes
  les 5 minutes. Mesuré avec la commande Codex 0.154 et le Codex de l'app ChatGPT 0.162. Il faut un compte ChatGPT : avec une clé
  d'API, Codex répond par une erreur et aucune jauge ne s'affiche. Un résumé vu sur un intercalaire replié cache un chiffre de
  plus de 15 minutes.

### Réglages de la notch

Ouvre **…** › **Réglages…** (⌘,).

- **Visibilité** : toujours visible (par défaut), seulement quand Claude est ouvert (proposé avec l'onglet Claude
  activé), ou seulement pendant une activité : une session qui travaille, attend ou vient de finir, ou un onglet qui affiche des oreilles (minuteur,
  lecteur).
- **Masquer la notch** pendant 1 h, jusqu'à demain, ou jusqu'à ce que tu la réaffiches. Les mêmes choix sont dans le
  menu **…** et dans le menu du clic droit sur la notch repliée.
- **Ouverture** : au survol (avec un délai) ou au clic. **Fermer au clic à l'extérieur** garde le panneau ouvert
  jusqu'à un clic ailleurs, au lieu de le refermer quand la souris le quitte.
- **Raccourcis** (aucun par défaut) : l'un ouvre ou ferme le panneau, l'autre masque ou réaffiche la notch, un
  troisième ouvre la [barre de commande](#barre-de-commande). Ils marchent partout, sans l'autorisation d'accessibilité. Panneau ouvert au clavier : ← et → changent d'onglet, ⌘1 à
  ⌘9 vont à un onglet, Échap ferme.
- **Taille et apparence** : largeur du panneau (compact, standard, grand, ou une largeur personnalisée de 460 à
  720 pt), fond (noir, graphite, bleu nuit ou couleur libre), opacité, ombre, couleur d'accent et vitesse des
  animations. Avec « Réduire les animations » activé dans macOS, les animations deviennent un simple fondu.
- **Écran** : l'écran intégré (par défaut), l'écran principal, l'écran sous la souris, ou un écran choisi par son
  nom. Un écran sans encoche reçoit une encoche virtuelle en haut au centre.
- **Bulle** : glisse l'angle en bas à droite du panneau ouvert, et la notch se décolle en une bulle à poser où tu
  veux, ses onglets en barillet de revolver (molette ou clic pour tourner, clic au centre pour ouvrir ; le bouton
  retour, Échap, un clic à l'extérieur ou un pincement ramènent au barillet). Approche-la de la notch, qui l'attire et
  l'aspire comme du ferrofluide, double-clique sur son bord ou choisis **Rattacher à la notch**. Désactivable, et elle peut
  revenir dans la notch à chaque lancement.
- **Confidentialité** : masquer la notch des captures d'écran et du partage d'écran. Cela dépend de l'app qui capture
  l'écran.
- **Profil** : **Changer de profil…** te fait partir d'un profil (Développeur, Étudiant, Créatif ou Minimal) : la
  fenêtre montre les onglets affichés et masqués, l'ouverture et les oreilles, et ne change rien avant ta
  confirmation. Les données des onglets et les hooks ne sont jamais touchés ; les onglets masqués reviennent depuis
  **Réglages › Onglets**. Le volet nomme le profil qui correspond à tes onglets, ou « Personnalisé ».
- **Assistant de configuration** : **Relancer l'assistant de configuration** refait les étapes du premier lancement,
  en partant de tes réglages actuels.
- **Rétablir les réglages par défaut**, après confirmation. Les onglets, leurs données et les hooks ne changent pas.

### Installation

1. Télécharge `Oriel-<version>.dmg` depuis la page [Releases](https://github.com/Slybald/oriel/releases).
2. Ouvre-le et glisse **Oriel** sur **Applications**.
3. Facultatif : vérifie le téléchargement avec le fichier `.sha256` publié à côté :
   `shasum -a 256 -c Oriel-<version>.dmg.sha256` (dans le dossier du téléchargement).

#### Premier lancement

Oriel n'est pas notarisée (pas de compte Apple Developer ; les releases sont signées avec un
certificat auto-signé) : macOS la bloque à la première ouverture. Ce n'est pas un virus, il faut juste le dire à
macOS une fois. Les mêmes étapes sont dans un fichier texte à l'intérieur du DMG.

- **macOS 13 et 14** : clic droit (ou Ctrl + clic) sur **Oriel** dans Applications › **Ouvrir** › **Ouvrir**.
- **macOS 15 et après** : ouvre Oriel, ferme l'alerte, va dans **Réglages Système › Confidentialité et
  sécurité**, descends et clique sur **Ouvrir quand même** à côté du message sur Oriel, puis confirme.
- Ou, dans le Terminal :

  ```sh
  xattr -dr com.apple.quarantine /Applications/Oriel.app
  ```

Le certificat est le même à chaque release : macOS reconnaît chaque mise à jour comme la même app et garde les
accès que tu as accordés (calendrier, Bluetooth, Automation, dossiers). Les versions précédentes étaient
signées ad hoc, une signature qui change à chaque build : au passage à la première release signée avec le
certificat, macOS redemande ces accès une dernière fois, puis plus jamais.

Au premier lancement, un assistant de configuration te laisse choisir ce qui t'intéresse, en quatre courtes
étapes. **Passer** est toujours possible et ne change rien ; rien n'est écrit avant **Appliquer**.

1. **Bienvenue et profil** : ce qu'est la notch, et un profil facultatif : Développeur (Claude et Codex s'ils sont
   trouvés, presse-papiers, minuteur, notes), Étudiant (agenda, lecteur et calendrier, minuteur, notes, réglages rapides),
   Créatif (lecteur et calendrier, étagère, presse-papiers) ou Minimal (lecteur et calendrier, réglages rapides). Il
   coche les onglets, règle l'ouverture du panneau et les oreilles ; les étapes suivantes partent de lui et tout reste
   modifiable. Sans choix, rien ne change.
2. **Onglets** : une carte par onglet, coche ceux que tu veux (au moins un reste activé). La carte Claude n'est
   proposée que si Claude Code est sur le Mac, avec une option décochée pour installer les hooks de Claude Code :
   ils ajoutent les entrées d'Oriel dans `~/.claude/settings.json` (une sauvegarde horodatée est faite à
   côté avant, tes hooks existants sont conservés) et installent le script de hook dans `~/.claude/hooks/`. Sans
   Claude Code, une ligne dit où activer l'onglet Claude plus tard (**Réglages › Onglets**).
3. **Comportement** : ouverture au survol ou au clic, un raccourci clavier facultatif, et le lancement à l'ouverture
   de session.
4. **Fin** : un aperçu de ta notch avec les onglets choisis, et où retrouver tout ça (menu **…**, Réglages).

L'assistant ne demande aucune autorisation macOS (calendrier, Bluetooth…) : macOS ne la demande que lorsque tu
utilises l'onglet concerné. Il ne s'affiche qu'une fois, et pas après une mise à jour depuis une version déjà
configurée. Pour le refaire : **Réglages › Général › Relancer l'assistant de configuration**. Les hooks peuvent
aussi s'installer plus tard depuis **Réglages › Claude** ; une session déjà ouverte apparaît à son prochain message.

#### Prérequis

- macOS 13 Ventura ou plus récent, Apple silicon ou Intel.
- Pour l'onglet Claude seulement : Claude Code (CLI, ou onglet Code de Claude Desktop).
- Pour l'onglet Codex seulement : Codex (l'app ChatGPT ou la commande `codex`), versions 0.154 (commande) et 0.162 (app)
  testées, hooks activés (par défaut).
- Configuration de Claude Code dans `~/.claude`. `CLAUDE_CONFIG_DIR` n'est pas pris en charge par l'app :
  les hooks sont toujours installés dans `~/.claude`.

### Mises à jour

Oriel se met à jour seule depuis la page [Releases](https://github.com/Slybald/oriel/releases).

- 60 secondes après le lancement, puis toutes les 6 heures, l'app demande à GitHub la dernière release
  (`api.github.com` ; seule la version de l'app part, dans le User-Agent). Brouillons et préversions sont
  ignorés.
- Une version plus récente est téléchargée avec sa signature (`Oriel-<version>.dmg.sig`) et n'est
  installée que si sa signature Ed25519 correspond à la clé publique intégrée à l'app. Un DMG sans signature,
  ou à la signature invalide, est refusé et rien n'est installé.
- Au lancement, la nouvelle version s'installe tout de suite ; ensuite, seulement quand aucune session n'est
  en cours ni ne t'attend (sinon l'app réessaie toutes les 10 minutes). L'app redémarre alors seule et le
  menu **…** affiche « Mis à jour en X ».
- L'installation automatique demande que l'app soit dans `/Applications` ou `~/Applications`, dans un dossier
  où tu peux écrire. Sinon, le menu **…** propose d'ouvrir la page de la release.
- Pour la désactiver : menu **…** › décoche **Mises à jour automatiques**. Les nouvelles versions sont alors
  seulement signalées dans le menu, avec un bouton **Installer**. **Rechercher les mises à jour** vérifie
  tout de suite.
- Une app compilée depuis les sources (`scripts/build.sh`, `scripts/install.sh`) ne se met jamais à jour
  seule : le menu affiche « Build de développement : mises à jour désactivées ».
- **Mise à jour depuis la 2.1 ou avant** (quand l'app s'appelait encore Claude Notch) : la mise à jour
  automatique ne peut pas passer le renommage. Télécharge `Oriel-<version>.dmg` une fois à la main et glisse **Oriel**
  sur Applications (elle remplace l'ancienne app), puis redonne les accès macOS demandés. Tes réglages, tes notes et
  tes hooks sont repris au premier lancement (dossier de données, ouverture à la connexion, hooks de Claude Code
  déplacés vers les nouveaux noms ; les hooks Codex gardent leur approbation). Ensuite, les mises à jour redeviennent automatiques. Si tu avais activé
  l'autorisation des ventilateurs ou de l'économie d'énergie, refais-le dans les Réglages ; les anciennes règles se
  retirent avec `sudo rm /etc/sudoers.d/claude-notch-*` et
  `sudo rm /Library/PrivilegedHelperTools/io.github.slybald.claudenotch.fanctl`.

### Confidentialité

- Tout reste sur ton Mac. Oriel n'envoie aucune donnée sur toi ni sur tes sessions : pas de
  statistiques. Ses seules requêtes sortantes sont la recherche de mise à jour sur `api.github.com` et le
  téléchargement des nouvelles versions depuis GitHub (voir [Mises à jour](#mises-à-jour)).
- L'app n'écoute que sur `127.0.0.1:47823`, sur l'interface de bouclage : elle est injoignable depuis le réseau.
- Le script de hook ne parle qu'à cette adresse locale, avec `curl`. Chaque requête porte un jeton que l'app
  génère à chaque lancement et écrit dans `~/Library/Application Support/Oriel/hook-token` (lisible par
  ton compte seulement) ; curl le lit dans ce fichier, il n'apparaît donc jamais dans la liste des processus.
  L'app refuse toute requête sans lui, avec un autre `Host` que `127.0.0.1:47823` ou avec un en-tête `Origin`
  (une page web). Dans l'autre sens, une décision ou un message de l'app porte un second secret (`hook-proof`,
  même dossier, jamais envoyé par le script) : sans lui, le script ignore la réponse. Un programme qui prend le
  port pendant que l'app est fermée (un autre compte sur un Mac partagé) ne décide donc rien.
- Réponses depuis la notch : l'app ne fait jamais que répondre à la requête d'un hook de Claude Code, après un
  clic dans la notch. Aucune route ne permet à un autre programme de décider à ta place, et il n'y a pas de
  « toujours autoriser ». Au moindre échec (app fermée, réglage coupé, délai passé), le hook rend la main au
  terminal : jamais d'autorisation par défaut.
- **Presse-papiers** : pendant que l'app tourne, l'onglet Presse-papiers vérifie le presse-papiers une fois par
  seconde, et ne lit son contenu que s'il a changé et passe les contrôles de confidentialité. Les copies marquées
  confidentielles, temporaires ou générées par un gestionnaire de mots de passe ne sont jamais enregistrées, ni
  celles faites depuis Trousseaux d'accès, Mots de passe, 1Password, Bitwarden, Dashlane ou KeePassXC (la liste
  peut être modifiée). Par défaut, l'historique reste en mémoire et disparaît à la fermeture de l'app ou à la
  désactivation de l'onglet. Si tu le gardes d'un lancement à l'autre, seuls les textes et les liens sont écrits,
  jamais les images ni les fichiers. Suspendre la capture arrête les contrôles jusqu'au prochain lancement.
- Ce que l'app lit : les événements de hook, la fin du transcript d'une session en cours (pour détecter
  Esc), les fichiers de tâches de Claude Code, la liste des processus (pour trouver l'app hôte), le morceau en cours
  et sa pochette (Lecteur), les événements des calendriers que tu as choisi d'afficher, l'état du Wi-Fi et du
  Bluetooth, et le niveau de la batterie. Avec le quota activé : les pourcentages et heures de remise à zéro que Claude Code
  donne à sa ligne d'état (relayés, gardés en mémoire) et que Codex renvoie quand on le lui demande.
- Ce que l'app écrit : les journaux et les fichiers du jeton dans `~/Library/Application Support/Oriel/`
  (voir [Registres partagés](#registres-partagés)), et les données des onglets dans le même dossier :
  `shelf.json` (les références à tes fichiers), `notes.json`, `timer.json`, et `clipboard-history.json` seulement
  si tu gardes l'historique. Ces fichiers ne sont lisibles que par ton compte. Il y a aussi les hooks dans
  `~/.claude` quand tu le demandes, les hooks Codex (`~/.codex/hooks.json` et `~/.codex/hooks/codex-notch-hook.sh`) quand tu
  le demandes, `oriel-statusline.sh` et une copie de ta commande de ligne d'état précédente (lisible par toi seul) dans
  `~/.claude/hooks/`, et la `statusLine` de `~/.claude/settings.json`, quand tu actives le quota de Claude (`~/.codex/config.toml` n'est que lu, pour montrer l'état des hooks, jamais écrit par l'app : l'approbation des
  hooks, quand tu cliques sur **Approuver dans Codex**, est écrite par Codex lui-même, que l'app lance un instant avec un
  environnement minimal) et, pendant une mise à jour, le DMG dans
  `~/Library/Caches/io.github.slybald.oriel/updates/` (supprimé ensuite) et la nouvelle app à la place de
  l'ancienne. Les messages que tu tapes partent à la session Claude Code seulement, sans être enregistrés.

### Autorisations macOS

Oriel ne demande une autorisation que lorsque tu utilises la fonction qui en a besoin. Rien n'est demandé au
lancement.

- **Calendriers** (accès complet) : ta semaine et tes événements dans l'onglet Lecteur, et le prochain rendez-vous de
  l'onglet Agenda (avec son compte à rebours sur la notch repliée). Demandé quand tu appuies sur le bouton du
  calendrier ou sur **Autoriser l'accès au calendrier**, ou que tu actives l'option.
- **Automatisation : Calendrier** (Apple Events) : pour ouvrir un jour ou un événement dans Calendrier. macOS le
  demande la première fois.
- **Bluetooth** : pour lire l'état du Bluetooth et le couper ou le rallumer depuis Réglages rapides. Demandé quand tu
  utilises pour la première fois la tuile Bluetooth ou une scène qui la change.
- **Notifications** : pour annoncer la fin d'un minuteur. Demandé au premier minuteur lancé. Sans elles, le son et
  l'oreille « Terminé » signalent quand même la fin.
- **Coller depuis d'autres apps** (macOS 15.4 et plus récent) : pour que l'onglet Presse-papiers puisse lire ce que
  tu copies. macOS peut le demander à chaque fois, ou le bloquer. Bloqué, rien ne peut être enregistré ; l'onglet et
  les réglages renvoient vers Réglages Système.
- **Accès complet au disque** (onglet Messages, désactivé par défaut) : pour lire la base de Messages. macOS n'a pas
  de fenêtre pour ça : ajoute Oriel toi-même dans Réglages Système › Confidentialité et sécurité › Accès
  complet au disque, puis relance l'app. Sans lui, l'onglet le dit et renvoie vers Réglages Système.
- **Contacts** (onglet Messages) : pour afficher les noms des contacts au lieu des numéros. Demandé quand tu cliques
  sur **Autoriser** dans l'onglet.
- **Automatisation : Messages** (Apple Events) : pour envoyer une réponse rapide. macOS le demande au premier envoi.
- **Automatisation : Mail** (Apple Events) : pour lire les derniers mails et envoyer la réponse que tu écris. Demandé
  quand tu cliques sur **Autoriser** dans l'onglet Mail.
- **Bureau, Documents, Téléchargements** : seulement pour les outils compagnons facultatifs (voir
  [Section outils](#section-outils)).
- Wi-Fi : le nom du réseau n'est pas lu, donc la localisation n'est pas demandée. Si macOS refuse de changer l'état
  du Wi-Fi, la tuile l'indique.
- L'économie d'énergie exige les droits administrateur (`pmset`). Le premier changement demande ton mot de passe ou
  Touch ID une fois et, dans la même fenêtre, pose une règle système limitée à l'activation et la désactivation de
  ce mode (`/etc/sudoers.d/oriel-lowpower`) ; ensuite, plus de mot de passe. Retirée par « Retirer
  l'autorisation » dans les réglages ou à la
  désinstallation.
- La vitesse fixe des ventilateurs exige root pour écrire dans le SMC. La première vitesse fixe demande ton mot de
  passe une fois et installe un petit outil (`/Library/PrivilegedHelperTools/io.github.slybald.oriel.fanctl`) et
  une règle système qui n'autorise que lui (`/etc/sudoers.d/oriel-fans`). Lire les vitesses et les températures
  ne demande rien. « Retirer l'autorisation » dans les réglages ou la désinstallation retire les deux.

### Fonctionnement

- Codex : ses hooks passent par le même serveur local (`/codex/hook`, et `/codex/permission` pour le hook `PermissionRequest`
  synchrone), avec le même jeton et la même preuve. Codex lance ce hook *avant* sa propre invite et l'attend : l'app tient
  donc une demande 4 s si sa carte n'a jamais été affichée, 60 s sinon, puis répond « pas de décision » et Codex demande
  dans le terminal (timeout du hook : 75 s).
- Chaque événement de hook est relayé par `curl` vers `http://127.0.0.1:47823/hook`, avec le PID du
  processus parent du hook et quelques variables d'environnement. Ces hooks sont déclarés `async: true` :
  aucune latence pour Claude.
- Deux autres sortes de hooks servent à « Répondre depuis la notch » :
  - `PermissionRequest` lance aussi le script en synchrone (mode `permission`, timeout de 600 s). Le dialogue
    du terminal s'affiche en même temps et reste utilisable ; la première réponse gagne. L'app tient la
    demande jusqu'à ton clic, sinon elle répond « pas de décision » : après 4 s si tu n'as pas ouvert sa carte
    dans la notch, après 590 s environ si tu l'as ouverte, dès que l'outil tourne ou que le tour avance, ou
    quand tu réponds au terminal. Réglage coupé, le hook rend la main tout de suite.
  - `SessionStart` et `Stop` lancent une attente (mode `inbox`, `asyncRewake`) : elle attend en arrière-plan
    un message tapé dans la notch, puis le remet à Claude, qui démarre un tour (3 s environ). Pendant un tour,
    le message est lu après l'action en cours. Sans attente (session ouverte avant la mise à jour des hooks,
    app relancée), le message reste en file jusqu'à la fin du tour. Taille limitée à 1 800 octets, caractères
    de contrôle retirés. Les sessions sans terminal (`claude -p`, SDK, IDE) ne reçoivent pas de message depuis la
    notch : Claude y attend la fin de ce hook avant de lire le prompt (ou avant de sortir), l'app le libère donc
    tout de suite. L'onglet Code de Claude Desktop fait exception, à la fin d'un tour seulement (`Stop` ; le
    script envoie l'identifiant de session Desktop) : le résultat du tour est déjà parti et le prompt suivant
    n'attend pas, alors que tenu sur `SessionStart` le hook retardait le premier prompt de toute l'attente (mesuré
    avec Claude Code 2.1.304). À la fermeture d'une session Desktop, SIGTERM la termine aussitôt ; fermer son
    entrée laisse Claude jusqu'à 30 s environ.
- Après une mise à jour de l'app, des hooks posés par une version précédente sont mis à jour sans rien
  demander, avec la sauvegarde horodatée habituelle de `settings.json`.
- À partir de ce PID, l'app remonte la chaîne de processus pour trouver le processus Claude (détection de
  fin de session) et l'app hôte (Terminal, iTerm2, Ghostty, VS Code, Claude Desktop…). Une session qui a
  Claude Desktop parmi ses ancêtres est une session Desktop ; le clic l'ouvre avec
  `claude://code/continue?session=local_…` (identifiant transmis par `CLAUDE_CODE_HOST_SESSION_ID`).
- Si l'app est fermée, le hook la relance au prochain `SessionStart` ou `UserPromptSubmit`.
- Une interruption par Esc ne déclenche aucun hook : pendant un tour, l'app relit la fin du transcript chaque
  seconde et repasse la session en « Prête » si elle y trouve l'interruption.
- Diagnostic : `GET http://127.0.0.1:47823/state` renvoie l'état des sessions et de la notch en JSON
  (lecture seule, local uniquement, avec le jeton :
  `curl -H @"$HOME/Library/Application Support/Oriel/hook-token" http://127.0.0.1:47823/state`).

### Section outils

Une carte compacte entre la liste des sessions et la ligne Claude Desktop. Chaque partie n'apparaît que si
son fichier existe :

- **Fichiers récents** (replié par défaut, l'en-tête montre le dernier) : les 5 derniers chemins distincts de
  `files.jsonl`, hors dossiers temporaires (`/tmp`, `/var/folders`, espaces jetables). Un fichier supprimé
  est grisé. Clic : le Finder sélectionne le fichier (ou son dossier parent s'il a disparu).
- **Git**, depuis `~/Library/Application Support/GitRadar/state.json` s'il a moins de 2 h : « tout est
  poussé » ou « N dépôts à traiter », avec branche, commits à pousser ou à récupérer, modifications locales.
- **Usage**, depuis `~/Library/Application Support/ClaudeUsage/today.json` s'il est daté du jour : temps
  actif et nombre de sessions.

Les fichiers ne sont lus que panneau ouvert (toutes les 15 s, sur une queue de fond) ; replié, rien ne
tourne. Les fichiers Git et usage viennent d'outils en ligne de commande séparés, absents de ce dépôt.

#### Tâches des outils compagnons

Si des outils compagnons sont installés dans `~/.local/share/<outil>/` (`git-radar`, `claude-usage`,
`course-sorter`, `claude-recap`), Oriel lance lui-même leurs tâches de fond à la place de
LaunchAgents : macOS refuse `~/Documents`, `~/Desktop` et `~/Downloads` aux scripts démarrés par launchd,
alors que l'accès accordé une fois à une app est hérité par les processus qu'elle lance. Un outil absent est
ignoré. Journaux : `~/Library/Logs/Oriel/<outil>.log` ; état : clé `jobs` de `/state`. Les releases
gardent le même certificat de signature, ces accès survivent donc aux mises à jour. Une app compilée depuis
les sources est signée ad hoc et les perd à chaque build.

### Registres partagés

L'app ajoute une ligne JSON par événement à deux fichiers de `~/Library/Application Support/Oriel/`, à
partir de hooks qu'elle reçoit déjà :

- `files.jsonl` : chaque fichier écrit par Claude (`PostToolUse` réussi de Write, Edit, MultiEdit,
  NotebookEdit) : `{"ts", "path", "tool", "session_id", "project", "cwd", "source"}`.
- `permissions.jsonl` : chaque demande de permission : `{"ts", "session_id", "project", "tool", "detail"}`,
  où `detail` est la 1re ligne de la commande pour Bash, le chemin du fichier pour une édition, sinon la
  description courte de l'outil, tronqué à 200 caractères.

### Limites

- Les conversations « chat » de Claude Desktop ne passent pas par les hooks : seul l'état « Claude Desktop
  ouvert / au premier plan » est affiché pour elles.
- Une session ouverte avant l'installation des hooks n'apparaît qu'à son prochain message.
- Après une permission accordée dans le terminal, la carte reste en « Attend ta permission » jusqu'à la fin
  de l'outil : aucun hook ne signale l'accord lui-même. (Accordée depuis la notch, la carte suit tout de suite.)
- Répondre depuis la notch : une session ouverte avant la mise à jour des hooks ne reçoit les réponses
  qu'après son redémarrage. Une session sans terminal autre que l'onglet Code de Claude Desktop (`claude -p`,
  SDK, IDE) ne peut pas recevoir de message : la conversation propose d'ouvrir la session. Avec Claude Desktop,
  les plans n'ont pas été vérifiés, ni la façon dont sa fenêtre montre un tour démarré depuis la notch. La
  conversation garde les 6 dernières répliques de chaque session, en mémoire seulement. Après un redémarrage de
  l'app (mise à jour, relance), une session au repos n'a plus de hook en attente jusqu'à la fin de son prochain
  tour : les hooks tenus se reconnectent seuls si l'app revient dans les 30 secondes (pas ceux lancés par un
  ancien script), sinon un message reste en file et la conversation dit qu'il partira au prochain tour de Claude,
  avec un bouton **Ouvrir**.
- Codex : un hook neuf ne tourne qu'une fois approuvé (**Approuver dans Codex**, ou **Review hooks** dans l'app ChatGPT, ou
  `/hooks` dans un terminal), et seulement dans les conversations démarrées ensuite. Modifier un hook (une mise à jour d'Oriel) fait que Codex le redemande. `codex exec` ne demande jamais d'approbation : rien n'y est tenu ; le CLI
  interactif et le moteur de l'app ChatGPT, si (mesuré avec le Codex 0.162 de l'app). La fenêtre de l'app ChatGPT elle-même
  n'a pas été pilotée ; le lien qui ouvre une conversation (`codex://threads/<id>`) vient du routage de l'app. Pas de message libre à une session en cours, pas de réponse aux questions propres de Codex (aucun hook), et
  la carte reste sur « Attend ton approbation » après une approbation donnée dans le terminal, jusqu'à la fin de l'outil.
- Jauges de quota : le chiffre de Claude n'arrive que quand une session munie du relais répond (Pro et Max, sessions de
  terminal ; on n'a pas vérifié si l'onglet Code de Claude Desktop exécute la `statusLine`, la documentation ne la décrit que
  pour le terminal), et il est perdu au redémarrage de l'app jusqu'à la réponse suivante. Un `settings.json` de projet ou local
  qui impose sa propre `statusLine` contourne le relais. Le chiffre de Codex est lu à l'ouverture du panneau : il peut avoir
  quelques minutes.
- Esc pendant la réflexion, avant le moindre texte : Claude n'écrit rien dans le transcript, la carte reste en
  « Réfléchit » jusqu'au prochain événement.
- Une session `claude` lancée depuis un terminal ouvert dans Claude Desktop est classée Desktop (Claude.app
  figure parmi ses ancêtres).
- Registres : écrits seulement pendant que l'app tourne (le hook ne relance l'app qu'au début d'une session
  ou d'un tour). Pas de rotation (environ 250 octets par ligne) ; au-delà de 16 Mo, l'app ne lit que la fin
  de `files.jsonl`.
- `permissions.jsonl` contient aussi AskUserQuestion et ExitPlanMode : Claude Code les fait passer par
  `PermissionRequest`.
- Liste de tâches : les outils TaskCreate/TaskUpdate ne sont actifs par défaut que sur certains modèles.
  Sinon, `CLAUDE_CODE_ENABLE_TODO_TOOLS=1`. Claude Code supprime les fichiers de tâches quand toute la liste
  est terminée : la barre disparaît.
- Lecteur : le morceau vient de `mediaremote-adapter`, un utilitaire open source (BSD-3-Clause) qui passe par
  `/usr/bin/perl` d'Apple, car depuis macOS 15.4 MediaRemote ne répond plus aux apps tierces. Si l'utilitaire ne
  démarre pas, l'onglet affiche « Lecture en cours indisponible » et un bouton **Réessayer**.
- Économie d'énergie : demande le mot de passe administrateur ou Touch ID une seule fois, au premier changement (ou à
  chaque changement si tu as retiré l'autorisation dans les réglages). La tuile est masquée sur les Mac qui n'ont
  pas ce mode.
- Concentration : macOS n'offre aucun moyen de lire ni de régler la Concentration depuis une app. La tuile lance un
  raccourci que tu crées dans l'app Raccourcis (la tuile explique comment). L'état affiché est celui de ton dernier
  clic.
- Bluetooth utilise une API privée d'`IOBluetooth`, chargée à l'exécution. Apple peut la modifier sans prévenir.
- Wi-Fi : le nom du réseau n'est pas affiché.
- Presse-papiers : les images de plus de 5 Mo ne sont pas gardées, et l'historique garde 25, 50 ou 100 éléments. Les
  éléments épinglés s'ajoutent à ce nombre et ne sont jamais retirés.
- Notes rapides : 200 notes au plus, 100 000 caractères par note, texte brut seulement.
- Minuteur : la fin est signalée par le son et l'oreille « Terminé ». La notification demande ton autorisation.

### Désinstallation

Menu **…** › **Désinstaller Oriel…** retire les hooks (ceux de Claude Code, et ceux de Codex si tu les as installés) et ce
que l'app a installé, puis la quitte.
Jette ensuite `Oriel.app` du dossier Applications à la Corbeille.

### Développement

Swift Package (pas de projet Xcode), swift-tools 5.10, macOS 13+.
Carte du code et décisions de conception (en anglais) : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```sh
swift build
swift test
scripts/build.sh      # build/Oriel.app universelle (arm64 + x86_64), signée ad hoc par défaut
scripts/make-dmg.sh   # build/Oriel-<version>.dmg et son .sha256, vérifié après création
```

- `VERSION=1.2.3 scripts/build.sh` fixe la version de l'app (par défaut : `CFBundleShortVersionString` de
  `Resources/Info.plist`). `RELEASE_CHANNEL=1` marque l'app comme build de release
  (`OrielUpdateChannel = release` dans son Info.plist) : seules celles-là se mettent à jour seules.
- `SIGN_KEYCHAIN=<trousseau> SIGN_IDENTITY=<nom du certificat> scripts/build.sh` signe avec ce certificat au
  lieu d'ad hoc (les deux variables, ou aucune). C'est ce que fait le workflow de release ; les builds locaux
  restent ad hoc et macOS redemande leurs accès après chacun.
- `scripts/test-local.sh [options de swift test]` lance `swift test --parallel` sans les classes de tests qui ouvrent des
  fenêtres à l'écran (la suite complète tourne en CI).
- `scripts/install.sh` compile et installe depuis les sources ; `scripts/uninstall.sh` retire tout.
- Traductions : `Resources/en.lproj` et `Resources/fr.lproj`. Le texte français du code sert de clé ;
  `LocalizationTests` vérifie que chaque clé utilisée dans le code a sa traduction anglaise.
- Captures PNG du panneau, avec des données fictives :
  `ORIEL_SNAPSHOT_DIR=/un/dossier swift test --filter SnapshotTests`.
- **Publier une version** = pousser un tag `vX.Y.Z`. GitHub Actions lance les tests, compile l'app universelle
  en version X.Y.Z avec `RELEASE_CHANNEL=1`, fabrique le DMG, le signe avec le secret `UPDATE_SIGNING_KEY`
  (`scripts/update-signing.swift` ; le job échoue si la signature échoue ou si la clé ne correspond pas à
  celle intégrée à l'app) et crée la release avec le DMG, son SHA-256 et sa signature. Les installations
  existantes la récupèrent seules.

  ```sh
  git tag v1.2.0
  git push origin v1.2.0
  ```

  La clé privée de signature est aussi dans le trousseau du mainteneur. La perdre casse la mise à jour
  automatique de toutes les installations existantes : elles n'acceptent que les DMG signés avec cette clé.
- **Signature du code** : le workflow de release signe l'app avec un certificat auto-signé (CN `Claude Notch
  Self-Signed`, signature de code, 10 ans) pour que son exigence désignée reste identique d'une version à
  l'autre et que macOS garde les accès accordés à l'app (TCC). Deux secrets de dépôt de plus sont nécessaires :
  `SIGNING_CERT_P12` (le `.p12`, en base64) et `SIGNING_CERT_PASSWORD` ; le job échoue tout de suite sans eux.
  Le workflow importe le certificat dans un trousseau temporaire et le supprime à la fin. Sauvegarde dans le
  trousseau de session du mainteneur, en mots de passe génériques de service
  `io.github.slybald.claudenotch.code-signing` et de comptes `p12-base64` et `p12-password`. Pour remettre les
  secrets depuis cette sauvegarde :

  ```sh
  S=io.github.slybald.claudenotch.code-signing
  printf %s "$(security find-generic-password -s $S -a p12-base64 -w)" | gh secret set SIGNING_CERT_P12 -R Slybald/oriel
  printf %s "$(security find-generic-password -s $S -a p12-password -w)" | gh secret set SIGNING_CERT_PASSWORD -R Slybald/oriel
  ```

  Ne remplace pas ce certificat à la légère : un nouveau change l'exigence et tous les utilisateurs
  revoient les demandes d'accès.

### Licence

[MIT](LICENSE).

Code tiers : `Vendor/mediaremote-adapter` (ungive/mediaremote-adapter, BSD-3-Clause, copié sans modification).
Sa notice figure dans **À propos › Licences**.
