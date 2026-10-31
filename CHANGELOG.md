# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [3.1.0] - 2026-10-31

### Changed

- **Screens without a notch** (a Mac without one, an external display): no more black block in the middle of the
  menu bar. The notch stays invisible until something happens, then shows in frosted glass.

### Added

- Settings › Appearance › "Display Without a Notch": chameleon (the default), a pill floating just below the top
  edge, or the drawn notch from before.

## [3.0.0] - 2026-10-26

### Changed

- **Everything is now called Oriel**: the app's executable, its identifier (`io.github.slybald.oriel`), its data
  folder and its hook scripts. Updating from 2.1 or earlier: download Oriel once by hand, then grant the macOS
  permissions again. Settings, notes and hooks (Claude Code and Codex) are carried over on first launch, along with
  the login item. The fan and low-power authorizations must be granted again in Settings.
- Settings › Claude explains that the quota gauges fill only while Claude Code runs in a terminal, not in the
  Claude app.

### Added

- **First launch guide** for macOS Gatekeeper, in the README (EN/FR) and as a text file inside the disk image.

### Removed

- The `ClaudeNotch-X.Y.Z.dmg` disk image: each release now ships a single `Oriel-X.Y.Z.dmg`.

## [2.1.0] - 2026-10-22

### Added

- **The bubble comes back like a drop rejoining a puddle, in ferrofluid**, live while you drag. As soon as it nears
  the notch it is pulled in, harder and harder: it stretches into a spiky drop, the notch bulges and reaches down to
  it, and when they touch a bridge of fluid forms and thickens as you come closer. Pull away and the bridge stretches
  into a thread, then breaks, and both spring back. Let go while bridged, or bring it close, and the notch sucks it in
  in one motion, then a ripple runs along its edge. "Reduce motion" keeps the simple magnet and fade.
- **The detach corner shows itself**: hovering it says "Drag the corner to detach the notch" at once, and so do the
  first three panel openings.
- **Back to the cylinder** from a tab opened in the bubble: a back button at the start of the tab bar, Esc (when the
  panel has the keyboard), a pinch, or a click outside the panel. The content folds back into its chamber.

### Changed

- Detaching the notch starts as soon as you drag its corner: the 0.3 s hold is no longer required (dragging earlier
  used to do nothing). The bubble's spring after it peels off is softer.

### Fixed

- **Detaching no longer stutters.** At the moment the drop peeled off, the app redrew the bubble for the first time,
  folded the notch and saved the setting in a single frame: 79 ms measured, about five dropped frames. The bubble is
  now drawn, transparent, while you drag; the notch folds and the setting is saved when you let go. The drop is redrawn
  once per screen refresh instead of once more at each mouse move.
- A click outside the bubble's panel always brings back the cylinder, whatever "Close on Click Outside" says.
- **The tabs beside the notch now have its curves**: the same flare where they meet the top of the screen and the
  same rounded bottom corner, instead of square edges. Opened, a card meets the notch with a rounded joint, and the
  light rim follows the outline instead of running along the top of the screen.

## [2.0.0] - 2026-10-21

**Claude Notch is now Oriel.** Same app, same settings, same data: the automatic update installs it in place and it
renames itself at its first launch (see *Changed* below). Entries below use the new name.

### Added

- **Your own index tabs: local API and `notch` command** (off by default, **Settings › Scripts**). Scripts and
  programs can put up to three small tabs beside the collapsed notch: a title, a short text, an icon and a color from
  fixed lists, for up to an hour (`POST /api/v1/ears` on the local server, see [docs/API.md](docs/API.md)).
  `notch show --title "Backup done"`, `notch run -- make test` (hourglass, then ✓ or ✗ with the duration), `notch
  clear`; the command is installed in `~/.local/bin` from the settings, only on your click. Its own token (0600 file,
  passed with `curl -H @file`), exact `Host` and no `Origin` (no web page can call it), strict schema, rate limit; no
  code, command or URL from a tab, only a button that opens a named app. A script's tab always says which program sent
  it and can never pass for a Claude or Codex request. Settings › Scripts lists the last clients.
