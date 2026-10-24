#!/bin/sh
# Hook Claude Code de Oriel : parle à l'app sur http://127.0.0.1:47823, avec le jeton qu'elle écrit dans
# un fichier 0600 (passé à curl par -H @fichier, jamais en argument). Trois modes :
#   (sans argument)  relaie l'événement vers /hook. Lancé en `async: true` : aucune latence. Sort avec 0.
#   permission       PermissionRequest synchrone : la décision prise dans la notch (JSON) part sur la sortie
#                    standard. Sans décision, app arrêtée ou réglage coupé : rien, le dialogue du terminal garde
#                    la main (jamais d'autorisation par défaut).
#   inbox            attente `asyncRewake` (SessionStart, Stop) d'un message envoyé depuis la notch : le texte
#                    part sur stderr avec le code 2, ce qui réveille Claude. Sinon 0. L'identifiant de session
#                    de Claude Desktop accompagne la requête : seul l'onglet Code est tenu sur Stop sans terminal.
#                    Si l'app s'arrête pendant l'attente (relance, mise à jour), l'attente est rétablie dès qu'elle
#                    revient (ORIEL_RETRY secondes au plus, 30 par défaut) : sans cela la session resterait
#                    sans attente jusqu'à son prochain Stop.
# Une décision ou un message n'est appliqué que s'il porte la preuve de l'app (second fichier 0600, jamais
# envoyé) : un autre programme qui occuperait le port, app fermée, ne décide rien.

URL="http://127.0.0.1:${ORIEL_PORT:-47823}"
TOKEN="$HOME/Library/Application Support/Oriel/hook-token"
PROOF="$HOME/Library/Application Support/Oriel/hook-proof"

case "${1:-}" in
permission | inbox)
    [ -r "$TOKEN" ] && [ -r "$PROOF" ] || exit 0
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/oriel.XXXXXX") || exit 0
    trap 'rm -rf "$WORK"' EXIT
    # Hook arrêté (« No » au terminal, fin de session, timeout) : curl part avec lui, l'app voit la connexion se
    # fermer et retire sa carte ou son attente.
    CURL=
    trap 'if [ -n "$CURL" ]; then kill "$CURL" 2>/dev/null; fi; exit 0' HUP INT TERM
    cat > "$WORK/in"
    if [ "$1" = permission ]; then MAX=598; else MAX=86000; fi
    UNTIL=
    while :; do
        curl -q -sf --noproxy "*" -D "$WORK/head" -o "$WORK/out" --connect-timeout 0.5 --max-time "$MAX" \
            -H @"$TOKEN" \
            -H 'Content-Type: application/json' \
            -H 'Expect:' \
            -H "X-Claude-PPID: $PPID" \
            -H "X-Host-Session-Id: ${CLAUDE_CODE_HOST_SESSION_ID:-}" \
            --data-binary @"$WORK/in" \
            "$URL/$1" &
        CURL=$!
        wait "$CURL"
        STATUS=$?
        CURL=
        [ "$STATUS" -eq 0 ] && break
        # Hors `inbox`, ou pour toute autre cause : le terminal garde la main (jamais de décision par défaut).
        [ "$1" = inbox ] || exit 0
        NOW=$(date +%s)
        case "$STATUS" in
        # 52, 56 : l'app a fermé la connexion sans répondre (elle s'arrête). Délai pour qu'elle revienne.
        52 | 56) UNTIL=$((NOW + ${ORIEL_RETRY:-30})) ;;
        # 7, 28 : pas encore revenue ; 22 : jeton de l'ancien lancement, pas encore réécrit.
        7 | 22 | 28) [ -n "$UNTIL" ] && [ "$NOW" -lt "$UNTIL" ] || exit 0 ;;
        *) exit 0 ;;
        esac
        # Claude parti : plus personne à réveiller.
        kill -0 "$PPID" 2>/dev/null || exit 0
        sleep 1 &
        CURL=$!
        wait "$CURL"
        CURL=
    done
    [ -s "$WORK/out" ] || exit 0
    # Comparaison par des commandes internes du shell : la preuve n'apparaît dans aucune liste de processus.
    IFS= read -r EXPECTED < "$PROOF" && [ -n "$EXPECTED" ] || exit 0
    CR=$(printf '\r')
    GENUINE=
    while IFS= read -r LINE; do
        if [ "$LINE" = "X-Oriel-Proof: $EXPECTED$CR" ]; then GENUINE=1; fi
    done < "$WORK/head"
    [ -n "$GENUINE" ] || exit 0
    if [ "$1" = permission ]; then
        cat "$WORK/out"
        exit 0
    fi
    cat "$WORK/out" >&2
    exit 2
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
        -H "X-Claude-PPID: $PPID" \
        -H "X-Term-Program: ${TERM_PROGRAM:-}" \
        -H "X-Bundle-Id: ${__CFBundleIdentifier:-}" \
        -H "X-Entrypoint: ${CLAUDE_CODE_ENTRYPOINT:-}" \
        -H "X-Task-List-Id: ${CLAUDE_CODE_TASK_LIST_ID:-}" \
        -H "X-Config-Dir: ${CLAUDE_CONFIG_DIR:-}" \
        -H "X-Host-Session-Id: ${CLAUDE_CODE_HOST_SESSION_ID:-}" \
        --data-binary @"$TMP" \
        "$URL/hook" 2>/dev/null
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
