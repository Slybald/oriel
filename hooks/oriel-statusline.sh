#!/bin/sh
# Relais de la statusLine de Claude Code pour les jauges de quota de Oriel (Réglages › Claude › Jauges de quota).
# Claude Code passe un JSON sur l'entrée standard et affiche ce que le script écrit. Ce script :
#   1. envoie ce JSON à l'app (127.0.0.1:47823/claude/status, jeton lu dans un fichier 0600 passé à curl par -H @fichier)
#      quand il contient « rate_limits » (abonnés Pro et Max, après la première réponse). L'app n'en garde que les
#      pourcentages et les heures de remise à zéro, en mémoire ; rien n'est écrit sur le disque. App fermée : rien.
#   2. relance l'ANCIENNE commande de statusLine (fichier oriel-statusline.previous, à côté du script) avec le
#      même JSON et affiche sa sortie, comme avant. Sans ancienne commande, il affiche seulement « 5h 39% · 7d 63% ».
# Il sort toujours avec 0, et curl a 1 s au plus : l'affichage n'est jamais retardé par l'app.

URL="http://127.0.0.1:${ORIEL_PORT:-47823}/claude/status"
TOKEN="$HOME/Library/Application Support/Oriel/hook-token"
PREVIOUS="$(dirname "$0")/oriel-statusline.previous"

INPUT=$(cat)

case "$INPUT" in
*'"rate_limits"'*)
    if [ -r "$TOKEN" ]; then
        printf '%s' "$INPUT" | curl -q -s --noproxy "*" -o /dev/null --connect-timeout 0.5 --max-time 1 \
            -H @"$TOKEN" \
            -H 'Content-Type: application/json' \
            -H 'Expect:' \
            --data-binary @- \
            "$URL" 2>/dev/null
    fi
    ;;
esac

if [ -s "$PREVIOUS" ]; then
    # Claude Code lance la commande par sh : l'ancienne reçoit le même JSON, par le même chemin.
    printf '%s\n' "$INPUT" | /bin/sh -c "$(cat "$PREVIOUS")"
    exit 0
fi

FLAT=$(printf '%s' "$INPUT" | tr -d ' \n')
percent() {
    printf '%s' "$FLAT" | sed -n "s/.*\"$1\":{\"used_percentage\":\([0-9]*\).*/\1/p"
}
FIVE=$(percent five_hour)
SEVEN=$(percent seven_day)
OUT=
[ -n "$FIVE" ] && OUT="5h $FIVE%"
[ -n "$SEVEN" ] && OUT="${OUT:+$OUT · }7d $SEVEN%"
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
