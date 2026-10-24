#!/bin/sh
# Hook Codex de Oriel : parle à l'app sur http://127.0.0.1:47823, avec le jeton qu'elle écrit dans un fichier
# 0600 (passé à curl par -H @fichier, jamais en argument). Deux modes :
#   (sans argument)  relaie l'événement vers /codex/hook. Lancé en `async: true` : aucune latence. Sort avec 0.
#   permission       PermissionRequest synchrone : la décision prise dans la notch (JSON) part sur la sortie
#                    standard. Sans décision, app arrêtée ou réglage coupé : rien, Codex pose sa question
#                    dans le terminal (jamais d'autorisation par défaut). Codex attend ce hook avant son invite.
# Une décision n'est appliquée que si elle porte la preuve de l'app (second fichier 0600, jamais envoyé) :
# un autre programme qui occuperait le port, app fermée, ne décide rien.

URL="http://127.0.0.1:${ORIEL_PORT:-47823}"
TOKEN="$HOME/Library/Application Support/Oriel/hook-token"
PROOF="$HOME/Library/Application Support/Oriel/hook-proof"

case "${1:-}" in
permission)
    [ -r "$TOKEN" ] && [ -r "$PROOF" ] || exit 0
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/oriel.XXXXXX") || exit 0
    trap 'rm -rf "$WORK"' EXIT
    # Hook arrêté (Ctrl-C, timeout) : curl part avec lui, l'app voit la connexion se fermer et retire sa carte.
    CURL=
    trap 'if [ -n "$CURL" ]; then kill "$CURL" 2>/dev/null; fi; exit 0' HUP INT TERM
    cat > "$WORK/in"
    curl -q -sf --noproxy "*" -D "$WORK/head" -o "$WORK/out" --connect-timeout 0.5 --max-time 70 \
        -H @"$TOKEN" \
        -H 'Content-Type: application/json' \
        -H 'Expect:' \
        -H "X-Codex-PPID: $PPID" \
        -H "X-Term-Program: ${TERM_PROGRAM:-}" \
        -H "X-Bundle-Id: ${__CFBundleIdentifier:-}" \
        --data-binary @"$WORK/in" \
        "$URL/codex/permission" &
    CURL=$!
    wait "$CURL" || exit 0
    CURL=
    [ -s "$WORK/out" ] || exit 0
    # Comparaison par des commandes internes du shell : la preuve n'apparaît dans aucune liste de processus.
    IFS= read -r EXPECTED < "$PROOF" && [ -n "$EXPECTED" ] || exit 0
    CR=$(printf '\r')
    GENUINE=
    while IFS= read -r LINE; do
        if [ "$LINE" = "X-Oriel-Proof: $EXPECTED$CR" ]; then GENUINE=1; fi
    done < "$WORK/head"
    [ -n "$GENUINE" ] || exit 0
    cat "$WORK/out"
    exit 0
    ;;
esac

TMP=$(mktemp "${TMPDIR:-/tmp}/oriel.XXXXXX") || exit 0
trap 'rm -f "$TMP"' EXIT
trap 'exit 0' HUP INT TERM
cat > "$TMP"

send() {
    curl -q -s --noproxy "*" -o /dev/null --connect-timeout 0.5 --max-time 2 \
        -H @"$TOKEN" \
        -H 'Content-Type: application/json' \
        -H 'Expect:' \
        -H "X-Codex-PPID: $PPID" \
        -H "X-Term-Program: ${TERM_PROGRAM:-}" \
        -H "X-Bundle-Id: ${__CFBundleIdentifier:-}" \
        --data-binary @"$TMP" \
        "$URL/codex/hook" 2>/dev/null
}

if ! send; then
    # App fermée (ou jeton pas encore écrit) : on la relance au début d'une session ou d'un tour, puis on réessaie.
    if grep -Eq '"hook_event_name"[[:space:]]*:[[:space:]]*"(SessionStart|UserPromptSubmit)"' "$TMP"; then
        open -g -b io.github.slybald.oriel >/dev/null 2>&1 || exit 0
        i=0
        while [ "$i" -lt 10 ]; do
            sleep 0.3
            send && break
            i=$((i + 1))
        done
    fi
fi
exit 0