- **Fans in Quick Settings.** A Fans card shows both fan speeds and the hottest CPU and GPU temperatures, read only
  while the tab is shown. **Fixed speed** sets the fans to a speed of your choice with a slider, never below the Mac's
  minimum nor above its maximum; **Give control back to macOS** is always visible while it is active, and the
  collapsed notch shows the speed in an index tab. Absent on Macs without fans; read-only on Intel Macs.
- The first fixed speed installs, after one administrator password, a small helper
  (`/Library/PrivilegedHelperTools/io.github.slybald.claudenotch.fanctl`) and a system rule that allows only this
  helper, with only `auto` or `hold`. The helper checks every request against the bounds read from the Mac.
- Safety: macOS gets control back when the app quits or crashes, freezes for 30 s, on sleep or session change, above
  105 °C, or when macOS itself takes a fan back. "Remove the authorization" (Settings › Quick Settings) and
  uninstalling remove the helper and its rule.
- **Agenda tab and a live countdown on the collapsed notch.** The next appointment becomes an index tab that counts
  down: a discreet calendar icon and `14 min` from 15 minutes before, amber with a camera and `4 min` from 5 minutes
  before, green `now` during the meeting, then it goes away. An amber tab stays unfolded even in *Retracted* mode, and
  ranks above the timer. Hover it to see the title, the time and the place, with a **Join** button.
- **Join.** When the event holds a Zoom, Google Meet, Microsoft Teams, Webex or FaceTime link (in its URL, its location or
  its notes), **Join** opens it in one click, from the tab, the unfolded index tab or the full-screen summary. The text
  of an event comes from a third party (an invitation), so only an `https` link on the service's own domain is kept
  (never `zoom.us.other.com`, nor an address with an account in it), plus a `facetime:` link from the event's URL field;
  the link is re-checked just before opening and never opens on its own. No link: no button, **View in Calendar** stays.
- **Agenda tab**: the week, the next appointment large (amber frame at 5 minutes, green while it runs) and the rest of the
  day below, past ones dimmed, with the place under each title. Settings › Agenda: the tab before a meeting (on by
  default) and the calendars to read. The tab is on by default and is part of the *Student* profile. It reads the
  Calendars permission the Player tab already uses, asked only when you press **Allow Calendar Access**.
- Nothing is polled: once access is granted the tab listens to the calendar database (a change, a day change, the clock,
  waking from sleep) and plans ONE wake-up at the next threshold (start − 15 min, − 5 min, start, end), one per minute
  during the 15-minute countdown. Between two wake-ups the CPU is at zero. Many changes in a row (an iCloud sync) cost a
  single re-read.
- **Quota gauges** in the Claude and Codex tabs: a thin ring, the percentage used and the reset time of the 5-hour and
  7-day windows, amber from 80 % and red from 95 %, also in the summary that unfolds from the collapsed tab. Nothing is
  shown when a tab is off or when the agent gives no figure.
- **Claude** (Settings › Claude › Show quota, off by default): Claude Code only gives the quota to its `statusLine`, so a small
  relay takes its place in `~/.claude/settings.json` (timestamped backup), sends `rate_limits` to the app and then runs your
  previous command with the same data. Turning it off, or uninstalling, puts your command back exactly. Pro and Max only.
  Measured with Claude Code 2.1.304. Only percentages and reset times are kept, in memory.
- **Codex** (Settings › Codex › Show quota, on by default): read from Codex itself (`account/rateLimits/read`, ChatGPT
  sign-in) only while the panel is open, at most once a minute, then every 5 minutes. Measured with Codex 0.154 and 0.162.
- **Command bar.** A field in the notch with one-key prefixes: `t 25` starts a timer (also `t 1h30`, or `25 min`
  without the prefix; `t` alone offers 25, 5 and 10 minutes and the Pomodoro), `n idea` creates a quick note,
  `c link` searches the clipboard history and copies the chosen entry again, `s presentation` applies a Quick Settings
  scene (and `s fans` gives a fixed fan speed back to macOS), `m invoice` opens one of the latest emails in Mail,
  `a team` joins the next meeting or opens Calendar on that day, `i backup` removes a tab put up by a script,
  `> message` writes to a Claude session (only with "Reply from the notch" on). The prefixes are shown under the
  field and can be clicked; typing one turns it into a pill, Backspace brings it back. ↑ ↓ choose, ⏎ runs, Esc closes;
  nothing runs before ⏎ (or a click on the row). The panel opens with the bar and closes with it.
  Settings › General › Shortcuts has a new "Command bar" shortcut (none by default, ⌥⌘K is offered), and
  **…** › **Command Bar…** opens it without a shortcut. Fuzzy search ignores case and accents.
