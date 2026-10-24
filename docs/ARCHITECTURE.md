# Architecture and design decisions

For contributors. The [README](../README.md) describes the product; this page explains how the code is
organised and why some choices were made, so they are not undone by accident.

The product is called Oriel (formerly Claude Notch). Since 2.2 every internal name follows: the Swift module and
`Sources/Oriel`, the executable `Oriel`, the bundle identifier `io.github.slybald.oriel`, the data folder, the hook
scripts. Not renamed: the repository name, the local API port, and the signing certificate (CN `Claude Notch
Self-Signed`, a GitHub secret; renaming it would change the code requirement and reset every macOS permission).
The old names live on only as constants of the one-time migration (`LegacyMigration`, `AppIdentity.legacyBundleIds`).
This reverses the earlier decision to keep the old names so that updating kept permissions: the cost is one manual
reinstall for people on 2.1 or earlier (see "Rename migration" below).

## Commands

- `swift build`: must produce **zero warnings** (the only tolerated one is the toolchain's
  "x86_64 architecture is deprecated" during the universal build).
- `swift test`: all green; 7 diagnostic tests are skipped unless their environment variables are set.
- Offscreen PNG renders: `ORIEL_SNAPSHOT_DIR=/some/dir swift test --filter SnapshotTests` (notch, tabs,
  compact mode, settings window, reply cards in `ClaudeSnapshotTests`). Known artifact: under the notch's
  `clipShape`, SF Symbols come out white in these renders (`layer.render` and `cacheDisplay` alike); a
  window-server capture of the same view shows them tinted, as on screen.
- Real Codex check (skipped by default, uses a little quota): `ORIEL_CODEX_LIVE=1 swift test --filter CodexLiveTests`
  drives `codex app-server` through the real installer, hook script and server in a throwaway `CODEX_HOME`.
- Memory and CPU of the notch view: `ORIEL_FOOTPRINT=1 swift test --filter FootprintTests`.
- `scripts/build.sh` (universal app in `build/`, ad hoc signed unless `SIGN_KEYCHAIN` and `SIGN_IDENTITY` are
  set; `VERSION=x.y.z` sets the version, `RELEASE_CHANNEL=1` marks a release build), `scripts/make-dmg.sh`
  (DMG + SHA-256), `scripts/install.sh` (developer install), `scripts/update-signing.swift` (Ed25519 key
  generation, signing, verification).
- Release: push a `vX.Y.Z` tag; `.github/workflows/release.yml` imports the signing certificate into a temporary
  keychain, builds the app with `RELEASE_CHANNEL=1`, checks its code signature, makes the DMG, signs it with the
  `UPDATE_SIGNING_KEY` secret and creates the release (DMG, `.sha256`, `.sig`).
- Live diagnostics of the running app: `GET http://127.0.0.1:47823/state` with the hook token
  (`curl -H @"$HOME/Library/Application Support/Oriel/hook-token" …`): sessions, notch, tools, jobs,
  version, updater, replies (counts only), local API (on, tab count, client names); `notch` gives the window level seen by the window server, the Space,
  occlusion, screen, front app, full-screen state, tab, tab edit mode (`editingTabs`) and running modules.

## Code map (`Sources/Oriel/`)

- `HookServer`: minimal HTTP server on 127.0.0.1:47823. It resolves the process context *before* replying,
  while the hook process is still alive. Exact `Host`, no `Origin`, token (`HookAccess`) on every route but
  `/health` and `/api/…`; `/permission` and `/inbox` are long requests handed to `ReplyCenter`; `/codex/hook` and `/codex/permission` do the
  same for Codex (`CodexRelay`); `/claude/status` hands the `statusLine` JSON to `ClaudeUsageStore` (quota gauges);
  `/api/…` goes to `LocalAPI` with its own token. `HookEvent`: tolerant JSON reading, every field optional.
- `ProcessInspector`: walks the ancestors of the hook's `$PPID` to find the Claude process, the host app
  (outermost `.app` bundle) and the source (CLI or Desktop). `ClaudeMonitor`: is Claude Desktop running,
  which `claude` processes are alive (2 s scan, only while the Claude tab is on).
- `SessionStore`: per-session state machine, task lists (`~/.claude/tasks/<session_id>/`), Esc detection, the last
  6 lines of each conversation (`Utterance`: prompt, `Stop`, `SubagentStop`; memory only, never on disk or in
  `/state`).
- `NotchController` (window, hover, visibility, full screen), `NotchViews` (root, panel, tab bar,
  session cards), `EarTabs` (index tabs of the collapsed notch: choice, left/right split, geometry and hover zones, pure)
  and `EarTabViews` (their drawing), `ToolsViews` / `ToolsFeed` (tools section). `FullScreenDetector`: is the front app full screen
  on the notch's screen. `NotchShell`: rules tested without a real screen (visibility, screen choice, real or
  virtual notch, "hidden until" text). `HotKeys`: global shortcuts and the keys of the panel.
