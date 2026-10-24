# Local API and the `notch` command

Your own scripts and programs can put small **ear tabs** beside the collapsed notch: "build done", "backup failed",
"12 unread", a render in progress. No code is loaded into the app: a program sends a short JSON description over the
local server, the app checks it field by field and draws it.

```sh
notch show --title "Backup done" --text OK --icon externaldrive.fill --color green --ttl 300
notch run -- make test        # hourglass while it runs, then ✓ or ✗ with the duration
notch clear                   # removes them all
```

The API is **off by default**. Turn it on in **Settings › Scripts**. Turned off, its routes answer 403, its ear tabs go
away and its token file is deleted.

## The `notch` command

Settings › Scripts › **Install** copies the command to `~/.local/bin/notch` (and **Update** or **Remove** later). It is
never installed without that click, and never over another program called `notch`. If your shell does not find it, add
`~/.local/bin` to your `PATH`.

```text
notch show --title TEXT [--text SHORT] [--detail TEXT] [--icon SYMBOL] [--color NAME]
           [--ttl SECONDS] [--id ID] [--app BUNDLE_ID] [--client NAME]
notch run [--title TEXT] [--id ID] [--client NAME] [--] COMMAND [ARGUMENTS...]
notch clear [--id ID]
notch help
```

- `show` prints the id of the ear tab. The same `--id` replaces it in place (a progress that updates).
- `run` shows an hourglass titled with the command name while it runs, then a check mark (green) or a cross (red, with
  the exit code) and the duration for 60 s. It exits with the status of the command. With the API off or the app
  closed, the command still runs, without an ear tab. Ctrl-C or closing the terminal stops the command and shows the
  cross; if `notch` itself is killed outright, the hourglass goes away at the end of its hour.
- `clear` removes one ear tab (`--id`) or all of them.
- `--client` is the name shown on the card ("via make.sh") and in Settings › Scripts. Default: `notch`.
- `ORIEL_PORT` changes the port (tests).

## HTTP API

Base URL: `http://127.0.0.1:47823/api/v1/ears`.

### Authentication

While the API is on, the app writes `~/Library/Application Support/Oriel/api-token` (mode 0600, readable by your
account only). It holds one header line, `Authorization: Bearer <32 hex>`, so curl can read it with `-H @file`: the
token never appears on a command line or in `ps`. The token is new at each launch of the app and each time the API is
turned on: read the file at each call, do not copy the token.

This token is not the one of the Claude Code and Codex hooks: it opens `/api/v1/ears` and nothing else, and the hook
token does not open the API.

Every request must also carry `Host: 127.0.0.1:47823` exactly and no `Origin` header (curl does both on its own). A web
page cannot meet these rules, even through DNS rebinding, so no website can call the API.

### `POST /api/v1/ears`: show or replace an ear tab

`Content-Type: application/json`, body of 4 KB at most, a JSON object with these fields only (any other field, or a
field of the wrong type, is refused):

| Field | Type | Rule | Default |
|---|---|---|---|
| `title` | string | required, 1 to 40 characters; on the unfolded card | |
| `text` | string | 12 characters at most; beside the icon at rest (`OK`, `2m14`, `12`) | none (icon alone) |
| `detail` | string | 160 characters at most; on the unfolded card, 3 lines | none |
| `icon` | string | an SF Symbol from the list below | `bell.fill` |
| `color` | string | a color name from the list below | `indigo` |
| `ttl` | integer | seconds before it goes away, 1 to 3600 | 60 |
| `id` | string | 1 to 32 of `A-Z a-z 0-9 . _ -`; the same id replaces the ear tab | random, returned |
| `app` | string | bundle identifier of an installed app (`com.apple.Terminal`): the card gets a button that opens it | no button |
| `client` | string | 1 to 24 of `A-Z a-z 0-9 space . _ -`: your program's name, shown as "via …"; names containing claude, codex, anthropic or openai are refused | `script` |

Texts are shown on one line: line breaks and tabs become spaces; control characters, writing-direction overrides,
zero-width and private-use characters are removed. Lengths count characters (an emoji is one), after that cleaning.
Nothing is ever cut silently: too long is refused.

Answer: `200 {"id":"…"}`.

At most **3** ear tabs from scripts at a time: a fourth replaces the oldest. They sit after Claude, Codex and the timer,
before the player, and never stay unfolded on their own.

### `DELETE /api/v1/ears/{id}` and `DELETE /api/v1/ears`

Remove one ear tab (`204`, or `404` if there is none with that id) or all of them (`204`).

### Errors

Errors come as `{"error": "<code>", "message": "<explanation>"}`.