- `NotchModule` gets two optional members, `commandVerb` and `commands(for:)` (empty by default): a module offers its
  own actions to the bar, nothing is hard-coded in the bar. A stopped or hidden tab is never woken by a search.
- **Detach the notch into a bubble.** Hold the bottom right corner of the open panel (a small arc marks it), then drag:
  the panel stretches like a drop of liquid, a neck forms and thins, and the drop comes off as a round bubble you can put
  anywhere on your screens (all Spaces, above apps, like the notch). Its position is remembered per display.
- **Tabs in a revolver cylinder.** Inside the bubble, your tabs sit in a circle in the order you chose; the one at the
  top is the active tab. Scroll, drag around the cylinder or click a tab to turn it, one detent at a time; click the
  centre (or the top tab) and the bubble opens into the panel with that tab, then closes back into a bubble. Activities
  (Claude working, a timer, music…) show as a colored ring and a pill on the bubble, and a dot on their tab.
- **Back to the notch**: bring the bubble under the notch (it snaps to it) and it merges back with the reverse drop
  effect; or double-click its edge, or choose **Reattach to Notch** (right click, **…** menu). While detached, hovering
  the notch does not open a second panel; index tabs still work and open the bubble on their tab, and the panel
  shortcut, the command bar and a keyboard approval open in the bubble's panel. **Detach Notch** is
  also in the **…** menu and the right-click menu of the notch, and VoiceOver can use it and turn the cylinder.
- **Settings › General › Bubble**: *Allow detaching the notch* (on by default) and *Return to the notch at relaunch*.
  With "Reduce motion", the drop becomes a simple fade.

### Changed

- **Index tabs fan out like cards on a table.** At rest the tabs of each side overlap: the most important one is on
  top, against the notch, with its icon and short text; each of the others slides under the previous one and shows a
  regular slice with its icon only, with a thin light edge and a soft shade so the stack reads. Every tab is exactly as
  tall as the notch (same top, same bottom, one continuous base, no staircase): the overlap is only horizontal. Hover a
  slice and the tab opens wide with its details, with the usual spring; the tabs closer to the notch stay where they are
  and the ones further out go under it, so nothing slides under a still pointer. Click a tab to open the panel on it, as
  before. *Always Visible* is the half-closed fan, *Retracted* the tight one (a thin sliver per tab); an alert still
  stays open. Nothing runs at rest and the hover zones are the exact shapes.
- **Renamed to Oriel.** The app, its menus, settings, setup assistant, alerts and macOS permission prompts now say
  Oriel. The bundle is `Oriel.app`, the disk image `Oriel-<v>.dmg` (volume "Oriel"). The repository is now
  `github.com/Slybald/oriel`; the old address redirects.
- **Existing users have nothing to do.** The automatic update installs the new version in place of `ClaudeNotch.app`;
  at its first launch the app renames itself `Oriel.app`, points open-at-login to the new path and restarts (one
  instance only). macOS permissions, settings, hooks and data are kept: the bundle identifier
  (`io.github.slybald.claudenotch`), the signing certificate, the data and log folders and the hook scripts keep their
  names. An older `ClaudeNotch.app` found next to `Oriel.app` is moved to the Trash.
- **Two disk images per release.** `Oriel-<v>.dmg` (with `Oriel.app`) is the one to download. A second signed image,
  `ClaudeNotch-<v>.dmg` (the same app in a `ClaudeNotch.app` folder), is still published because versions 1.1.0 to
  1.9.0 only look for that name when they update themselves.