- `Command/`: the command bar. `CommandBarModel` (pure: `CommandVerb`, `CommandQuery`, `NotchCommand`, `CommandParser`,
  `FuzzyMatch`, the model that routes a query to the modules and ranks the answers) and `CommandBarView` (the field, an
  AppKit `NSTextField` because SwiftUI's `TextField` gets no ↑ ↓ before macOS 14, the rows, the prefix chips).
- `Bubble` (pure: phases, detach and magnet thresholds, screen clamping, position per screen, revolver geometry and
  detents, drop shapes), `BubbleViews` (corner handle, drop canvas, revolver bubble, bubble panel) and `BubbleWindow`
  (`BubbleController`: the bubble window, the drop window, detaching and reattaching). See "Detached notch" below.
- `Modules/`: `NotchModule` (the contract), `ModuleRegistry` (order, activation, life cycle, ears), one folder
  per module:
  - `Claude/`: sessions, compact summary, Claude settings. `ReplyCenter` holds the long requests of `/permission`
    and `/inbox` (one waiter per session, FIFO queue of messages); `ReplyViews` draws the cards;
    `ApprovalQueue` (approve with the keyboard, see below) and `ApprovalViews` (key caps, rank, settings row);
    `ConversationViews` draws the conversation of a session (last lines, message field, or "Answer in *app*" +
    **Open**) and the card that proposes to turn replies on.
  - `Quota/`: not a tab. `QuotaModels` (`QuotaWindow`, `QuotaSnapshot`: percent, reset, 5 h / 7 d labels, expiry) and
    `QuotaViews` (the ring and the one-line strip shared by the Claude and Codex tabs).
  - `Codex/` (`codex`): `CodexModule` (tab, ears, settings, `CodexRelay` for the server), `CodexStore` (per-session state
    machine fed by Codex's hooks, one `kqueue` per Codex process, one-shot deadlines, no periodic timer),
    `CodexApprovals` (the held `PermissionRequest` requests), `CodexHookInstaller` (`~/.codex/hooks.json`),
    `CodexProcess` (Codex process and host app from the hook's `$PPID`), `CodexUsage` (quota gauge store), `CodexViews`.
    See *Codex* below.
  - `Media/` (`media`): `MediaModule` (life cycle, settings), `NowPlaying` (state rebuilt from the
    `mediaremote-adapter` JSON lines; `MediaRemoteAdapter` runs the helper and restarts it with a growing delay),
    `MediaCalendar` (week maths and the Calendar opener), `MediaViews`.
  - `Agenda/` (`agenda`): `AgendaModule` (calendar access, one planned wake-up, ears), `AgendaModels` (pure: `MeetingLink`,
    `AgendaMath.focus` / `nextWake`, texts), `AgendaViews` (tab, unfolded index tab, compact line, settings).
    `Modules/CalendarSource.swift` (shared with Media): `CalendarSource`, `EventKitCalendar`, `MediaEvent` (with `location`
    and `meeting`). See "Agenda: a live index tab" below.
  - `QuickSettings/` (`quicksettings`): `QuickSettingsModule` (tiles, scenes, caffeine, automatic switch),
    `QuickSettingsBackends` (the system accesses, behind protocols: CoreWLAN, IOBluetooth loaded at runtime,
    `pmset`, IOPS, IOPMAssertion, `shortcuts run`), `QuickSettingsModels` (pure parsers and state), `QuickSettingsViews`.
    Fans: `FanController` (reading while the tab is shown, fixed speed held by the helper), `FanBackend` (SMC reads,
    helper install, `sudo -n fanctl hold`), `FanAuthorization` (pure: sudoers rule and root install command),
    `FanViews`. The SMC code is the `FanControl` library (`Sources/FanControl`), shared with the `fanctl` helper
    (`Sources/fanctl`, root, `auto` and `hold` only).
  - `Shelf/` (`shelf`): `ShelfModule`, `ShelfStore` (bookmarks in `shelf.json`), `ShelfAppKit` (drag and drop,
    Quick Look, `ShelfDropView`, the AppKit view under the notch's SwiftUI content), `ShelfViews`.
  - `Clipboard/` (`clipboard`): `ClipboardModule` (capture by change count, limits, suspension), `ClipboardSystem`
    (pasteboard reads and access), `ClipboardModels` (history and `ClipboardPrivacy` rules), `ClipboardStorage`
    (opt-in history file), `ClipboardViews`.
  - `Timer/` (`timer`): `TimerModule`, `TimerEngine` (pure state machine, keeps an end date), `TimerSystem`
    (sounds and notifications), `ModuleStorage` (`ModuleScheduler` and `SecureJSONFile`, shared with Notes),
    `TimerViews`.
  - `Notes/` (`notes`): `NotesModule` (list, limits, undo, save) and `NotesViews` (plain-text editor).
  - `Messages/` (`messages`, off by default): `MessagesModule` (state, badge, quick reply), `MessagesBackends`
    (read-only `chat.db` through `SQLite3`, Contacts, FSEvents watcher, AppleScript sender: all behind protocols),
    `MessagesModels` (typedstream decoder for `attributedBody`, dates, contact book), `MessagesViews`.
  - `Mail/` (`mail`, off by default): `MailModule` (state, 2-minute counter poll while Mail runs, the 3 to 5 latest
    received emails, the reply in progress), `MailModels` (the read and reply AppleScripts and the parser of their
    answers), `MailViews` (list, hover "Reply" button, reply bar). `AppleEvents.swift` is shared by both: Automation status
    without a prompt, `osascript` runner with a time limit, System Settings privacy links.
- `Preferences`: every setting (UserDefaults, observable, values clamped). `SettingsWindow`: the settings
  window (SwiftUI in an `NSWindow`, sidebar) and the main menu (⌘, ⌘W, editing).
- `NotchShell`: notch rules that do not need a window: visibility (`NotchVisibilityRule`), screen choice and
  virtual notch geometry (`NotchScreenPicker`). `HotKeys`: global shortcuts (`HotKeyCenter`) through Carbon
  `RegisterEventHotKey`, which needs no Accessibility permission.
- `HookInstaller` + `OrderedJSON`: add and remove the hooks in `~/.claude/settings.json`. `Onboarding`:
  hook window (install, update) and hook menu items. `SetupAssistant`: the first-launch setup assistant.
  `AppIdentity`: bundle identifier and migration from early builds.
- `ActivityLog`: `files.jsonl` / `permissions.jsonl`. `JobRunner`: optional companion tool jobs.
- `Localization`: the `L()` helper, with an optional table. `LaunchAgent`: open at login.
- `Updater`: automatic updates from GitHub releases (check, signature, install, relaunch) and its menu items.
- `LocalAPI`: the local API of the user's scripts (`/api/v1/ears`, see [API.md](API.md)): token, strict schema
  (`ExternalEar`), rate limit, expiry, the ear tabs it hands to `ModuleRegistry` (ids `api.<id>`), and `NotchCLI`
  (installs `hooks/notch` in `~/.local/bin`). `LocalAPIViews`: the unfolded card of a script's tab and Settings › Scripts.

## Modules (tabs)

The expanded notch is a row of tabs; each tab is a module. Adding a module means: a folder
`Sources/Oriel/Modules/<Name>/`, its string tables `Resources/{en,fr}.lproj/<Name>.strings`, and one line
in `ModuleRegistry.standardModules`. A module never edits `Info.plist` (the usage descriptions for calendars,
Apple Events and Bluetooth are already there; Messages added the one for Contacts) nor another module's files.

- **Contract** (`NotchModule`, an `ObservableObject`): stable `id` (the settings key: never change it), localized
  `title`, SF Symbol `symbol`, `makeView()`. Optional, with defaults: `makeCompactView()` (full-screen summary),
  `ears` (with a `priority`), `keepsRunningWhenCollapsed`, `makeSettingsView()` (a `SettingsPane`, listed in the
  settings sidebar), `licenseNotices` (About › Licenses), `makeTabIcon()`, `makeHeaderAccessory()`,
  `isEnabledByDefault`, `start()` / `stop()`, `commandVerb` and `commands(for:)` (the command bar, below).
- **Life cycle**: the registry calls `start()` when a module is enabled *and* useful (the panel is open, or the
  module returns `keepsRunningWhenCollapsed`, re-read after each of its `objectWillChange`), and `stop()` as soon
  as that is no longer true, including when it is disabled. Stopped, a module does no work at all: no timer, no
  observer, no file read. All enabled modules run while the panel is open, so tabs switch instantly and the
  compact mode has its summaries.
- **Running while collapsed** (`keepsRunningWhenCollapsed`): Clipboard while its capture is not suspended (the
  history must not have holes); Player while its tab and its ears are on; Quick Settings while a caffeine is
  active or the automatic switch is on; Timer while a timer counts, is paused, or shows its "Done" ears; Agenda while
  Calendar access is granted and its ears are on (see "Agenda" below).
- **Views** are built on demand (shown tab, compact mode, settings) and thrown away: state that must survive a
  tab switch lives in the module (`@Published`). Content width and maximum height come from the environment
  (`\.notchContentWidth`, `\.notchContentMaxHeight`): the whole panel must stay under 460 pt.
- **Registry**: order and activation come from `Preferences` (`tabOrder`, `tabEnabled`); unknown ids are ignored,
  a new module appears at the end, enabled if `isEnabledByDefault`. The Claude tab can be disabled like the others
  (see "Claude Code is optional" below).
- **Tab bar**: icons in the header row, below the menu bar band, at a fixed width: the active tab is marked by a
  capsule that slides (`matchedGeometryEffect`) and its title is shown beside the bar, so no tab shifts under the
  pointer. Click, or hover for 0.2 s (passing over a tab does not switch). The panel opens on the last tab or the
  default one (settings), except when Claude needs the user and the Claude tab is on: then on Claude (or on Codex when only Codex waits for an
  approval and its tab is on). A tab that
  is no longer enabled falls back to the first enabled one.
  - **Edit mode** (`NotchViewModel.isEditingTabs`, rules in `TabEditing`, pure): a 0.5 s long press on the bar (or
    the "Edit Tabs" accessibility action). Icons wiggle, can be dragged (the others move aside with the spring),
    "−" hides a tab (never the last one shown), "+" after the last tab lists the hidden ones and puts the chosen one
    back at the end. Same storage as Settings › Tabs (`ModuleRegistry.moveTab`, `hideTab`, `showTab` write
    `tabs.order` and `tabs.enabled`, read from `Preferences` so two gestures in one run loop never use a stale
    order): both stay in sync live and a hidden tab stops its module. A move keeps hidden tabs in their slots.
  - While it lasts: hover does not switch tabs, the panel does not collapse when the mouse leaves, the tab content
    is dimmed and takes no clicks, "Done" replaces the title, accessory and "…" menu. The panel takes the keyboard
    so Esc works, and gives it back on exit unless it was opened with the shortcut. Exits: Done, a click outside
    the bar (in the panel: a background tap; outside the panel: `NotchController.mouseDown`, which then only leaves
    the mode), Esc (`handleKey`), the panel collapsing (`isExpanded` didSet), compact full screen.
  - No tab moves under the pointer outside a drag: every tab keeps its width (`LayoutTests`), "−" sits on the icon
    and "+" comes after the last tab. One view per tab in both modes.
  - **Wiggle** (`WiggleIcon`): a Core Animation rotation of the icon placed in its own `NSHostingView`, which lets
    clicks through to the SwiftUI gestures (`hitTest` returns nil). A repeating SwiftUI animation took a full core
    while editing (measured, `TabEditingGestureTests.testEditModeCPU`); now ~3 % in debug while editing and 0 %
    after the exit transition. Off with "Reduce motion" (fade only). The views exist only in edit mode, panel open.
  - Tests play the gestures with mouse events sent to the expanded notch in an offscreen window (long press,
    click, drag, "−", Done, click outside the bar) and render `tabs-*.png` with `ORIEL_SNAPSHOT_DIR`.
- **Ears = index tabs** (collapsed notch; Claude only while its tab is on; Codex is an ordinary module here, see
  "Codex" below). Every activity that has ears gets its own tab against the notch: Claude (waiting for you >
  working > just finished, 5 s) first, then the running modules by decreasing priority (timer 5, Codex 9 while it waits
  and 6 otherwise, agenda 6 five minutes before an appointment and 2 otherwise, player 1, caffeine −10; tab order breaks ties). The first goes on the left against the notch, the second
  on the right against it, then each side one step further (`EarTabs.distribute`, pure): at most three per side, and with
  more than six the sixth place becomes "+N" (the activities left out). "Show the ears" off: the collapsed notch is exactly
  the notch. Module ears also keep the notch window on screen. This replaced the 1.2.2 rotation (Claude and the other
  ears took turns every 4 s, with its `Timer`, `EarsRotation` and `appearance.alternateEars`): it was a misreading of
  "index tabs", which are side by side, not one after another.
  - **Geometry** (`EarTabsGeometryTests`, measured on the rendered silhouette against the physical notch): the collapsed
    shape on a real notch has no top flares (`topRadius` 0), so it is exactly `notchRect` (185 × 32 pt on the 14" built-in
    display: screen width − the two auxiliary areas) and `contentSize` equals the notch; the 6 pt flares are kept only on
    the virtual notch and once expanded. Every tab, at every rank, has exactly the notch's height (same top, same bottom, a
    continuous base: no staircase, no vertical offset, at rest or deployed; the stack overlaps horizontally only), the
    `overlap` of rank 0 runs down to the notch's bottom so no gap is left in the notch's rounded bottom corners, and the
    deployed card's inner corner radius never starts above that bottom (`EarTabsLayout.cardInnerRadius`). The rendered base
    is measured across the whole fan (`testFanBaseIsContinuousAndFlushWithTheNotch`): covered at the notch's bottom,
    nothing under it (so no drop shadow at rest: the shadow of the covering tab is a gradient inside the slice).
  - **Outer edge = the notch's outline** (`EarTabsGeometryTests`: path elements identical to `NotchShape`, rendered
    profile compared line by line, no gap between slices). Each tab's outer side is drawn with the very curves of
    `NotchShape` (quadratic, control point in the corner) and the radii it takes collapsed, shared as constants
    (`NotchShape.collapsedTopRadius` 6 pt: concave flare that joins the top of the screen and sticks out of the slice;
    `collapsedBottomRadius` 9 pt: bottom corner), also on an 8 pt sliver (the corner then ends under the neighbour).
    Measured on the hardware notch of the 14" (photo, curve fit): bottom corner ≈ 8 pt, top flare ≈ 4.4 pt, both
    quadratic; 2.0.0 had a 6 pt corner and a sharp top corner, hence the odd join. Unfolded: same flare, 14 pt corner
    (`EarTabs.cardRadius`), and where the card drops under the notch (or under the tab before it) the concave corner
    is rounded by a fillet of the flare's radius (`EarTabShape`), never a sharp angle. The flare and fillet are drawn
    only: hit zones are the bodies. The light edge (`EarTabEdge`) is the exact outline, clipped by the shape.
  - **Look** (`EarTabViews.swift`): a fan, like cards spread on a table. Each tab is its own shape
    drawn in the notch's black and as tall as the notch, with a discreet accent per activity
    (`EarTabs.accentHex`: Claude takes the accent of the settings). Rank 0 (against the notch) is on top; the body of every other tab slides under the
    previous one (`EarTabs.overlap`) and only its **slice** shows (`EarTabsLayout.Item.width`, see `EarTabs.slice(of:rank:mode:)`;
    `frame` is the slice, `bodyFrame` the whole tab). Stacking is `zIndex(-rank)`; a thin light edge (`EarTabEdge`), a soft
    shadow and a slight lightening per rank make the overlap readable (rank 0 keeps the notch's pure black). Setting
    `appearance.earTabs` (`EarTabsMode`): **visible** (default, the half-closed fan: rank 0 shows icon and a very short
    text, `4:59`, `1·6`, equalizer bars; the others a regular 28 pt slice with their icon only) or **retracted** (the tight
    fan, an 8 pt sliver per tab, for a quiet notch). An alert (Claude waiting, Codex waiting for an approval:
    `ModuleEars.alert`) stays open, at any rank, in both. The old "Alternate Claude and the other ears" setting migrates once (`Preferences.migratedEarTabs`):
    on or never set → visible, off → retracted; the old key is removed.
  - **Hover and click** (`EarTabsLayout`, pure; `NotchController.collapsedHit`): the window ignores the mouse while
    collapsed, so the controller decides from mouse events. The zones are the real shapes (rounded corner included), in
    one coordinate system shared with the view (origin at the top centre of the notch): the notch centre (panel opens as
    before, with the same 2 pt margin under the band), each tab, and the deployed tab. `hit` goes from the top of the stack
    down (rank 0 first) and takes the first body that contains the point, so the rounded corner of a tab shows the tab
    below it, and the zones never overlap: a tab does not open the panel and the centre does not unfold a tab. A tab
    unfolds after 0.12 s of hover (crossing the menu bar unfolds nothing) and folds 0.2 s after the mouse leaves, or at once
    when it reaches the notch centre. Unfolded, it opens from its own slice: its inner edge (where the tab above it ends)
    does not move, it grows outwards and downwards over the tabs further out and keeps its rank in the stack, so the tabs
    closer to the notch are never covered. Its zone always contains the one it had at rest and no other point changes
    target (`EarTabsFanTests.testOpeningATabOnlyGrowsItsOwnZone`): nothing slides under a still pointer (the 1.2.1 tab bar
    lesson). To reach a tab hidden under an open one, leave it and come back. The card shows the module's `makeTabDetailView()` (default: its compact
    summary, so Claude lists its sessions and their state, the timer its clock and a pause button; the player has its own:
    artwork, title, previous / play-pause / next). Its height is measured by the view and handed to the controller
    (`NotchViewModel.tabCardHeight`) so the zone follows the real size. Click on a tab (unfolded or not): the panel opens
    on its tab (`NotchActions.openTab`); a button inside keeps its own click.
  - **Cost**: nothing runs at rest (no timer: the rotation one is gone; the hover work items exist only while the mouse
    is over a tab). While a tab is unfolded the window takes the mouse (its buttons need it) and the 15 Hz mouse poll of
    the open panel runs too, then both stop. The equalizer bars and the Claude spinner are Core Animation as before.
  - `/state` lists the tabs (`notch.earTabs`: ids left and right from the notch outwards, the mode, the unfolded one).
- **Full screen**: detected on events only (Space change, plus 0.4 s later, app activation, screen change): a
  layer-0 window of the front app covers the notch's whole screen, menu bar included (a zoomed window does not).
  Window bounds need no screen-recording permission. Setting: compact (270 pt, no tabs, each module's compact
  summary; Claude shows its running sessions, state and one line each), normal, or hidden (the notch leaves the
  screen until the app leaves full screen). The collapsed ears do not change.
- **Settings** (`Preferences`): one `@Published` property per setting, stored in UserDefaults under a namespaced
  key (`hover.openDelay`, `tabs.order`, `appearance.accent`…), read back clamped. A module stores its own
  settings under `<id>.<name>`. The accent color is read through `Palette.accent`; the notch view is rebuilt
  when it changes. "Reply from the notch" (`claude.replyFromNotch`, off by default): off, the reply hooks get
  an immediate "no decision".
- **Messages and Mail**: optional tabs for everyone, off by default, no permission before the
  tab is opened. They only run collapsed (`keepsRunningWhenCollapsed`) once a first read worked (`<id>.armed`):
  Messages listens to FSEvents on `chat.db` / `chat.db-wal` (no timer), Mail polls a counter script every 2 minutes
  only while Mail runs and never launches it (`application id … is not running` guard, checked). Message text and
  AppleScript arguments never go through string interpolation. A Mail reply leaves only through
  `MailModule.sendReply()` (click on Send or Return in the field), never on open, refresh or close. Under XCTest the default accesses are inert
  (`ModuleEnvironment.isTesting`): tests never read real messages or run `osascript` (except the closed-Mail guard).
- **Command bar** (`Command/`, opened by `keyboard.commandBar` or **…** › **Command Bar…**, `NotchViewModel.isCommandBarOpen`):
  it replaces the panel's content while it is open (`NotchRootView`), takes the keyboard like a text field
  (`NotchKeyboard`) and closes together with the panel (Esc, a command run, the shortcut again: `closeCommandBar` =
  `collapse`). The commands come from the modules, not from a list in the bar: a module (or the local API: both are a `CommandSource`) declares one `commandVerb` (a
  letter or `>`, never translated) and answers `commands(for: CommandQuery)` with `NotchCommand`s (id, symbol, title,
  detail, score, `run`). Rules: `commands(for:)` is pure and `run` only executes on Return or a click on the row
  (`CommandBarTests.testNothingRunsBeforeReturn`); `run` returns a failure message instead of closing the bar when the
  action did not happen (Claude's full queue); the bar asks `registry.commandSources` (the modules enabled **and**
  running, then the scripts' tabs), so a search never starts a stopped or hidden module; with a verb typed only that module is asked, without one every module
  is asked and answers only what is unambiguous (a duration with its unit, a scene, an email or an event with 3+ letters),
  the clipboard and the scripts' tabs never; at most five rows (the panel stays under 460 pt: `CommandBarSnapshotTests.testFullBarFitsInPanel`). The grammar
  is one-key verbs shown under the field (`t` timer, `n` note, `c` clipboard, `s` scene or fans back to macOS, `m` latest
  emails, `a` agenda, `i` scripts' tabs, `>` Claude; keys only when the names do not fit), no natural language; a letter is a verb only before a
  space, so plain text stays plain. Typed, the verb leaves the field and becomes a pill; Backspace on an empty field
  brings it back. Ranking: score, then tab order, then the module's own order; `FuzzyMatch` is case and accent blind,
  every word must match, a word matches by inclusion (best at the start of the text or of a word) or, in a text of 64
  characters or less, by letters that follow closely. A module's commands live in its folder (`TimerCommands`,
  `NotesCommands`, `ClipboardCommands`, `QuickSettingsCommands`, `ClaudeCommands`, `MailCommands`, `AgendaCommands`,
  and `LocalAPICommands` for the scripts' tabs); an email opens in Mail (never a reply), a meeting is joined through
  `AgendaModule.join` (same link check as its button); texts are in the `Command` table.
  The Claude verb exists only with "Reply from the notch" on, and sends through `ReplyCenter.send` like the chat
  field. VoiceOver: the field is labelled, rows are buttons with title and detail, the chips say their key, and the
  results count and the selected row are announced because the focus stays in the field (`announcementRequested`;
  checked by the code only, not with a running VoiceOver).
- **Localization per table**: `L("…", table: "Media")` or `Text("…", tableName: "Media")`; without a table,
  `Localizable`. `LocalizationTests` checks every table: each key used in the code is translated in its table, no
  unused keys, French identity, same format specifiers, same tables in `en.lproj` and `fr.lproj`.

## Decisions worth keeping

- **Claude Code is optional**: the notch is for everyone (player, calendar, quick settings, shelf, clipboard,
  timer, notes); the Claude Code integration (Claude tab, hooks, replies) is an option, never imposed. 1.2.0 got
  this wrong (visibility "when Claude is open", Claude tab that could not be disabled, hooks pushed at every
  launch); 1.2.1 fixed it.
  - **Detection** (`HookInstaller.claudeCodePresent`): `~/.claude` or `$CLAUDE_CONFIG_DIR` is a folder. Hooks
    already installed by Oriel live in `~/.claude`, so they count. Never real under XCTest
    (`claudeCodeOnThisMac` checks `NSClassFromString("XCTestCase")`).
  - **Decided once** (`Preferences.decideClaudeTab`, `AppCore.start`): at the first launch of 1.2.1 or later, the
    Claude tab is enabled only if Claude Code is detected, and the result is saved in `tabs.enabled`. It never
    changes on its own afterwards (installing Claude Code later does not turn the tab on: Settings › Tabs does).
  - **Tab off** (applied live by `AppCore.setClaudeTracking`, from `ModuleRegistry.enabled`): `ClaudeMonitor`
    stopped (no 2 s process scan, no Claude Desktop observers), `SessionStore` stopped (sessions forgotten, no
    timer, no transcript read), held replies given back to the terminal. `HookServer.isPaused`: the port stays open
    (zero cost at rest) but `/hook` answers 204 without walking the processes and `/permission` and `/inbox` answer
    204 at once (fail-open). No Claude ears, no switch to the Claude tab, default tab = first enabled one, no
    session or hook items in the **…** menu ("Uninstall" stays, without hook wording when none are installed).
    Back on: everything restarts; open sessions show up at their next event.
  - **First launch** (`HookSetup.launchWindow`, `onboarding.welcomeShown`): the setup assistant, once. Not shown
    after an update from a version that had installed the hooks. Four steps (`SetupAssistantModel.Step`): welcome,
    tabs, behavior, done. The choices are plain data (`SetupChoices`, pure, tested without a window): the tabs
    offered are all of them except Claude when Claude Code is not detected (unless its tab is already on, which
    matters when the assistant is run again), at least one stays ticked, and `apply` writes `tabs.enabled` through
    `ModuleRegistry.setEnabled` (same storage as Settings › Tabs) plus `hover.trigger` and `keyboard.togglePanel`.
    Nothing is written before "Apply" (the last step before "Done"); "Skip" or closing the window changes
    nothing. "Open at login" and the hooks are closures given by `HookSetup` (`applyLaunchAtLogin`, `installHooks`),
    so the tests never touch the Mac. The hooks are an unticked checkbox under the Claude card (ticked by default
    only for an update of hooks that were already installed) and are written at "Apply", the result shown on the
    last step. `~/.claude` is read only if the Claude card is offered. No macOS permission is requested. Run again
    from Settings › General (`HookSetup.showSetupAssistant`, `firstRun: false`): it starts from the current
    settings. `OnboardingView` keeps only the hook window (install, update).
  - **Profiles** (`Profiles.swift`, `ProfileViews.swift`): several ways to start in ONE app (one
    update, one signature). `NotchProfile` (developer, student, creative, minimal) is pure data: tab IDs in order
    (an ID the app does not have yet, like `codex`, is ignored), opening mode, ears. `ProfilePlan` computes what a
    profile shows and hides and writes only `tabs.enabled` (through `ModuleRegistry.setEnabled`), `tabs.order`,
    `hover.trigger` and `appearance.showEars`: never a tab's data, the hooks, visibility, look or shortcuts (tested
    on the keys of the defaults). Claude and Codex (`NotchProfile.agentTabs`) are offered only if detected or
    already on. First step of the setup assistant: `SetupChoices.choose` ticks the profile's tabs, its order and
    ears are written with the rest at "Apply". Settings › General › Change Profile… (`ProfileWindow`, same window
    style as the assistant) previews the plan and applies it on confirmation; the current profile is
    `NotchProfile.matching`, from the enabled tabs only (order ignored), else "Custom". Texts: table `Profiles`.
    To add a tab to a profile: one ID in `NotchProfile.tabs`.
- **Facts measured on Claude Code 2.1.29x**: `PermissionRequest` carries no `tool_use_id` (it is matched to the
  last active tool with the same name); internal agents send `SubagentStop` with an empty `agent_type`
  (ignored); a background agent's result comes back as a `UserPromptSubmit` starting with
  `<task-notification>`; the hook's `$PPID` is the claude process; the native CLI process is named after its
  version (e.g. `2.1.296`) and is recognised by its path.
- **Reply from the notch, facts measured on Claude Code 2.1.304** (spike of 50 sessions, then replayed against
  the real server and script):
  - `PermissionRequest` hook run synchronously (timeout 600, **no `onFailure`**: a failure is fail-open, even
    exit 2 does not deny): the terminal dialog is shown at the same time and stays usable; the first answer
    wins. "No" in the terminal sends SIGTERM to the hook; "Yes" runs the tool and the hook's late answer is
    ignored. Parallel tool calls ask one permission at a time.
  - Output: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, or
    `deny` with a `message` that becomes the tool result (Claude goes on).
  - AskUserQuestion is answered through the same hook (not PreToolUse, which hides the question in the
    terminal): `allow` + `updatedInput` = original `tool_input` + `answers` {exact question text: label};
    multiple choice = labels joined by ", "; free text accepted.
  - ExitPlanMode: `allow` alone is **ignored**; approval = `allow` + `updatedInput` (original input) +
    `updatedPermissions` `[{"type":"setMode","mode":"acceptEdits","destination":"session"}]`; `deny` +
    `message` = keep planning.
  - Free message: `SessionStart` and `Stop` hooks with `asyncRewake: true` (timeout 86400) long-poll the app; the
    message goes to stderr with exit 2 and Claude starts a turn (~3 s); during a turn it is read after the
    current tool. It comes back as a `UserPromptSubmit` `<task-notification>` with our `rewakeSummary`.
  - Without a terminal (`-p`/`--print`, or `--input-format`/`--output-format` as passed by the SDK and the Code
    tab of Claude Desktop, without `-p`), Claude **waits for the `asyncRewake` hooks** before reading the prompt
    (`claude -p` never answered with a held waiter). `ReplyCenter.wait` reads the argv of `X-Claude-PPID`
    (`KERN_PROCARGS2`) and answers 204 at once; such sessions are listed in `headless` and the conversation offers
    "Answer in *app*" + **Open** instead of a field. Checked with the real `claude -p` and stream-json against the
    real server: about 5 s, as without the hooks.
- **Claude Desktop (Code tab), facts measured on Claude Code 2.1.304** (a real `claude` started with the Code tab's
  flags: stream-json in and out, `--permission-prompt-tool=stdio`, then the same hook script against a test
  server; spikes kept out of the repository):
  - `PermissionRequest` is called, alongside Desktop's own `can_use_tool` request. A decision from the hook runs
    the tool and Desktop gets a `control_cancel_request` for its dialog; when Desktop answers first, the tool
    runs at once and the late hook answer is ignored. In `bypassPermissions` mode Bash raises no
    `PermissionRequest` (nothing to allow) but AskUserQuestion still does: `allow` + `updatedInput.answers` is
    applied (`tool_result`: "Your questions have been answered…").
  - `Stop` carries `last_assistant_message` (~30 ms after the `result` line); a woken turn comes back as a
    `UserPromptSubmit` `<task-notification>` then a `Stop`.
  - `asyncRewake` held on `Stop` blocks neither the `result` nor the next prompt, and its exit 2 starts a turn
    ~3 s later when Claude is idle, or is read right after the running tool (`<task-notification>` at the end of a
    25 s Bash call). Held on `SessionStart` it delays the first prompt by the whole wait (21 s for a 20 s hold):
    never held there. Closing: SIGTERM exits at once; closing stdin makes Claude wait for the held hooks, then
    give up after ~30 s (SessionEnd fires only then).
  - Hence `ReplyCenter.wait(desktop:atStop:)`: the script sends `X-Host-Session-Id` (`CLAUDE_CODE_HOST_SESSION_ID`,
    `local_…`); a headless session with that ID, without `-p`, is held at `Stop` only. Any other headless session
    (SDK, IDE, `-p`, an old script without the header) keeps the 204 and gets "Answer in *app*". End to end with
    the real server, script and `claude`: waiter held at `Stop`, message delivered, answer ~3 s later.
  - Not checked: ExitPlanMode with Desktop, and how the Desktop window displays a turn started by a hook.
  - **Held waiter lost at an app restart** (found with 1.5.0 on real Desktop sessions: a message to an idle session
    stayed queued, `waiting` 0, no `inbox` process). Not a Desktop limit: a `claude` started with the real Code-tab
    flags and the installed hooks, against the real app, keeps the `Stop` hook alive while idle and during the next
    turn (`ps`), and `ReplyCenter.wait` holds the argv of every real Desktop session of the machine. What happens:
    when the app quits (update, relaunch, crash) the connection of every held hook drops, the script exits 0, and
    Claude does not start it again before the next `Stop`. A session idle since before the relaunch has no waiter
    until then. Fix: in `inbox` mode the script retries when the connection was cut (curl 52/56), every second, until
    the app is back (`ORIEL_RETRY`, 30 s by default; 7/22/28 while it is not up or has not rewritten its
    token), then holds again; it gives up (exit 0) after the delay or when its parent is gone. `permission` is never
    retried. Hooks started by an older script keep the old behaviour until their next `Stop`. `HookServer.stop()`
    now closes the open connections like a quit does (tests). `/state` shows `replyChannel` per session
    (`waiting`, `queued`, `headless`, `none`).
- **CLI, same version** (interactive `claude` in a pty): `PermissionRequest` is called for Bash and AskUserQuestion,
  the terminal dialog stays up ("Allowed by PermissionRequest hook" when the hook answers first).
- **Quota gauges** (`Modules/Quota/`, `ClaudeUsage`, `StatusLineRelay`, `CodexUsage`; docs in README › Quota gauges). One ring per window (5 h, 7 d), amber from 80 %, red from 95 %, under the session list of the Claude and
  Codex tabs and in their compact summary (so also in the unfolded index tab and the full screen summary, where the strip drops
  the reset times when too narrow and carries the agent's name). Nothing when the tab is off or there is no figure; no ear.
  - **Claude**: the only source is the `statusLine` JSON (`rate_limits.five_hour` / `seven_day`: `used_percentage`,
    `resets_at` in epoch seconds; absent without Pro or Max and before the first answer of a session; hooks do not carry it).
    Measured on Claude Code 2.1.304 by running one short real session with a capture script as `statusLine`: the first call has
    no `rate_limits`, the one after the first answer has both windows. Claude Code allows ONE `statusLine` command, so
    `StatusLineInstaller` (Settings › Claude › Show quota, off by default) swaps the `command` for `hooks/oriel-statusline.sh`
    in place (other keys such as `padding` and the key order stay, timestamped backup, `HookInstaller.loadSettings` / `save`),
    keeps the old command in `oriel-statusline.previous` (0600, next to the script) and the script runs it again with
    the same JSON (`sh -c`, as Claude Code does). Not a plain command (`type` other than `command`, no `command`): refused,
    nothing touched. Uninstall (the switch, or Uninstall Oriel) puts the exact old command back; a `statusLine` the user
    changed since is left alone. The script POSTs to `/claude/status` only when the JSON has `rate_limits`, never fails the
    status line (`curl` 1 s at most, app closed = nothing), and `ClaudeUsage.parse` keeps only the percentages and reset times,
    in memory. `HookServer.isPaused` (Claude tab off) answers 204 without reading. The figure is the account's, so the last one
    received from any session is the one shown; windows past `resets_at` are dropped, like Claude Code does.
    The Code tab of the Claude app never runs the `statusLine`, so no figure from it. Ruled out (measured 2026-10-24):
    reading `GET api.anthropic.com/api/oauth/usage` with the OAuth token of the `Claude Code-credentials` keychain item.
    Only the `claude` CLI renews that token (it had expired for 3 days while working in the app only), the app's Code tab
    has its own authentication, and Oriel must never refresh it itself (that would rotate the refresh token and sign
    Claude Code out).
  - **Codex**: `CodexAppServer.rateLimits()` (`account/rateLimits/read`, one process of about 1 s). `CodexUsageStore` reads only
    between `CodexModule.start()` and `stop()` (panel open): cache of 60 s, one 5-minute timer, an error keeps the last figure and
    waits 15 min, `forget()` (tab or setting off) discards a read still in flight. The intercalaire hides a figure older than 15 min.
  - Tests: `QuotaTests` (both parsers, store with a double, installer, real relay script against the real server) and
    `QuotaSnapshotTests` (PNG). `StatusLineInstaller.standard` points at a missing folder under XCTest: a test never touches the
    real `~/.claude`.
- **Codex** (measured on Codex CLI 0.154): the tab follows Codex through its own
  hooks (`~/.codex/hooks.json`), never `notify` or `config.toml`, never the compressed rollout files.
  - **Same optional rules as Claude**: `CodexHookInstaller.codexPresent` (`~/.codex`, `$CODEX_HOME`, `Codex.app`, a
    `codex` command), never real under XCTest; `Preferences.decideCodexTab` decides once at launch (enabled only if
    Codex is found); `isEnabledByDefault` is false; the setup assistant offers the card only when detected or already
    on. Tab off (`AppCore.setCodexTracking`): `HookServer.isCodexPaused` (the `/codex/*` routes answer 204 without
    inspecting a process), `CodexStore` stopped (sessions forgotten, watchers and timer cancelled), held approvals given
    back. The module runs while collapsed only while something happens (`keepsRunningWhenCollapsed` =
    `store.hasActivity`), so its ears get their own index tab (priority 9 waiting, as an alert that stays deployed, 6 working or done).
  - **Hooks**: one async relay per event (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
    `Interrupt`, `SessionEnd`; the last two are capped at 3 s by Codex) and the synchronous `PermissionRequest` entry
    (`codex-notch-hook.sh permission`, timeout 75 s). Same token, proof and `Host`/`Origin` rules as Claude's hooks
    (routes `/codex/hook`, `/codex/permission`; the header is `X-Codex-PPID`). The hook's `$PPID` is the `codex`
    process (CLI or the app's engine): `CodexProcess` walks up for the host app, `CodexStore` watches the pid.
  - **Trust**: Codex skips a hook that the user has not reviewed (`/hooks`), recorded as
    `hooks.state."<file>:<event>:<group>:<hook>".trusted_hash` in `config.toml`. We never write it. `config.toml` is only
    read (`ConfigNotes`: hooks off, inline hooks, `notify` present, reviewed) and is never modified.
  - **Approvals**: Codex runs `PermissionRequest` *before* its own prompt and the prompt waits for it (measured: a 6 s hook
    delayed the prompt by 6 s), unlike Claude Code. So `CodexApprovals` holds 4 s if the card was never shown, 60 s once
    it was (`engagedDelay`, under the 75 s hook timeout), then answers "no decision"; "In the terminal" gives the hand
    back at once. Output: `hookSpecificOutput.decision.behavior` `allow` or `deny` + `message`, nothing else. A decision
    only exists as the answer to a hook's request, after a click; no "always allow". `codex exec` forces
    `approval: never` and never fires the hook.
  - **Not possible**: a free message to a running session (a held `Stop` hook would freeze the terminal; `codex queue`
    needs the experimental shared daemon), and Codex's own questions (no hook).
- **Reply design**: one long connection per request; the app answers on the first of: the user's decision; the
  `PostToolUse` (same tool and input), `Stop`, `UserPromptSubmit` or `SessionEnd` of the session; the connection
  closing; the deadline (4 s if the card was never on screen, 590 s once it was, under the hook's 600 s). No
  decision = 204. One waiter per session (a new one closes the old with 204), FIFO queue (10 messages), waiters
  closed when their claude PID exits (kqueue `DispatchSourceProcess`, no polling). No route lets a client
  decide: a decision only exists as the answer to a hook's request, after a click. Never "always allow".
- **Conversation and the "turn on" card** (Claude tab): the "Chat" button opens `ConversationView` under the card
  (the list then takes the whole panel height and scrolls to it). Replies off, the conversation still shows what
  was said and offers to turn them on. The card at the top of the tab (`ReplyPromptCard`) shows while replies are
  off, not dismissed (`claude.replyPromptDismissed`) and the tools pane is closed (open, it would push the panel
  past 460 pt, measured). "Turn On" sets the setting and applies `HookSetup.repairNeeded`: nothing, a silent
  update, or the install window (the choice stays with the user). Nothing is decided without a click.
- **Hook token**: 32 hex, new at each launch, written (0600, `O_EXCL` + `rename`) only once the listener is
  ready, so a second instance that cannot bind never overwrites it. The script passes it with `curl -H @file`
  (never in argv) and `-q --noproxy '*'` (no `~/.curlrc`, no proxy). `permission` and `inbox` modes run curl
  in the background and trap TERM to kill it: the app sees the connection close.
- **Proof of the app**: the token authenticates the script to the app, not the other way round. A second
  secret (`hook-proof`, 0600, written before the token, never sent by the script) comes back in the
  `X-Oriel-Proof` header of a 200 from `/permission` or `/inbox`, only to an authenticated request. The
  script compares it with shell builtins (never in argv) and ignores any answer without it: a program bound to
  the port while the app is closed (any account can bind 47823) gets the request but decides nothing. While
  the app runs, nobody else can bind the port (checked, even with `SO_REUSEPORT`).
- **Approve with the keyboard** (`ApprovalQueue`, `claude.approveByKeyboard`, off by default): ⌃⌥Y allows, ⌃⌥N denies the
  oldest keyable request of both agents (`ApprovalSource.claude` / `.codex`: tool permissions only; questions and plans
  need a choice or a text and stay with the mouse). Carbon `RegisterEventHotKey` again (no Accessibility), through the
  `HotKeyRegistering` protocol so tests use a double. Why this shape: a reflex must not allow a command nobody read.
  - The combinations are registered only while the queue is not empty (and the setting is on), then released: nothing is
    reserved the rest of the time. A combination macOS refuses (`approveLive`/`denyLive`) shows no key cap.
  - A key decides only if the **head** card is on screen (`cardAppeared`/`cardDisappeared` from the cards' `onAppear`/
    `onDisappear`; the panel content is removed when it collapses, and only the selected tab is in the tree) and has been
    for `guardDelay` (1 s) *since it became the head while visible* (`armed`). Otherwise the first press only calls
    `reveal(tab)` (`NotchController.revealApproval`: opens the panel on that tab or switches tab, `openedByKeyboard` so
    it stays up, no `NotchKeyboard.take()`: the typing in the front app is not captured). It decides nothing.
  - One at a time: `armed` is cleared before `decide`, and the next head re-arms from the moment it becomes the head,
    even if its card was already visible. A head settled elsewhere between two presses does the same: a press aimed at
    the old card never settles the new one. Decisions go through `ClaudeModule.decide` / `CodexModule.decide`, the same
    as a click (`.deny("")` = the default message, `Decision.deny` for Codex): deadlines, "first answer wins" and the
    output format are unchanged; still no "always allow".
  - Not done: the automatic drawer of the idea (the notch opening by itself on a request) and the "smart suppress" when
    the session's terminal is in front; both touch `NotchViews`/`NotchController` more and are left for later.
  - Known limits: a card scrolled out of a long list still counts as on screen; tab editing mode (cards dimmed) too.
- **Notch keyboard**: the panel never activates the app; it becomes key only for a text field
  (`NotchKeyboard.take`) and gives the keyboard back with `orderOut` + `orderFrontRegardless` when the field
  closes or the panel collapses, otherwise the next keystrokes would be swallowed by the hidden panel.
- **Esc**: no hook fires. During a turn the transcript is read every second; only a `type: user` line whose
  text starts with `[Request interrupted by user` counts, not a mere quotation of that text.
- **~0 % CPU when collapsed**: no fast timer and no file reads while the panel is collapsed. The spinner and the
  pulsing hand are Core Animation animations (`AnimatedGlyphView`); a SwiftUI `TimelineView` re-ran the whole
  hosting view layout on every frame (~10 % CPU). Modules are stopped while collapsed unless they ask; the 1 s
  session timer only runs while there are sessions; the root view does not observe `ClaudeMonitor` (it changes
  on every app switch), only the Claude tab does.
- **Notch settings** (Settings › General and Appearance, `NotchShell`):
  - Visibility `visibility.mode`: always (the default for everyone, no key needed; the old `alwaysVisible = false`
    becomes "when Claude is open"), when Claude is open, during activity. With the Claude tab off, "when Claude is
    open" is not offered (Settings › General, **…** menu) and acts as always; "during activity" only counts module
    ears. One-time repair (`visibility.defaultFixed121`, set at the first launch of 1.2.1): 1.2.0 saved "when Claude
    is open" on its own for people who had the hooks, so that value without the old `alwaysVisible` key goes back
    to always, once. Trade-off: someone who picked it on purpose during 1.2.0 gets always once. Module ears show it
    in every mode. "Hide the notch" for 1 h, until 8 am tomorrow or until turned back on (`visibility.hiddenUntil`, `distantFuture`): one `Timer` at the
    end date, only while hidden, re-read on wake. "Until turned back on" ends when the app is opened again
    (reopen event) or relaunched; reopening the app also opens the settings (no Dock or menu bar icon).
  - Screen `display.screen`: built-in (with the notch), main, under the mouse (follows it while collapsed, on
    mouse events only) or a screen by name (identical models are numbered). Without a notch, a 200 pt virtual
    notch is drawn at the top center, as high as that screen's menu bar.
  - Global shortcuts (`keyboard.*`, a short list, never the same one twice): Carbon `RegisterEventHotKey`, no
    Accessibility permission; a combination macOS refuses is reported in the settings. Opened with the shortcut,
    the panel takes the keyboard (`NotchKeyboard.take`) and stays open when the mouse leaves: ← → and ⌘1…9
    switch tabs (not in compact full screen), Esc closes and gives the keyboard back, and so does a click
    outside or the shortcut again.
  - The window is 800 × 480 pt so the widest custom panel (720 pt), its radii and shadow fit. A light custom
    background is darkened (relative luminance ≤ 0.06): the panel is always dark-themed, its text white.
  - "Invisible in screenshots" sets `sharingType = .none`; it does not touch the window level.
- **Detached notch (bubble)** (`Bubble*.swift`, `NotchViewModel.bubble`, settings `bubble.*`):
  - **Phases** (`BubblePhase`, pure): attached → detaching (drag from the corner) → bubble ⇄ bubble panel → reattaching →
    attached; `reset` goes straight back (setting turned off). While detached the notch never expands: hover and click on
    the notch do nothing, an index tab opens the bubble panel on its tab, the global shortcut toggles the bubble panel,
    the command bar opens inside the bubble panel (and closes with it, or at reattach), a keyboard approval opens its
    card there (`revealApproval`), `collapse()` (open a session, settings…) closes it. A file dragged to the notch does not open the Shelf then.
  - **Handle**: an arc and a dot in the bottom right corner of the expanded panel (not in compact full screen nor in tab
    edit mode). A 3 pt drag or a 0.3 s long press (SwiftUI) starts the drag (the long press alone failed as soon as the
    mouse moved before 0.3 s, and nothing happened). Hovering the corner shows "Drag the corner to detach the notch"
    right away (the tooltip takes a second), and so do the first three panel openings, for 3.5 s
    (`Preferences.takeHandleHint`; never again once the gesture is found); the drags and the mouse-up then come from a local event
    monitor (they go to the window of the mouse-down, even outside it) that is removed at the mouse-up. Menu, right
    click and VoiceOver detach without dragging (`detachAutomatically`).
  - **Drop** ("gooey" metaballs): a separate window under the notch, a `Canvas` with `blur` then `alphaThreshold`
    (macOS 12+, no shader). Shapes are pure functions of the progress or the elapsed time (`Goo`, `GooState`): body (the
    panel shrinking halfway towards the notch), a neck drawn as a band (circles alone break into beads once thin) pinched
    in the middle down to 5.5 pt (`neckFloor`: thinner, the threshold erases it), and the drop. At 120 pt
    (`detachDistance`) it snaps: the body springs back into the notch, the bubble window takes the drop's place at the
    same size (scale 0.72) and springs to 1 (damping 0.7), and the same drag keeps moving it. Released earlier, the drop
    goes back. The notch view fades out while the drop replaces it (`gooActive`). `TimelineView(.animation)` only exists
    while a drop is animated (`.rest` draws a still image); afterwards `goo = nil` and the window is ordered out.
    "Reduce motion": no drop, a half-transparent bubble follows the mouse, then a fade.
  - **Detach frame budget** (measured offscreen by `BubbleFrameBenchTests`, main thread, release; the drawing itself,
    blur included, is RenderBox's work on the GPU: SwiftUI views are `RBDrawingLayer`s): the drop costs 0.4 ms a
    frame. The snap used to do everything in one frame: first image of the bubble window (55 ms), notch folding
    (17 ms), saved setting (5 ms), phase (1.5 ms), 79 ms in all. Now: the bubble views and the drop window are built at
    launch (`start`); the bubble window is ordered in transparent and click-through at the grab (`prepareBubble`), so
    its first image is drawn during the pull; the snap frame only flips it opaque (2 ms); the notch folds and the
    setting is saved at the mouse-up (`notchPending`, `finishDetach`), hidden under the drop resting in the notch, then
    the notch fades back in. The drop follows the mouse through `GooModel.liveDrop`, read by the timeline at each frame
    and not published: one image per screen refresh, not one more per mouse move. For three frames after the snap the
    drop stays drawn under the new bubble and follows it (`snapOverlap`): a bubble window one frame late shows nothing
    missing.
  - **Bubble window**: same level, collection behavior and "hide from capture" as the notch (`isFloatingPanel` before
    `level`), created on first detach (`defer`), clamped to the visible frames (menu bar and Dock excluded). Position
    stored per display label (`NotchScreenPicker.labels`) as an offset from the display origin, plus the last display;
    a display that disappears sends the bubble back to the notch's display. Hidden with the notch ("Hide the notch",
    full screen "hidden").
  - **Magnetic return (ferrofluid)** (`Ferro`, `FerroState`, `FerroShapes`, pure; `FerroCanvas`): like a drop rejoining
    a puddle, drawn at every frame of the drag. Within 150 pt (`reach`, gap between the bubble's edge and the notch
    bottom right above it, `Ferro.base`) the bubble is pulled toward the notch, up to 30 pt, with a strength that
    grows faster and faster as the gap shrinks (square of the closeness). The bubble window then grows once to the
    notch's field (`Ferro.fieldFrame`, notch included) and stops moving: the bubble moves inside it, and its outline
    (`RevolverBubble.outline`), the notch's cone, the bridge and the notch edge are drawn in the same view, so nothing
    lags behind. Bubble and notch reach toward each other (`reachOut`): the bubble stretches into a drop with seven
    cone-shaped spikes (sharp tips, bases tangent to the circle, on a 360-point outline whose spikes fall on points),
    the notch grows a cone (40 % of the gap) and its bottom bulges; at 70 pt (`bridgeGap`) the tips touch and a
    bridge forms (its neck grows from nothing in 0.12 s), thicker as the bubble comes closer. Pulled away, the bridge
    stretches into a thread and breaks only beyond 105 pt (`breakGap`, hysteresis: it does not flicker at the limit);
    both halves spring back (`recoil`). A bridged bubble lights its rim and is sucked in when released; within 16 pt
    (`captureGap`) it is sucked in without waiting. Aspiration (0.42 s) starts from the bridge as it is (no jump): the
    bubble accelerates into the notch, shrinks, its spikes and cylinder fade, the bridge widens into a funnel (its base
    stays within the notch's flat bottom); then a ripple runs along the notch bottom toward both corners and dies out
    (0.6 s), and the window is ordered out. Released unbridged in the field: the bubble relaxes (damped, slightly
    flattened, then round) and the window shrinks back. The bridge goes from the notch's color (black on a real notch)
    to the bubble's. "Reduce motion": a plain magnet (pulled halfway within 44 pt) and a fade. Reattach from the menu or
    a double click from far away: the bubble glides under the notch first.
  - **Revolver** (`Revolver`, pure): one chamber per enabled tab in the user's order, active tab at the top (fixed
    mark), `turn` counts detents without bounds so the spring always turns the short way. Scroll: 1 detent per wheel
    line or per 28 pt of trackpad, momentum ignored (`RevolverScroll`); circular drag on the chambers: one detent per
    angle step crossed, across ±π (`RevolverDrag`); click on a chamber turns it to the top; the hub or the top chamber
    opens. A drag elsewhere moves the bubble, a double click on the rim reattaches. Scroll wheel and right click come
    from an `NSHostingView` subclass (no scroll wheel API in SwiftUI before macOS 14). VoiceOver: one adjustable
    element (swipe up/down turns), default action opens, a named action reattaches.
  - **Bubble panel**: the same `ExpandedPanel` in a rounded shape, with a back button at the start of the tab bar
    (`NotchActions.backToRevolver`); the window grows to the panel (top at the bubble's top, clamped to the screen) and
    shrinks back after the transition. The content grows out of the top chamber (`chamberAnchor`) and folds back into
    it. Back to the cylinder (`back()`: leaves tab edit mode first): the back button, Esc when the panel has the
    keyboard, a pinch, a click outside (always, whatever "Close on click outside" says), or the mouse leaving after the
    close delay. Every phase can reach the notch again (`testEveryPhaseHasAWayOut`).
- **Shape size** is reported through `NotchSizeKey` with a `max` reduce (a plain `nextValue()` let a sibling's
  default value win, leaving the hover zone at zero). The expanded panel stays under 460 pt.
- **Window level**: `isFloatingPanel = true` must be set *before* `level`: that setter resets the level to
  `.floating` (3, measured with `CGWindowListCopyWindowInfo`, see `WindowLevelTests`). At level 3 the menu bar
  (24) and its icons were drawn above the notch and a full-screen app hid it; this is what an earlier version of
  this page described as "menu bar icons are drawn above the notch whatever its level", which was wrong. The
  panel now sits at `mainMenu + 3` (27), checked by `/state` (`level`, `windowServerLevel`), and is ordered front
  again 0.4 s after each Space change.
- **Menu bar band**: the expanded panel keeps a menu-bar-high empty band and the header sits below it: the
  middle of that band is the physical notch (nothing visible there) and, at level 27, the band covers the menu
  bar items on both sides while the panel is open. The collapsed ears also live in that band, next to the
  notch, and are drawn above the menu bar.
- **Protected folders** (Documents, Desktop, Downloads): never touched on the main thread (a macOS permission
  prompt would freeze the notch), and not at all when no companion tool is installed.
- **Companion tools** run from `JobRunner`, not launchd: macOS denies protected folders to launchd jobs, while
  processes started by the app inherit the access granted to it.
- **Installer**: byte-for-byte identical to `scripts/hooks_config.py` (tested), key order preserved,
  timestamped backup, nothing written when the JSON is invalid or nothing changes.
- **Opening a Desktop session**: `claude://code/continue?session=<local_…>`, a format read from Claude Desktop's
  `open-url` handler; the identifier is passed by the hook from `CLAUDE_CODE_HOST_SESSION_ID`.
- **Localization**: the French strings are the keys, English lives in `Resources/en.lproj`; any user-visible
  `String` goes through `L()`; `LocalizationTests` checks coverage.
- **Code signature**: release builds are signed with a self-signed certificate (CN `Claude Notch Self-Signed`,
  extended key usage `codeSigning`, 10 years; the name is kept after the rename to Oriel, it is shown nowhere), not ad hoc. The designated requirement of an ad hoc signature is
  the build's `cdhash`, which changes with every build, so macOS (TCC) sees each update as a new app and asks
  again for calendar, Bluetooth, Automation and protected folders. With the certificate the requirement is
  `identifier "<bundle id>" and certificate leaf = H"<SHA-1 of the certificate>"`, the same for every build
  signed with it, so the grants carry over from one version to the next.
  - `scripts/build.sh` signs with `codesign --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN"` when both
    variables are set (the release workflow sets them), otherwise ad hoc (local builds, `scripts/install.sh`).
    Only one of the two is an error, so a release cannot silently fall back to ad hoc. No hardened runtime: it
    would require entitlements and block code loaded by third-party processes (mediaremote-adapter, loaded by
    perl).
  - The `.p12` and its password are the repository secrets `SIGNING_CERT_P12` (base64) and
    `SIGNING_CERT_PASSWORD`. The workflow imports them into a temporary keychain (`set-key-partition-list`, so
    `codesign` never prompts), builds, runs `codesign --verify --deep --strict` and requires a `certificate leaf
    = H"…"` requirement without `cdhash`, then deletes the keychain (`if: always()`). Missing secrets fail the
    job before the tests.
  - Backup: the maintainer's login keychain, generic passwords of service
    `io.github.slybald.claudenotch.code-signing`, accounts `p12-base64` and `p12-password` (the README shows how
    to put the secrets back). The certificate is made with `openssl req -x509` (RSA 2048, `-days 3650`) and
    exported with `openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`, the
    format `security import` reads on every macOS version.
  - Never replace the certificate lightly: another one has another `H"…"`, so every user is asked for the
    accesses again. It is also what happens when it expires (10 years): `codesign` then refuses to sign and
    the release fails.
  - Consequence for users: the first release signed this way has a different requirement from the ad hoc
    versions, so macOS asks one last time for the accesses already granted; after that, never again.
  - Not a notarization: there is still no Developer ID, so macOS blocks the first launch of a downloaded copy
    (right-click › Open on macOS 13-14, Open Anyway on 15 and later, or `xattr -dr com.apple.quarantine`; steps in the README and in a text file inside the DMG).
  - Independent from the Ed25519 key above: that one protects the update download, this one gives the app a
    stable identity.
- **Update channel**: only an app built with `RELEASE_CHANNEL=1` (Info.plist key `OrielUpdateChannel =
  release`, set by the release workflow) checks for updates; local builds and `scripts/install.sh` never do.
  The signal is a GitHub release (`/releases/latest`, drafts and pre-releases ignored), not a commit.
  Checks run 60 s after launch, then every 6 h (low-frequency timers with tolerance, ~0 % CPU).
- **Signed updates**: a DMG is installed only if its Ed25519 signature (`Oriel-<v>.dmg.sig`, base64 of
  the signature of every byte of the DMG) matches the public key in `Updater.swift`. The CI signs with the
  `UPDATE_SIGNING_KEY` secret and checks the result against that public key, so a wrong secret fails the release
  instead of shipping an update nobody can install. The private key also lives in the maintainer's keychain;
  losing it breaks automatic updates for every existing installation. Each release carries one signed image, `Oriel-<v>.dmg`
  (volume "Oriel", with `Oriel.app`, the Applications link and a bilingual first-launch text file).
  `ClaudeNotch-<v>.dmg`, which the Updater of 1.1.0 to 1.9.0 looked for, is no longer published: those versions
  find no update. No background picture with an arrow in the DMG: placing icons needs an interactive Finder
  (AppleScript), which the CI runner does not have.
- **Install**: `hdiutil attach` on a private mount point, the volume's `Oriel.app` must have our bundle
  identifier and the announced version, `ditto` into a hidden folder next to the installed app (same volume),
  detach, then two renames (current → a hidden `-old.app` backup next to it, new → current path) with a rollback if
  the second fails: never a half-replaced app. Only from `/Applications` or `~/Applications` with a writable folder;
  otherwise the menu links to the release page. `hdiutil` prints a deprecation notice on recent macOS; it stays
  because the app supports macOS 13.
- **Rename migration** (2.2): the Updater refuses a bundle with another `CFBundleIdentifier`, so 2.1 and earlier
  cannot update into Oriel; the user downloads the DMG once by hand and macOS asks for its accesses again. At the
  first launch `LegacyMigration.run` (before anything else, after quitting a running old instance) takes over the
  old installation; each step is idempotent and never overwrites: `Application Support/ClaudeNotch` → `Oriel`
  (moved, nothing done if both exist; the API and hook tokens go with it); the old UserDefaults domains
  (`io.github.slybald.claudenotch`, then `local.claudenotch`) copied only while the new domain is empty; in
  `~/.claude/settings.json` the file names `claude-notch-hook.sh` and `claude-notch-statusline.sh` rewritten as
  text (the rest of the file is untouched, copy in `settings.json.oriel-migration.bak`) and the scripts and the
  `.previous` file renamed in `~/.claude/hooks`, only once settings.json is rewritten (otherwise the old script stays,
  open Claude sessions still call it, and `HookInstaller.legacyMarker` makes the next launch replace the old entries
  instead of duplicating them; `hooks_config.py` does the same); `~/.codex/hooks.json` is not touched (changing a
  hook definition, `statusMessage` included, changes Codex's trust hash and asks for approval again, so
  `CodexHookInstaller.permissionStatus` stays "Claude Notch"): only the script is refreshed silently at launch
  when the Codex tab is on (`CodexHookSetup.updateScriptIfNeeded`); the `notch` command is recognised by its old
  marker (`NotchCLI.legacyMarker`) and offered as an update; the old LaunchAgents are replaced by the new one when
  the app runs from Applications; outside it (DMG, Downloads) the old LaunchAgent is left alone, because the new one would
  point to a path that disappears on eject, and it is migrated at a later launch from Applications. Covered by `MigrationTests` (paths injected, never the real `~`). Not migrated: the sudo
  rules and the `fanctl` helper (root-owned, the user authorizes again; the old ones are removable, see the README).
- **When to install**: at launch, as soon as a version is found; later, only when no session is working or
  waiting (`SessionStore.hasBusySessions`), retried every 10 min. With the preference off, the version is only
  announced in the menu.
- **Relaunch**: a `/bin/sh` relay started with `posix_spawn` waits for the old PID to exit, then runs
  `open` on the app. `POSIX_SPAWN_SETSID` because launchd kills the process group of a LaunchAgent job when the
  app quits; `POSIX_SPAWN_CLOEXEC_DEFAULT` because an inherited socket would keep port 47823 busy and the new
  instance would quit at once.
- **Hooks after an update**: when the entries in `settings.json` are current and only the bundled hook script
  changed (`HookInstaller.Status.scriptOutdated`), the script is rewritten silently at launch and
  `settings.json` is not touched. When our entries come from a previous version (`.outdated`), entries and
  script are reinstalled silently too (timestamped backup). Only with the Claude tab on, and so only for people who
  already had the hooks; with the tab off, `~/.claude` is not even read at launch. A window opens only if that
  update fails. Hooks that were never installed are offered once, in the setup assistant (first launch, Claude Code
  detected, unticked), then from Settings › Claude; never at every launch.
- **Local API** (`LocalAPI`, [API.md](API.md)): off by default (`api.enabled`), for scripts only. Its own token
  (`api-token`, 0600, `Authorization: Bearer …` so curl reads it with `-H @file`), written once the listener is ready and
  only while the API is on, new at each launch and each time it is turned on: the hook token does not open it and its
  token opens nothing else. Strict schema (unknown field, wrong type or too long = 400, never cut), icons and colors from
  lists, 3 tabs (the oldest leaves), 1 h at most, token bucket (10, then 2/s). No URL, command or file: the only action
  opens an installed app by bundle id, on a click. Tabs rank 2 (under timer, Codex, Claude), never `alert`, no
  Allow/Deny, "via <client>" on the card (names with claude, codex, anthropic or openai refused, no color is Codex's).
  `notch run` resends a result refused by the rate limit once, a second later, else removes its hourglass. Expiry is one wall-clock `asyncAfter` re-armed for the next deadline (no
  periodic timer). Requests are handled on the main thread (`DispatchQueue.main.sync` from the server queue, like
  `/state`). Not done: a `oriel://` scheme (any web page can open one) and App Intents.
- **Reply flow** (`/permission`, `/inbox`): the hook script posts with the token (curl reads it from the 0600 file
  `hook-token`, never from argv) and waits. `HookServer` checks `Host`, `Origin` and the token, then hands the
  request to `ReplyCenter`. A click gives the answer: the app returns it with the `X-Oriel-Proof` header,
  whose value is the 0600 file `hook-proof`. The script checks that header, then prints the decision (`permission`)
  or writes the message to stderr and exits 2 (`inbox`). Fail-open everywhere: a missing token or proof file, a
  failed curl, an empty body, or a missing or wrong proof make the script exit 0 without applying anything, so
  Claude Code falls back to the terminal.
- **Notch visibility and settings** (`NotchVisibilityRule`, `NotchScreenPicker`): on-demand display (a file dragged
  to the shelf, a shortcut) comes first; the user's hiding and the full-screen hiding win over the mode; an expanded
  panel stays up; then the mode decides (always, while Claude is open, during an activity). A named screen that is
  no longer connected falls back to the built-in screen. "Hide from captures" sets `NSWindow.sharingType` to
  `.none`, and `/state` reports it. These rules are plain functions, tested without a screen.
- **Clipboard capture runs while the panel is collapsed**: the capture reads only `changeCount`, once a second
  (0.5 s tolerance), and reads the content only after the privacy checks (concealed, transient or auto-generated
  types, excluded apps). The history stays in memory unless the user opts in; then only text and links go to
  `clipboard-history.json` (0600). A history that stopped with the panel would have holes.
- **The shelf keeps bookmarks, not copies**: `URL.bookmarkData` in `shelf.json` (0600) finds a moved file again and
  marks a missing one. Dragging items out offers copy or alias, never a move; the optional "remove after drag"
  only drops the reference from the shelf.

- **Agenda: a live index tab, with one planned wake-up and no polling.** Once Calendar access is granted (asked only on a
  click, never at launch) and the ears are on, the module runs collapsed too (`keepsRunningWhenCollapsed`). It listens to
  `EKEventStoreChanged`, the day change, `NSSystemClockDidChange` and waking from sleep (a re-read each), and plans ONE
  wake-up through `ModuleScheduler`: `AgendaMath.nextWake` returns the nearest of start − 15 min, start − 5 min, start,
  end of any timed event, plus the next minute change while a countdown is shown (so one wake-up per minute during the
  15-minute window, none the rest of the time). A wake-up reads the clock again and plans the next one; a re-read
  replaces it. A re-read in flight swallows the changes that arrive meanwhile and costs one more read (an iCloud sync
  sends dozens of notifications). The module could stop when nothing is left today, but then nothing could see an
  event added later: it stays on the notification, not on a timer.
  - **What shows** (`AgendaMath.focus`, pure): a timed event that ends in the future and lasts at most 12 hours (a trip
    is not an appointment). From 15 min before: soon (calendar icon, grey), from 5 min: imminent (amber, camera when the
    event has a link, `ModuleEars.alert` so it stays unfolded in *Retracted*, priority 6 above the timer), running
    (green, `now`), then nothing. Imminent beats running (a double booking), the earliest wins a tie. The state colour
    is `ModuleEars.accentHex`, which overrides the module's discreet accent.
  - **Meeting link** (`MeetingLink.find`, pure): the event text is third-party input. Only `https` on the service's own
    domain (Zoom `/j/` and `/my/`, Meet code `abc-defg-hij`, Teams `meetup-join` and `meet`, Webex, FaceTime `join`) is
    kept, found in the URL field, then the location, then the notes (50 000 characters read at most, 2 048 per link). No
    account in the address, no port, no `http`; `facetime:` only from the URL field. `AgendaModule.join` re-checks with
    `MeetingLink.isOpenable` before `NSWorkspace.open`, and nothing opens without a click on **Join**.
  - **Shared calendar code**: `CalendarSource`, `EventKitCalendar` and `MediaEvent` (now with `location` and `meeting`; the
    notes are not kept) moved to `Modules/CalendarSource.swift`; the Player tab still reads its own week on demand.
  - Tests: `AgendaTests` (links and look-alikes, thresholds, the whole countdown, a fake calendar changing, clock and
    scheduler by hand) and `AgendaSnapshotTests` (`agenda-*.png`, `settings-agenda.png`).

## Conventions

- Code comments and commit messages are in French; conventional commits.
- Public repository: no personal data (paths, e-mail addresses, project names, real session identifiers).
- Prove before fixing: reproduce with a test, a command or `/state`.
