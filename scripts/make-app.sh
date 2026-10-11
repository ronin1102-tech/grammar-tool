#!/bin/sh
# make-app.sh — builds LWA.app, the double-clickable launcher bundle.
#
# Pattern (proven daily by the Solstice Agent app): an AppleScript applet stub
# that runs scripts/launcher.sh from THIS project. Rebuilding the bundle is
# only needed if the project moves; a git pull updates launcher behavior.
#
# Output: <project root>/LWA.app — hand-install (double-click to test).
# First launch on Catalina: right-click → Open (unsigned applet), once.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/LWA.app"

command -v osacompile >/dev/null || { echo "FAIL: osacompile not found"; exit 1; }

rm -rf "$APP"
osacompile -o "$APP" -e "do shell script \"$ROOT/scripts/launcher.sh open\""
[ -x "$APP/Contents/MacOS/applet" ] || { echo "FAIL: applet stub missing"; exit 1; }

# Self-check: the embedded script must reference this project's launcher.
EMBEDDED=$(osadecompile "$APP/Contents/Documents/Main.scpt" 2>/dev/null || osadecompile "$APP" 2>/dev/null)
echo "$EMBEDDED" | grep -q "$ROOT/scripts/launcher.sh" || { echo "FAIL: embedded script does not point at $ROOT/scripts/launcher.sh"; exit 1; }

echo "OK: $APP"
echo "Install: double-click (first time: right-click → Open). Quit via its dialog or launcher.sh stop."