- Messages sent to Claude now say "Message from Oriel" and "Message from the user, sent from Oriel:", and a denial
  from the notch says "The user denied this from Oriel." (Codex: "Denied from Oriel."). The Claude Code hook entries
  are rewritten at launch, with a timestamped backup of `settings.json`; sessions already open keep the old text,
  which is still recognised. The Codex hook entries are not touched, so Codex does not ask for their approval again;
  its status line during a held request still reads "Claude Notch" until the Codex hooks next change.

### Fixed

- **Index tabs now line up with the real notch.** The tab against the notch was 3 pt shorter than it, so the notch showed
  as a small lip under the tabs with a step on each side and a gap in its rounded bottom corners; and the collapsed shape
  drew 6 pt flares on each side of the notch, so on a side without a tab it stuck out of the notch (the shape measured
  197 pt for a 185 pt notch). The central part is now exactly the notch (same width and height), the first tab on each side
  is as tall as the notch and continues it without a step or a gap, in every state (always visible, retracted, unfolded,
  virtual notch). Tests measure the rendered silhouette against the notch for several notch sizes.

## [1.9.0] - 2026-10-21

### Added

- **Approve with the keyboard.** A permission request from Claude Code or Codex can be settled without the mouse:
  **⌃⌥Y** allows, **⌃⌥N** denies the oldest waiting request, both agents in one queue ("1 of 3" on its card, the two keys
  shown on its buttons). Off by default (Settings › Claude and › Codex › *Approve with the keyboard*; it needs *Reply
  from the notch* / *Approve from the notch* on). Safeguards, because a reflex must never allow a command you have not read:
  - the two combinations are only taken while a request waits (nothing is reserved the rest of the time), and macOS
    refuses them if another app already owns them (the card then shows no key);
  - a key only decides if that card is open in the notch and has been for more than a second. Otherwise the first press
    just opens the notch on the right tab (without taking the keyboard, so typing elsewhere is not hijacked) and decides nothing;
  - one request at a time: once it is settled, the next one starts its one second again, so a repeated press never
    settles two requests; questions and plans still need the mouse;
  - same deciders as a click: nothing is ever "always allowed", the timeouts and "first answer wins" are unchanged.

## [1.8.0] - 2026-10-21

### Changed

- **Index tabs on the collapsed notch.** Each activity (Claude, now playing, timer, Codex, unread messages, caffeine…)
  gets its own small tab against the notch, left and right, the most important closest to it (three per side at most,
  then a "+N"). This replaces the 1.2.2 rotation, where Claude and the other ears took turns every 4 seconds: index tabs
  sit side by side. Each tab shows its icon and a very short text (`1·6`, `4:59`, equalizer bars) with its own shape,
  height (a staircase away from the notch) and a discreet accent color.
- Hover a tab and it unfolds with its details: the track with its controls, the timer with its phase and a pause button,
  the Claude sessions and their state. Click it to open the panel on that tab. The centre of the notch still opens the
  whole panel, and the two zones never overlap.
- **Settings › Appearance › Collapsed Notch › Index Tabs** replaces "Alternate Claude and the Other Ears": *Always
  Visible* (default: the information is readable at a glance, same footprint as the old ears in the usual case) or
  *Retracted* (a thin sliver until you hover, for a quiet notch). An alert (Claude or Codex waiting for you) always stays
  visible. The old setting carries over once: on (or never set) becomes *Always Visible*, off becomes *Retracted*.

### Removed

- The 4-second timer and `EarsRotation` of the alternating ears: nothing runs at rest on the collapsed notch.

### Fixed

