#!/usr/bin/env python3
"""Ajoute ou retire les hooks d'Oriel dans settings.json.

    hooks_config.py install <chemin du script de hook>
    hooks_config.py uninstall

Respecte CLAUDE_CONFIG_DIR. Sauvegarde horodatée avant toute écriture.
Idempotent : nos entrées (repérées par « oriel-hook.sh ») sont retirées puis rajoutées.
Les hooks existants et l'ordre des clés sont conservés. JSON invalide : abandon sans rien toucher.

Un groupe par événement : le relais async ; plus, pour « Répondre depuis la notch », le hook PermissionRequest
synchrone (mode permission, sans onFailure : un échec rend la main au terminal) et l'attente asyncRewake de
SessionStart et Stop (mode inbox). Même résultat, octet pour octet, que HookInstaller.swift.
"""

import json
import os
import shutil
import sys
import tempfile
import time

MARKER = "oriel-hook.sh"
# Nom d'avant le renommage en Oriel : ces entrées sont à nous aussi.
LEGACY_MARKER = "claude-notch-hook.sh"
EVENTS = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "TaskCreated",
    "TaskCompleted",
    "PreCompact",
    "PostCompact",
]
REWAKE_MESSAGE = "Message from the user, sent from Oriel:"
REWAKE_SUMMARY = "Message from Oriel"


def entries(hook_path):
    """Nos hooks, par événement, dans l'ordre où ils sont écrits."""
    command = f'"{hook_path}"'
    relay = {"type": "command", "command": command, "async": True, "timeout": 10}
    permission = {"type": "command", "command": f"{command} permission", "timeout": 600}
    inbox = {
        "type": "command",
        "command": f"{command} inbox",
        "asyncRewake": True,
        "timeout": 86400,
        "rewakeMessage": REWAKE_MESSAGE,
        "rewakeSummary": REWAKE_SUMMARY,
    }
    extra = {"SessionStart": [inbox], "PermissionRequest": [permission], "Stop": [inbox]}
    return {event: [dict(relay)] + [dict(hook) for hook in extra.get(event, [])] for event in EVENTS}


def config_dir():
    return os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")


def settings_path():
    return os.path.join(config_dir(), "settings.json")


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        sys.exit(f"settings.json invalide ({error}) : rien n'a été modifié.")
    if not isinstance(data, dict):
        sys.exit("settings.json n'est pas un objet JSON : rien n'a été modifié.")
    return data


def is_ours(hook):
    return isinstance(hook, dict) and any(m in str(hook.get("command", "")) for m in (MARKER, LEGACY_MARKER))


def strip(settings, drop_empty_root):
    """Retire nos entrées, puis les groupes et événements que ce retrait a vidés."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            inner = group.get("hooks") if isinstance(group, dict) else None
            if isinstance(inner, list) and any(is_ours(h) for h in inner):
                remaining = [h for h in inner if not is_ours(h)]
                if not remaining:
                    continue
                group = dict(group)
                group["hooks"] = remaining
            kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        elif groups:
            del hooks[event]
    if drop_empty_root and not hooks:
        del settings["hooks"]


def install(settings, hook_path):
    strip(settings, drop_empty_root=False)
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        sys.exit("La clé « hooks » de settings.json n'est pas un objet : rien n'a été modifié.")
    for event, ours in entries(hook_path).items():
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            sys.exit(f"hooks.{event} n'est pas une liste : rien n'a été modifié.")
        groups.append({"hooks": ours})


def write(path, settings):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        stem = f"{path}.oriel-{time.strftime('%Y%m%d-%H%M%S')}"
        backup, n = f"{stem}.bak", 1
        while os.path.exists(backup):
            backup, n = f"{stem}-{n}.bak", n + 1
        shutil.copy2(path, backup)
        print(f"Sauvegarde : {backup}")
    mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(prefix=".settings.", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit(__doc__)
    path = settings_path()
    settings = load(path)
    before = json.dumps(settings, sort_keys=False)

    if sys.argv[1] == "install":
        if len(sys.argv) < 3:
            sys.exit("Chemin du script de hook manquant.")
        install(settings, os.path.abspath(os.path.expanduser(sys.argv[2])))
    else:
        strip(settings, drop_empty_root=True)

    if json.dumps(settings, sort_keys=False) == before:
        print(f"{path} : déjà à jour.")
        return
    write(path, settings)
    print(f"{path} : hooks d'Oriel {'installés' if sys.argv[1] == 'install' else 'retirés'}.")


if __name__ == "__main__":
    main()
