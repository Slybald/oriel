#!/bin/sh
# Crée, à partir de build/Oriel.app (lancer scripts/build.sh avant), l'image disque build/Oriel-<version>.dmg :
# Oriel.app, un lien vers Applications et le fichier d'instructions de première ouverture. C'est l'image à
# télécharger et celle de la mise à jour automatique.
# Elle est vérifiée (hdiutil verify, montage en lecture seule) et accompagnée de son SHA-256 dans <dmg>.sha256.
# Pas de fond d'image avec flèche : il faudrait un Finder interactif (AppleScript) pour placer les icônes,
# ce que le runner CI n'offre pas.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Oriel.app"
VOLUME="Oriel"
INSTRUCTIONS="Première ouverture - First launch.txt"

if [ ! -d "$APP" ]; then
    echo "App introuvable : $APP (lance d'abord scripts/build.sh)" >&2
    exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

STAGING=""
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ]; then
        hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true
        rmdir "$MOUNT" 2>/dev/null || true
    fi
    if [ -n "$STAGING" ]; then rm -rf "$STAGING"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
    echo "DMG invalide : $1" >&2
    exit 1
}

make_dmg() {
    NAME=Oriel
    DMG="$ROOT/build/$NAME-$VERSION.dmg"

    # 1. Contenu : l'app et un lien vers /Applications (racine lisible par tous, mktemp la crée en 700).
    STAGING=$(mktemp -d "${TMPDIR:-/tmp}/oriel-dmg.XXXXXX")
    chmod 755 "$STAGING"
    ditto "$APP" "$STAGING/$NAME.app"
    ln -s /Applications "$STAGING/Applications"
    cp "$ROOT/scripts/dmg-first-launch.txt" "$STAGING/$INSTRUCTIONS"

    rm -f "$DMG" "$DMG.sha256"
    hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGING" -fs HFS+ -format UDZO \
        -imagekey zlib-level=9 -ov "$DMG"
    rm -rf "$STAGING"
    STAGING=""

    # 2. Vérifications.
    hdiutil verify -quiet "$DMG"
    MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/oriel-mount.XXXXXX")
    hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
    [ -x "$MOUNT/$NAME.app/Contents/MacOS/Oriel" ] || fail "$NAME.app absente ou incomplète"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MOUNT/$NAME.app/Contents/Info.plist")" = \
        io.github.slybald.oriel ] || fail "identifiant de $NAME.app inattendu"
    [ -s "$MOUNT/$INSTRUCTIONS" ] || fail "fichier d'instructions absent"
    [ -L "$MOUNT/Applications" ] || fail "lien Applications absent"
    [ "$(readlink "$MOUNT/Applications")" = /Applications ] || fail "le lien Applications ne pointe pas vers /Applications"
    codesign --verify --deep --strict "$MOUNT/$NAME.app" || fail "signature de $NAME.app invalide"
    echo "Contenu vérifié : $NAME.app ($(lipo -archs "$MOUNT/$NAME.app/Contents/MacOS/Oriel")), Applications -> /Applications"
    hdiutil detach -quiet "$MOUNT"
    rmdir "$MOUNT"
    MOUNT=""

    # 3. Empreinte, au format de `shasum -a 256 -c`.
    (cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
    echo "DMG prêt : $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
    echo "SHA-256 : $(cut -d' ' -f1 "$DMG.sha256")"
}

make_dmg