- **Codex tab with the ChatGPT app.** Codex ignores a hook until it is approved, and says nothing, so after "Install Codex
  hooks" the tab stayed empty with no explanation. The tab and Settings › Codex now show the real state: *hooks not
  installed*, *waiting for approval in Codex*, or *active*. While approval is pending, **Approve in Codex** asks Codex itself
  (the same request as the **Review hooks** button of the ChatGPT app) to trust the Claude Notch hooks, and only those,
  on your click; the app still never writes `config.toml`. The state is read without changing anything (`hooks/list`
  of the app's own Codex, falling back to reading `config.toml`), a hook modified since its approval is reported, and the
  tab updates by itself once the hooks are approved, here, in the app or with `/hooks`. Conversations already open when the
  hooks are approved are not tracked: the tab says to start a new one.
- **Codex in the ChatGPT app is recognised as such.** The ChatGPT app (which now contains Codex) counts as Codex being
  present (the tab is on at first launch), its sessions read **ChatGPT**, and clicking one opens that conversation
  (`codex://threads/<id>`) instead of only bringing the app to the front. Measured with the app's own Codex 0.162;
  the README describes the approval of the hooks.

### Changed

- **Mail tab: your latest received emails instead of only the unread ones.** It now lists the latest 3 to 5 emails of
  the inbox (Settings › Mail, 5 by default), read or not: sender, subject, the start of the text on one or two
  lines, relative time and a dot when unread. The badge on the collapsed notch is still the unread count. Click a row
  to open it in Mail.
- The list is read by position (`messages 1 thru N of inbox`) instead of filtering the whole inbox. Measured on a real
  inbox of 5,316 emails, the old unread filter did not answer within 30 seconds ("Mail is not responding"); the new
  read takes about 5 seconds the first time and 1.5 seconds after.
- With "Show senders, subjects and the start of messages" off, the list is not even read, only the counters.

### Added

- **Reply from the notch.** Hover an email and click **Reply**: a field opens under it (Return sends, Esc closes).
  The answer goes to the sender only, with Mail's own "Re: …" subject and quoted text. It is sent **only** when you
  click **Send** or press Return, never on its own. **Continue in Mail** opens Mail's reply window with your text
  already typed. "Sent" confirms; errors say what to do (Mail closed → a button to open it, never launched on its own;
  permission denied → Settings; no confirmation from Mail → check before trying again). Your text is kept after an error.

## [1.7.0] - 2026-10-21

### Added

- **Codex tab** (optional). Follows the sessions of OpenAI's Codex (CLI and app) with Codex's own hooks: which ones run,
  whether Codex is working, waiting for an approval or done, its last message and the elapsed time. Like the Claude
  tab, it is on at first launch only if Codex is found on the Mac, the setup assistant offers it only then, and it
  does nothing in the background when it is off. Its ears take turns with the others in the collapsed notch, and the
  full-screen compact mode lists the sessions.
- **Approve from the notch** (Settings › Codex, off by default): allow or deny a command or a patch, or hand the
  question back to the terminal. Codex waits for the notch before asking in the terminal, so the hold is short (4 seconds
  if the card never appeared, 60 seconds otherwise); nothing is ever approved by default.
- **Settings › Codex › Install Codex hooks** adds the hooks to `~/.codex/hooks.json` (timestamped backup, your hooks
  and key order kept, nothing written if nothing changes, an invalid file is refused) and **Remove the hooks** takes only
  ours away; Uninstall Claude Notch removes them too. `config.toml` and its `notify` are never touched. Codex runs a new
  hook only after you trust it with `/hooks`; the settings say so.

### Not possible

- Writing a message to a running Codex session and answering Codex's own questions: Codex offers no safe way (no hook).

## [1.6.0] - 2026-10-21

### Added

- Two optional tabs, **off by default** (turn them on in Settings › Tabs or by editing the tabs in the notch):
  **Messages** shows your recent iMessage and SMS conversations with an unread badge on the collapsed notch and a quick
  reply; **Mail** shows the unread count of Apple Mail and the latest unread messages, and opens one on click.
  Messages needs Full Disk Access (macOS has no dialog for it: the tab explains it and links to System Settings),
  Contacts for names, and Automation to reply. Mail needs Automation and is never launched by Claude Notch. Nothing
  is stored or sent outside the Mac, and no permission is asked before you open the tab. Limits are listed in
  the README.
- Profiles: Developer, Student, Creative and Minimal. A profile is a starting point (which tabs, in which order, how
  the panel opens, the ears) inside the same app: one update, one signature. The first step of the setup assistant
  offers them (optional, nothing changes without a choice), and **Settings › General › Change Profile…** shows what a
  profile will show and hide and changes nothing until you confirm. Your tab data and the hooks are never touched.
  Claude and Codex are only offered when they are found on the Mac.

### Fixed

- Messages to a Claude session from the notch were left queued after the app restarted (an update, a relaunch):
  every waiting hook dropped with the app and only came back at the session's next turn. The hook now reconnects
  by itself when the app is back (within 30 seconds).
- When a message cannot reach an idle session right away, the conversation says it will go on Claude's next turn
  (not "at the end of the turn") and offers **Open** to write in the session at once.

### Changed

- `/state` shows how each session can be reached (`replyChannel`).

## [1.5.0] - 2026-10-21

### Added

- Talk to Claude from the notch: hover a session card and click **Chat** to see what Claude just said (and what
  your subagents reported), what you wrote, and a field to write to it. It works for the CLI and for the Code tab
  of Claude Desktop (checked with Claude Code 2.1.304: permissions, questions and messages that wake Claude).
- A card at the top of the Claude tab offers to turn on "Reply from the notch" (**Turn On** / **Later**) instead
  of leaving it in Settings › Claude. Nothing is decided without your click, and the terminal or Claude Desktop
  keep control.
- When the notch cannot write to a session (`claude -p`, the Agent SDK, an IDE, a session opened before the hook
  script was updated), the conversation says "Answer in *app*" with an **Open** button.

### Changed

- The hook script sends the Claude Desktop session ID with its waiting requests (`inbox`), so the Code tab of
  Claude Desktop is held at the end of a turn only. Held at the start of a session, the hook would delay the first
  prompt.

## [1.4.0] - 2026-10-21

### Added

- A setup assistant replaces the welcome window on first launch. In four short steps you pick the tabs you want
  (one card each; the Claude card only when Claude Code is found on the Mac, with the hooks as an option that is
  off by default), how the notch opens (hover or click, an optional keyboard shortcut, open at login), and see a
  preview of your notch. "Skip" is always there and changes nothing; nothing is written before "Apply". It asks
  for no macOS permission. It is shown once, and not after an update from a version that was already set up.
- **Settings › General › Run the Setup Assistant Again** goes through the steps again, starting from the current
  settings.

### Changed

- The hooks window (Settings › Claude, the **…** menu, a failed silent update) no longer carries the welcome
  content.

## [1.3.0] - 2026-10-21

### Added

- Edit the tabs in the notch, like apps on an iPhone: press and hold the tab bar, then drag the icons to reorder
  them, hide a tab with **−** (never the last one) or bring one back with **+**. **Done**, Esc or a click outside the
  bar ends it. Same settings as **Settings › Tabs**, which stays in sync.

## [1.2.3] - 2026-10-21

### Fixed

- Updates were checked every 6 hours of awake time only: after a night of sleep the app could go a whole morning
  without noticing a new version. It now also checks when the Mac wakes up, if the last check is older than
  6 hours.

## [1.2.2] - 2026-10-20

### Added

- The collapsed notch alternates Claude and the other tabs' ears (now playing, timer) every 4 seconds, like index
  tabs, while Claude is working or has just finished; when Claude is waiting for you it stays alone. Turn it off
  in **Settings › Appearance › Collapsed Notch** ("Alternate Claude and the Other Ears").

### Changed

- Low Power Mode: the first click on the tile asks for the password once and, in the same system prompt, adds the
  rule that lets later switches go through without it (the prompt says so). The note at the bottom of the tab is
  gone. "Remove the authorization" in Settings stops this automatic setup.

## [1.2.1] - 2026-10-20

### Added

- A welcome window on first launch: how to open the notch, its tabs, where the settings are. The Claude Code hooks
  are offered there only when Claude Code is found on the Mac (`~/.claude` or `$CLAUDE_CONFIG_DIR`), and can wait
  ("Later"); otherwise the window says where to turn on the Claude tab.

### Changed

- The Claude Code integration is optional. The Claude tab can be turned off in **Settings › Tabs** like any other
  tab. On first launch it is on only if Claude Code is found on the Mac; that choice is saved and does not change
  afterwards. With the tab off, nothing Claude-related runs: no process scan, no session tracking, hook events are
  ignored and permission and message requests go straight back to the terminal, no Claude ears, the panel never
  switches to Claude, and the **…** menu shows no session or hook items. Turning the tab back on restarts
  everything; open sessions show up at their next message.
- The notch is shown **Always** by default, for everyone. With the Claude tab off, **When Claude Is Open** is no
  longer offered and acts as **Always**, and **During Activity** only counts the tabs' ears.
- Hooks are still updated silently after an update, but only for people who already had them, with the Claude
  tab on. The window no longer asks for the hooks at every launch.

- Low Power Mode no longer asks for the administrator password at every switch. **Settings › Quick Settings**
  (or "Don't ask again" in the tab) adds, once, a system rule that only allows `pmset -a lowpowermode 0|1`
  (`/etc/sudoers.d/claude-notch-lowpower`, checked by `visudo` before it is installed, written by root only).
  Switches then go through `sudo -n`; if the rule stops working, the password is asked again and the app offers
  to set it back. "Remove the authorization" and uninstalling (app or script) remove it.

### Fixed

- 1.2.0 saved **When Claude Is Open** on its own for people who already had the hooks. It is set back to
  **Always**, once (someone who picked it on purpose during 1.2.0 gets **Always** once too).
- Tabs no longer shift under the pointer when hovering opens one (fixed-width tab bar, title shown beside it).

## [1.2.0] - 2026-10-20

### Added

- Tabs in the expanded notch: **Claude**, **Player** (now playing and calendar), **Quick Settings**, **Shelf**,
  **Clipboard**, **Timer** and **Quick notes**. Click a tab or hover it briefly. The panel reopens on the last tab
  used, or on Claude when a session needs you. Tabs can be hidden, reordered and set as default in Settings.
- **Player**: artwork, title, artist and source app of the track playing, with progress (drag to seek),
  previous, play/pause and next. Artwork and an animated equalizer show in the collapsed notch's ears.
  A week view of Calendar, read only while the tab is on screen.
- **Quick Settings**: Wi-Fi, Bluetooth, Focus (through a Shortcuts shortcut), Low Power Mode, caffeine (1 h, 2 h
  or no limit), battery of the Mac and of AirPods, three scenes (Battery, Normal, Presentation), and an optional
  switch to Battery below a chosen charge level.
- **Shelf**: a holding area for files and folders. It keeps a reference to each item, never a copy. Drop files
  on the notch, even when collapsed; drag them out to Finder or another app (copy or alias). Multi-select,
  Quick Look, Share, AirDrop.
- **Clipboard**: history of text, links, images, files and colors, 25, 50 or 100 items, pinned items kept.
  Copies from password managers and items marked as confidential or transient are never recorded. Memory only
  unless you choose to keep text and links across restarts. Capture can be suspended.
- **Timer**: a countdown and a Pomodoro cycle (focus and break lengths in Settings). It keeps counting across
  sleep and restart, and sends a notification at the end.
- **Quick notes**: plain-text notes, pin or delete (with undo), search beyond 8 notes.
- **Reply from the notch** (Settings › Claude, off by default): allow or deny a permission, answer a question,
  approve a plan or ask for changes, and send a message to a session. The terminal stays usable; the first
  answer wins.
- Notch settings: show the notch always, while Claude is open or during activity; hide it for an hour, until
  tomorrow morning or until turned back on (also from a right click on the notch); open on hover or on click,
  close on a click outside; two optional global shortcuts (open the panel with the keyboard, hide the notch);
  screen choice (built-in, main, under the mouse or by name) with a virtual notch on screens without one; free
  panel width, background color, shadow, animation speed (simple fade with Reduce Motion); hide the notch from
  screenshots and screen sharing; reset to defaults. Opening the app again while it runs shows a hidden notch
  and the settings.
- Full screen: when an app is full screen on the notch's screen, the expanded panel becomes compact (half
  width, running sessions only), stays normal, or the notch hides, as set in Settings.
