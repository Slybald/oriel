#!/bin/sh
# Régénère Resources/AppIcon.icns depuis Resources/Icon/AppIcon.svg (dessin complet) et AppIcon-small.svg
# (dessin simplifié à part pour les tailles 16 et 32 px, comme le fait Apple : moins d'encoches, cadre plus épais).
# Nécessite rsvg-convert (brew install librsvg) et iconutil. Le .icns est versionné : build.sh et la CI n'ont pas besoin de rsvg.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/Resources/Icon"
SET=$(mktemp -d "${TMPDIR:-/tmp}/oriel-icon.XXXXXX")/AppIcon.iconset
mkdir -p "$SET"
trap 'rm -rf "$(dirname "$SET")"' EXIT

# fichier:taille en pixels (les @2x portent le double du nom)
for ENTRY in icon_16x16:16 icon_16x16@2x:32 icon_32x32:32 icon_32x32@2x:64 icon_128x128:128 icon_128x128@2x:256 \
    icon_256x256:256 icon_256x256@2x:512 icon_512x512:512 icon_512x512@2x:1024; do
    NAME=${ENTRY%%:*}
    PX=${ENTRY##*:}
    if [ "$PX" -le 32 ]; then FILE="$SRC/AppIcon-small.svg"; else FILE="$SRC/AppIcon.svg"; fi
    rsvg-convert -w "$PX" -h "$PX" "$FILE" -o "$SET/$NAME.png"
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "Icône prête : Resources/AppIcon.icns ($(du -h "$ROOT/Resources/AppIcon.icns" | cut -f1 | tr -d ' '))"
