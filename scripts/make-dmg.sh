#!/bin/sh
# Crée, à partir de build/Oriel.app (lancer scripts/build.sh avant), deux images disque de la même app :
#   build/Oriel-<version>.dmg        avec Oriel.app : celle à télécharger, et celle de la mise à jour automatique d'Oriel ;
#   build/Oriel-<version>.dmg  avec Oriel.app : la seule que la mise à jour automatique des versions 1.1.0 à
#                                    1.9.0 sait installer (l'app se renomme Oriel.app à son lancement).
# Chacune est vérifiée (hdiutil verify, montage en lecture seule) et accompagnée de son SHA-256 dans <dmg>.sha256.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Oriel.app"
VOLUME="Oriel"

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

# make_dmg <nom> : build/<nom>-<version>.dmg contenant <nom>.app.
make_dmg() {
    NAME=$1
    DMG="$ROOT/build/$NAME-$VERSION.dmg"

    # 1. Contenu : l'app et un lien vers /Applications (racine lisible par tous, mktemp la crée en 700).
    STAGING=$(mktemp -d "${TMPDIR:-/tmp}/oriel-dmg.XXXXXX")
    chmod 755 "$STAGING"
    ditto "$APP" "$STAGING/$NAME.app"
    ln -s /Applications "$STAGING/Applications"

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

make_dmg Oriel
make_dmg Oriel
