#!/bin/sh
# Compile en release (binaire universel arm64 + x86_64) et assemble build/Oriel.app (exécutable Oriel,
# identifiant io.github.slybald.oriel : conservés pour la mise à jour).
#
# Signature : ad hoc par défaut (le cdhash change à chaque build, macOS redemande alors les autorisations).
# SIGN_KEYCHAIN=<trousseau> SIGN_IDENTITY=<nom ou empreinte du certificat> scripts/build.sh → signature avec ce
# certificat : l'exigence désignée ne dépend plus du build, macOS garde les autorisations d'une version à l'autre.
# Les deux variables vont ensemble (la CI de release les pose, voir .github/workflows/release.yml). Pas de
# hardened runtime : il imposerait des entitlements et bloquerait le code chargé par des processus tiers
# (mediaremote-adapter, chargé par perl).
#
# VERSION=1.2.3 scripts/build.sh  → version injectée dans la copie de l'Info.plist
# (CFBundleShortVersionString et CFBundleVersion). Par défaut : celle de Resources/Info.plist.
# RELEASE_CHANNEL=1 scripts/build.sh → OrielUpdateChannel = release : l'app se met à jour seule depuis
# les releases GitHub. Sans (builds locaux, scripts/install.sh) : aucune mise à jour automatique.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PLIST_SRC="$ROOT/Resources/Info.plist"
VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SRC")}
case "$VERSION" in
    '' | *[!0-9.]* | .* | *. | *..*)
        echo "VERSION invalide : « $VERSION » (attendu : 1, 1.2 ou 1.2.3)" >&2
        exit 1
        ;;
esac

if [ -n "${SIGN_KEYCHAIN:-}" ] && [ -n "${SIGN_IDENTITY:-}" ]; then
    SIGNATURE="signature stable"
elif [ -z "${SIGN_KEYCHAIN:-}${SIGN_IDENTITY:-}" ]; then
    SIGNATURE="signature ad hoc"
else
    echo "SIGN_KEYCHAIN et SIGN_IDENTITY vont ensemble : définis les deux ou aucune." >&2
    exit 1
fi

ARCHS="--arch arm64 --arch x86_64"
# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCHS --show-bin-path)/Oriel"

for arch in arm64 x86_64; do
    if ! lipo "$BIN" -verify_arch "$arch"; then
        echo "Architecture $arch absente de $BIN ($(lipo -archs "$BIN"))" >&2
        exit 1
    fi
done

APP="$ROOT/build/Oriel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Oriel"
cp "$PLIST_SRC" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
CHANNEL=développement
if [ "${RELEASE_CHANNEL:-}" = 1 ]; then
    plutil -replace OrielUpdateChannel -string release "$APP/Contents/Info.plist"
    CHANNEL=release
fi
cp "$ROOT/hooks/oriel-hook.sh" "$APP/Contents/Resources/oriel-hook.sh"
chmod 755 "$APP/Contents/Resources/oriel-hook.sh"
cp "$ROOT/hooks/codex-notch-hook.sh" "$APP/Contents/Resources/codex-notch-hook.sh"
chmod 755 "$APP/Contents/Resources/codex-notch-hook.sh"
# Commande `notch` (API locale) : copiée dans ~/.local/bin seulement sur un clic dans les réglages.
cp "$ROOT/hooks/notch" "$APP/Contents/Resources/notch"
chmod 755 "$APP/Contents/Resources/notch"

# Outil des ventilateurs (Sources/fanctl) : livré dans Helpers, jamais exécuté de là. L'app le copie dans
# /Library/PrivilegedHelperTools (root:wheel) à la demande de l'utilisateur, après vérification de son empreinte.
FANCTL="$(dirname "$BIN")/fanctl"
mkdir -p "$APP/Contents/Helpers"
cp "$FANCTL" "$APP/Contents/Helpers/fanctl"
for arch in arm64 x86_64; do
    lipo "$FANCTL" -verify_arch "$arch" || { echo "Architecture $arch absente de $FANCTL" >&2; exit 1; }
done
cp "$ROOT/hooks/oriel-statusline.sh" "$APP/Contents/Resources/oriel-statusline.sh"
chmod 755 "$APP/Contents/Resources/oriel-statusline.sh"

# Lecture en cours : mediaremote-adapter (Vendor/mediaremote-adapter, BSD-3-Clause, commit noté dans COMMIT).
# Depuis macOS 15.4, MediaRemote ne répond qu'aux binaires d'Apple : /usr/bin/perl lance le script, qui charge
# ce framework (l'app ne le lie pas) ; le client de test sert à la commande « test ». Universels, signés avec
# l'app plus bas (codesign --deep).
MRA="$ROOT/Vendor/mediaremote-adapter"
FRAMEWORK="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
mkdir -p "$FRAMEWORK/Versions/A/Resources" "$APP/Contents/Helpers"
CLANG_FLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -O2 -fobjc-arc"
# shellcheck disable=SC2086
clang $CLANG_FLAGS -dynamiclib -fvisibility=default -I "$MRA/include" -I "$MRA/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter" "$MRA"/src/adapter/*.m "$MRA"/src/private/*.m "$MRA"/src/utility/*.m
# shellcheck disable=SC2086
clang $CLANG_FLAGS -Wno-gnu-folding-constant -I "$MRA/src/test" -framework Foundation -framework MediaPlayer \
    -o "$APP/Contents/Helpers/MediaRemoteAdapterTestClient" "$MRA"/src/test/*.m
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.slybald.oriel.mediaremote-adapter</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
</dict>
</plist>
PLIST
cp "$MRA/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote-adapter.pl"
for BINARY in "$FRAMEWORK/MediaRemoteAdapter" "$APP/Contents/Helpers/MediaRemoteAdapterTestClient"; do
    for arch in arm64 x86_64; do
        lipo "$BINARY" -verify_arch "$arch" || { echo "Architecture $arch absente de $BINARY" >&2; exit 1; }
    done
done

# Traductions (en.lproj, fr.lproj) : macOS affiche le français sur un système en français, l'anglais ailleurs.
for LPROJ in "$ROOT"/Resources/*.lproj; do
    plutil -lint -s "$LPROJ"/*.strings
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

if [ "$SIGNATURE" = "signature stable" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
echo "App prête : $APP (version $VERSION, canal $CHANNEL, $(lipo -archs "$APP/Contents/MacOS/Oriel"), $SIGNATURE)"