| Status | `error` | When |
|---|---|---|
| 400 | `invalid` | body not a JSON object, unknown field, wrong type, out of bounds, unknown icon, color or app |
| 401 | `unauthorized` | missing or wrong token |
| 403 | `api_disabled` | the API is off (also: wrong `Host` or any `Origin`, with no body) |
| 404 | `not_found` | unknown route or id |
| 413 | `too_large` | body over 4 KB |
| 415 | `unsupported_media_type` | `POST` without `Content-Type: application/json` |
| 429 | `rate_limited` | more than 10 requests in a burst, then more than 2 per second |

### Examples

```sh
TOKEN="$HOME/Library/Application Support/Oriel/api-token"

curl -q -s --noproxy '*' -H @"$TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"backup","title":"Backup done","text":"OK","icon":"externaldrive.fill","color":"green","ttl":300,"client":"backup.sh"}' \
  http://127.0.0.1:47823/api/v1/ears

curl -q -s --noproxy '*' -X DELETE -H @"$TOKEN" http://127.0.0.1:47823/api/v1/ears/backup
```

`--noproxy '*'` keeps an `http_proxy` setting from sending the request, and the token, to a proxy; `-q` ignores
`~/.curlrc`.

Python (standard library only):

```python
import json, pathlib, urllib.request

header = (pathlib.Path.home() / "Library/Application Support/Oriel/api-token").read_text().strip()
name, value = header.split(": ", 1)
request = urllib.request.Request(
    "http://127.0.0.1:47823/api/v1/ears",
    data=json.dumps({"title": "Training done", "text": "98%", "icon": "chart.line.uptrend.xyaxis",
                     "color": "mint", "client": "train.py"}).encode(),
    headers={name: value, "Content-Type": "application/json"},
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never through a proxy
print(opener.open(request, timeout=5).read().decode())
```

### Icons

`bell.fill`, `checkmark.circle.fill`, `xmark.circle.fill`, `exclamationmark.triangle.fill`, `info.circle.fill`,
`hourglass`, `clock.fill`, `timer`, `hammer.fill`, `wrench.and.screwdriver.fill`, `gearshape.fill`, `terminal.fill`,
`server.rack`, `externaldrive.fill`, `cpu`, `memorychip`, `arrow.down.circle.fill`, `arrow.up.circle.fill`,
`arrow.triangle.2.circlepath`, `icloud.fill`, `network`, `globe`, `envelope.fill`, `bubble.left.fill`, `star.fill`,
`heart.fill`, `flag.fill`, `bolt.fill`, `flame.fill`, `leaf.fill`, `drop.fill`, `sun.max.fill`, `moon.fill`,
`cloud.fill`, `music.note`, `film.fill`, `photo.fill`, `doc.fill`, `folder.fill`, `tray.full.fill`, `shippingbox.fill`,
`cart.fill`, `chart.bar.fill`, `chart.line.uptrend.xyaxis`, `battery.100`, `wifi`, `house.fill`, `person.fill`,
`calendar`, `sparkles`, `cup.and.saucer.fill`, `gamecontroller.fill`, `book.fill`, `paintbrush.fill`, `tag.fill`.

None of them looks like a permission request (no raised hand, lock, key, shield or question mark).

### Colors

`gray`, `red`, `orange`, `yellow`, `green`, `mint`, `cyan`, `blue`, `indigo`, `purple`, `pink` (none is Codex's teal).

## Security model

- **Off by default.** The notch is for everyone; only people who write scripts need this, and one switch turns it on.
- **Local and authenticated.** Loopback only (`127.0.0.1`), its own token in a 0600 file passed with `curl -H @file`,
  compared in constant time; exact `Host` and no `Origin`, so no web page reaches it.
- **Data, never code.** A strict schema with bounded sizes; icons and colors from fixed lists; no command, no URL, no
  file. The only action is a button that opens an installed app by its bundle identifier, on your click, with no
  document or argument.
- **Bounded.** 3 ear tabs at most, 1 hour at most, 10 requests in a burst then 2 per second. Expiry uses one scheduled
  wake-up, no periodic timer: the collapsed notch stays at ~0 % CPU.
- **Cannot pass for Claude or Codex.** Script ear tabs rank below theirs, never stay unfolded on their own, have no
  Allow or Deny button, and their card always says which program sent them ("via backup.sh"; a name with claude, codex,
  anthropic or openai is refused). No color is Codex's. Their ids are kept apart from the modules' (`api.<id>`), so a
  script whose id is `claude` gets its own tab, not Claude's.

Settings › Scripts lists the last five programs that showed something (the name each one gives itself, kept in memory
only), so you can see who uses the API.

## Not included

- **A `oriel://` link.** Any web page can open a custom URL scheme; the API stays reachable from local programs
  only.
- **Shortcuts actions (App Intents).** A shortcut can call the API with "Run Shell Script" and `notch`.
