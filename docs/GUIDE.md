# Oriel guide

Everything the [README](../README.md) leaves out: each tab, each setting, what the app reads and writes, how it
works and its limits. [Version française](GUIDE.fr.md).

## Features in detail

- **Session states at a glance**: ready, thinking, running a tool (with the command or the file),
  waiting for your permission, waiting for your answer, plan to review, done, error, compacting the context.
  Sessions that need you are listed first, with an amber outline.
- **Pop-ups**: a small pop-up comes down from the collapsed notch for a message, an email, Claude or Codex, the end of
  a timer or an upcoming event, for the tabs you turned on. Hover keeps it open, a click opens the tab (Settings › General). During a meeting with a link, a screen mirror or while a microphone is in use, the pop-up hides the sender and the text. This is not full protection: a screen share without an open microphone is not detected.
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
- **Ten more tabs**: Player, Agenda, Quick Settings, Shelf, Clipboard, Timer, Quick notes, Messages, Mail and
  Microphone & Camera (see [Tabs](#tabs)).
- **Health** (Settings › Health): what Oriel runs (memory, CPU, permissions) and a report you can copy. The notch calms its animations on its own in Low Power Mode or when the Mac runs hot.
- **Your own index tabs** (optional, see [Scripts](#scripts-local-api-and-notch-command)): `notch run -- make` shows an
  hourglass, then ✓ or ✗ with the duration; any script can show a short status through a local API.
- **Command bar**: one field, one-key prefixes (see [Command bar](#command-bar)): `t 25` starts a timer, `n idea`
  creates a note, `c link` searches your copies, `s presentation` applies a scene, `> message` writes to Claude.
- Works on screens without a notch too (Mac without a notch, external display, closed lid): by default nothing is
  drawn at rest, a tiny pearl shows during an activity, and the pointer coming close turns it into a frosted-glass
  notch. It can also stay a frosted-glass notch, a pill floating just below the top edge, or a drawn notch.

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
  without limit), the fans (automatic or a fixed speed), the battery of the Mac and of your AirPods, and three scenes: Battery, Normal and Presentation.
- **Shelf**: files and folders to keep at hand. Drop them on the notch, even when it is collapsed, and drag them
  out to Finder or another app. The shelf keeps a reference to each item: nothing is copied.
- **Clipboard**: your recent copies (text, links, images, files, colors). Click one to copy it again; nothing is
  pasted for you. Copies made in password managers are not recorded. Right-click an image to copy its text or read a QR code, and copy a colour as hex or RGB. Text that looks like a token, a key or a card number is removed from the history after 60 s (a setting turns this off; the list is short, not a guarantee).
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
- **Microphone & Camera** (off by default): an index tab on the collapsed notch, orange when a microphone is in use and green for a camera. Oriel never opens the microphone or the camera, and does not show which app uses them.

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
[API.md](API.md).

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
  The quota shows up when Claude Code runs in a terminal (`claude`). The Claude app (its Code tab included) does not
  pass it on: it never runs the `statusLine`.
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
  picked by name. A screen without a notch gets a virtual one at the top center, in the style set in Appearance
  ("Display Without a Notch"): pearl (the default: a tiny 44 × 20 pt pearl with the activity's icon and number, nothing at rest; the pointer
  coming close turns it into a frosted-glass notch, then the panel opens), chameleon (invisible at rest, frosted glass
  during an activity), a pill floating just below the top edge, or a drawn notch.
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

## Setup assistant

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

## Privacy

- Everything stays on your Mac. Oriel sends no data about you or your sessions: no analytics. Its only
  outgoing requests are the update check to `api.github.com` and the download of new versions from GitHub
  (see [Updates](../README.md#updates)).
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
  or files. Pausing the capture stops the checks until the next launch. Text that looks like a token, a key or a card number is removed from the history after 60 s (a setting turns this off); the list is short and is not a guarantee.
- What the app reads: the hook events (Claude Code and Codex), the end of the transcript of a running session (to detect Esc),
  Claude Code's task files, the process list (to find the host app), the track playing and its artwork (Player),
  the events of the calendars you chose to show, the state of Wi-Fi and Bluetooth, and the battery level, and whether a microphone or a camera is in use (the state only, never their stream). With the quota on:
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
- **Desktop, Documents, Downloads**: only for optional command-line companion tools that Oriel can run in the
  background (not part of this repository).
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
- Quota gauges: Claude's figure only arrives when a session that has the relay answers (Pro and Max, terminal sessions
  only: the Code tab of the Claude app never runs the `statusLine`), and is lost when the app restarts until the next answer. A project or local `settings.json` that sets its
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
- Focus: macOS gives an app no way to set Focus, and reading it needs an authorization that Oriel never asks for. The tile runs a shortcut that you create in the Shortcuts app
  (the tile explains how). The state it shows is the one set by your last click.
- Bluetooth uses a private API of `IOBluetooth`, loaded at runtime. Apple may change it without notice.
- Wi-Fi: the name of the network is not shown.
- Clipboard: images over 5 MB are not kept, and the history holds 25, 50 or 100 items. Pinned items are added to
  that number and never removed.
- Quick notes: 200 notes at most, 100,000 characters per note, plain text only.
- Timer: the end of a timer is announced by the sound and the "Done" ear. The notification needs your permission.
