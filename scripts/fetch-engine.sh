#!/bin/sh
# fetch-engine.sh — reproducible engine setup for a fresh machine, one command.
#
# Downloads the PINNED LanguageTool + Temurin artifacts, verifies sha256,
# extracts, patches the JDK for Catalina (see patch-jdk.sh), and smoke-tests
# the engine end-to-end. Idempotent: re-running skips work whose checksum
# already matches.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LT_VERSION="6.6"
JDK_VERSION="jdk-17.0.20.1+1"
LT_SHA="53600506b399bb5ffe1e4c8dec794fd378212f14aaf38ccef9b6f89314d11631"
JDK_SHA="c01975da12ed4235250ff891fe8bba73a9e73037d444b269c9d0922b5dbc8e0a"
LT_URL="https://languagetool.org/download/LanguageTool-${LT_VERSION}.zip"
JDK_URL="https://api.adoptium.net/v3/binary/version/${JDK_VERSION}/mac/x64/jdk/hotspot/normal/eclipse?project=jdk"
LT_ZIP="$ROOT/vendor/LanguageTool-${LT_VERSION}.zip"
JDK_TGZ="$HOME/jdks/temurin17-jdk.tar.gz"
PORT=8081

fetch_verify() { # $1=url $2=dest $3=sha
  if [ -f "$2" ] && echo "$3  $2" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "ok (cached, checksum verified): $2"
    return 0
  fi
  echo "downloading: $1"
  curl -fsSL -o "$2" "$1"
  echo "$3  $2" | shasum -a 256 -c - || { echo "FAIL: checksum mismatch: $2"; exit 1; }
}

command -v curl >/dev/null || { echo "FAIL: curl required"; exit 1; }
command -v unzip >/dev/null || { echo "FAIL: unzip required"; exit 1; }
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: port $PORT already in use: $(lsof -ti tcp:$PORT -sTCP:LISTEN)"; exit 1
fi

mkdir -p "$ROOT/vendor" "$ROOT/engine" "$HOME/jdks"

# 1. Artifacts (pinned + checksummed)
fetch_verify "$LT_URL"  "$LT_ZIP"  "$LT_SHA"
fetch_verify "$JDK_URL" "$JDK_TGZ" "$JDK_SHA"

# 2. Engine
if [ ! -f "$ROOT/engine/LanguageTool-${LT_VERSION}/languagetool-server.jar" ]; then
  echo "extracting LanguageTool..."
  unzip -q "$LT_ZIP" -d "$ROOT/engine"
fi

# 3. JDK (Tarball extracts to ~/jdks/$JDK_VERSION)
if [ ! -x "$HOME/jdks/$JDK_VERSION/Contents/Home/bin/java" ]; then
  echo "extracting Temurin JDK..."
  tar xzf "$JDK_TGZ" -C "$HOME/jdks"
fi
JDKHOME="$HOME/jdks/$JDK_VERSION/Contents/Home"

# 4. Catalina patch (idempotent)
sh "$ROOT/scripts/patch-jdk.sh" "$JDKHOME"

# 5. Smoke test: boot the server, run one real check, tear down.
LOG=/tmp/lwa-fetch-smoke.log
"$JDKHOME/bin/java" -Djava.awt.headless=true -Xms256m -Xmx1g \
  -cp "$ROOT/engine/LanguageTool-${LT_VERSION}/languagetool-server.jar" \
  org.languagetool.server.HTTPServer --port $PORT >>"$LOG" 2>&1 &
PID=$!
# If anything kills this script while the smoke server is booting, take the
# server down with it — never leave an orphaned listener on the port.
trap 'kill "$PID" 2>/dev/null || true' EXIT INT TERM
i=0
while [ $i -lt 60 ]; do
  # curl exits non-zero while the JVM is still booting — that is the expected
  # cold-start state, not an error (and set -e must not kill us for it).
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT/v2/languages" 2>/dev/null || true)
  [ "$code" = "200" ] && break
  kill -0 "$PID" 2>/dev/null || { echo "FAIL: engine died during smoke test"; tail -5 "$LOG"; exit 1; }
  sleep 1; i=$((i+1))
done
[ "$code" = "200" ] || { echo "FAIL: engine not ready in 60s"; kill "$PID" 2>/dev/null || true; exit 1; }
MATCHES=$(curl -s --data-urlencode "text=Their was a obvious mistake." \
  --data-urlencode "language=en-US" "http://localhost:$PORT/v2/check" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin)['matches']))")
kill "$PID" 2>/dev/null || true
echo "smoke: HTTP 200, $MATCHES grammar matches on test sentence"
[ "${MATCHES:-0}" -ge 1 ] || { echo "FAIL: engine answered but found no matches"; exit 1; }
echo "OK: engine ready at $ROOT/engine/LanguageTool-${LT_VERSION} (JDK: $JDKHOME)"
