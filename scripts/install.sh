#!/bin/sh
# Installation développeur : compile, installe l'app, le hook, les entrées settings.json et le LaunchAgent.
# (Depuis un DMG, rien de tout ça : l'app installe elle-même ses hooks au premier lancement.)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Même valeur que CFBundleIdentifier (Resources/Info.plist) et AppIdentity.bundleId.
LABEL=io.github.slybald.oriel
LEGACY_LABELS="io.github.slybald.claudenotch local.claudenotch"
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HOOK="$CONFIG_DIR/hooks/oriel-hook.sh"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/scripts/build.sh"

# 1. App
if [ -w /Applications ]; then
    DEST=/Applications
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Identifiants d'avant le renommage en Oriel : LaunchAgent déchargé et supprimé.
for OLD in $LEGACY_LABELS; do
    launchctl bootout "gui/$(id -u)/$OLD" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$OLD.plist"
done
pkill -x Oriel 2>/dev/null || true
i=0
while pgrep -x Oriel >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
    sleep 0.1
    i=$((i + 1))
done
rm -rf "$DEST/Oriel.app"
ditto "$ROOT/build/Oriel.app" "$DEST/Oriel.app"
"$LSREGISTER" -f "$DEST/Oriel.app" 2>/dev/null || true
echo "App installée : $DEST/Oriel.app"

# 2. Script de hook
mkdir -p "$CONFIG_DIR/hooks"
install -m 755 "$ROOT/hooks/oriel-hook.sh" "$HOOK"
echo "Hook installé : $HOOK"

# 3. settings.json
/usr/bin/python3 -I "$ROOT/scripts/hooks_config.py" install "$HOOK"

# 4. LaunchAgent (lancement à l'ouverture de session, pas de KeepAlive)
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Oriel.app/Contents/MacOS/Oriel</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "LaunchAgent chargé : $AGENT"
echo "Terminé. Vérifie avec : claude doctor"