- Settings window (**…** menu › **Settings…**, ⌘,): open at login, visibility, hover delays, haptic feedback, full-screen
  behavior, tabs, accent color, panel size, background opacity, ears, Claude, updates, about and licenses.
- `GET /state`: window level seen by the window server, Space, occlusion, screen, front app, full-screen state,
  tab and running modules.

### Changed

- Hooks: Claude Notch now also installs a synchronous `PermissionRequest` hook and a waiting `SessionStart` and
  `Stop` hook, used by replies from the notch. Hooks installed by a previous version are updated at launch, with
  the usual timestamped backup of `settings.json`.
- macOS permissions are asked only when the feature that needs them is used: Calendars, Automation (Calendar),
  Bluetooth, Notifications (timer), pasteboard access on macOS 15.4 and later (clipboard).
- No more one-second timer while there is no session.
- Release builds are signed with a fixed self-signed certificate instead of ad hoc, so macOS keeps the accesses
  granted to the app (calendar, Bluetooth, Automation, folders) from one update to the next. Moving to the first
  release signed this way asks for them one last time. Local builds stay ad hoc.
- Release workflow: the signing certificate comes from the `SIGNING_CERT_P12` and `SIGNING_CERT_PASSWORD`
  secrets (temporary keychain), the signature is checked before the DMG is made; a missing secret fails the job.

