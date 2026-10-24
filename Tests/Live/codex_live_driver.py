#!/usr/bin/env python3
"""Pilote un vrai `codex app-server` pour CodexLiveTests (jamais lancé sans ORIEL_CODEX_LIVE=1).

    codex_live_driver.py <CODEX_HOME jetable> <HOME jetable> <port> <dossier de travail> <accept|decline>

1. `hooks/list` : nos hooks sont-ils vus, et de confiance ? Sinon on écrit leur confiance dans le config.toml JETABLE,
   comme le fait `/hooks` (jamais dans le vrai ~/.codex).
2. Un tour : « touch marker.txt » dans un bac à sable en lecture seule, politique `on-request`. Les approbations que
   Codex adresse quand même au client (le hook n'a rien décidé) reçoivent `<accept|decline>`.
Sortie : une ligne JSON (ce qui a été vu), à la fin.
"""

import json
import os
import queue
import subprocess
import sys
import threading
import time

codex_home, fake_home, port, work, reply = sys.argv[1:6]
MARKER = "codex-notch-hook.sh"
env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
env.update(CODEX_HOME=codex_home, HOME=fake_home, ORIEL_PORT=port)


class Client:
    def __init__(self):
        self.proc = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, env=env, cwd=work)
        self.lines = queue.Queue()
        self.next_id = 0
        self.notifications = []
        self.approvals = 0
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"clientInfo": {"name": "notch-live", "version": "0"}})
        self.send({"method": "initialized"})

    def _read(self):
        for line in self.proc.stdout:
            try:
                self.lines.put(json.loads(line))
            except ValueError:
                pass

    def send(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def pump(self, until, timeout):
        """Traite les messages jusqu'à `until(message)`. Les requêtes du serveur sont comptées et reçoivent `reply`."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.lines.get(timeout=0.2)
            except queue.Empty:
                continue
            method = message.get("method", "")
            if "id" in message and method:
                if "requestApproval" in method:
                    self.approvals += 1
                    self.send({"id": message["id"], "result": {"decision": reply}})
            elif method:
                self.notifications.append(message)
            if until(message):
                return message
        return None

    def request(self, method, params, timeout=40):
        self.next_id += 1
        mine = self.next_id
        self.send({"id": mine, "method": method, "params": params})
        answer = self.pump(lambda m: m.get("id") == mine and "result" in m or m.get("id") == mine and "error" in m, timeout)
        if answer is None or "error" in answer:
            raise SystemExit(json.dumps({"error": f"{method}: {answer}"}))
        return answer["result"]

    def close(self):
        self.proc.terminate()


# 1. Nos hooks vus par Codex, et leur confiance.
first = Client()
listed = first.request("hooks/list", {"cwds": [work]})
ours = [h for entry in listed["data"] for h in entry["hooks"] if MARKER in h.get("command", "")]
untrusted = [h for h in ours if h["trustStatus"] != "trusted"]
with open(os.path.join(codex_home, "config.toml"), "a") as config:
    for hook in untrusted:
        config.write(f'\n[hooks.state."{hook["key"]}"]\ntrusted_hash = "{hook["currentHash"]}"\n')
first.close()

# 2. Un vrai tour, avec la confiance posée.
client = Client()
thread = client.request("thread/start", {"cwd": work, "approvalPolicy": "on-request", "sandbox": "read-only",
                                         "ephemeral": True})["thread"]["id"]
client.request("turn/start", {"threadId": thread, "input": [{"type": "text", "text": (
    "Run this exact shell command: touch marker.txt . Then say done in one word.")}]})
done = client.pump(lambda m: m.get("method") == "turn/completed", 120)
# Les relais `async` finissent après le tour (et Codex ne les annonce pas) : on leur laisse le temps d'arriver.
client.pump(lambda m: False, 2)
# Seuls les hooks synchrones sont annoncés (`blocked` : le hook a refusé la commande).
hooks_run = sorted({n["params"]["run"]["eventName"] for n in client.notifications
                    if n.get("method") == "hook/completed" and n["params"]["run"]["status"] in ("completed", "blocked")})
client.close()
print(json.dumps({
    "thread": thread,
    "hooksListed": len(ours),
    "untrustedBefore": len(untrusted),
    "clientApprovals": client.approvals,
    "marker": os.path.exists(os.path.join(work, "marker.txt")),
    "turn": (done or {}).get("params", {}).get("turn", {}).get("status"),
    "hooksRun": hooks_run,
}))