### Fixed

- The notch was drawn below the menu bar and disappeared behind full-screen apps: setting `isFloatingPanel`
  reset the window level to 3. It now sits above the menu bar (level 27).
- The hook script read the user's curl configuration (`~/.curlrc`) and proxy variables, which could break its
  output or redirect its requests. It now ignores both: it only talks to `127.0.0.1`.

## [1.1.0] - 2026-10-20

### Added

- Automatic updates from GitHub releases: check 60 s after launch, then every 6 hours; the DMG is installed only
  if its Ed25519 signature matches the public key built into the app; the app is swapped by renames with a
  rollback, then restarts by itself. A new version is installed at launch, or later when no session is running
  or waiting for you. Only apps built for a release update themselves.
- **…** menu: version line ("Updating to X…", "Updated to X"), **Automatic Updates** (on by default),
  **Check for Updates**, **Install** when automatic updates are off, or the release page when the app cannot
  replace itself (outside `/Applications` and `~/Applications`, or folder not writable).
- `GET /state`: `version` and `updater` keys.
- Release workflow: release builds (`RELEASE_CHANNEL=1`), signed DMG (`.dmg.sig` published next to the DMG and
  its SHA-256); a failed signature fails the job.

### Changed

- After an update, when only the bundled hook script changed, it is reinstalled silently at launch, without
  the first-launch window and without touching `settings.json`.
- The app now makes outgoing requests to GitHub (update check and download). Nothing about you or your
  sessions is sent.

## [1.0.0] - 2026-10-19

First public release.

### Added

- Notch panel that tracks Claude Code sessions from the CLI (terminals, editors) and from the Code tab of
  Claude Desktop, fed by async hooks relayed to a local server on `127.0.0.1:47823`.
- Session states: ready, thinking, running a tool, waiting for permission, waiting for an answer, plan to
  review, done, error, compacting; sessions that need you are listed first.
- Collapsed notch with two ears: overall state on the left, `sessions·subagents` (e.g. `1·6`) or task
  progress on the right.
- Permission details (command, file, question), task list progress, running subagents per session.
- Click on a card: brings the host app to the front, or opens the exact session in Claude Desktop.
- Optional tools section: recent files written by Claude, Git status, today's usage.
- Local logs of written files and permission requests in `~/Library/Application Support/ClaudeNotch/`.
- First-launch window that installs the hooks (backup of `settings.json`, existing hooks kept, key order
  preserved), and an uninstall command in the **…** menu (**Uninstall Claude Notch…**).
- Interface in English and French, following the system language.
- Migration from early builds (`local.claudenotch`): the new version replaces the running one and keeps
  the "open at login" setting.
- Universal app (Apple silicon and Intel), macOS 13 or later, distributed as a DMG built by GitHub Actions
  from version tags.

[1.2.0]: https://github.com/Slybald/oriel/releases/tag/v1.2.0
[1.1.0]: https://github.com/Slybald/oriel/releases/tag/v1.1.0
[1.0.0]: https://github.com/Slybald/oriel/releases/tag/v1.0.0
