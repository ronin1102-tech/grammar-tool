#!/bin/sh
# ext-battery.sh — J5 battery: service-worker engine health, capture-channel.
# Usage: ext-battery.sh <up|down>   (engine state you want the popup to report)
#
# Channel (the only one PROVEN on this machine): the SW POSTs its status JSON
# to 127.0.0.1:8082/capture; this script runs a local capture server and reads
# the result. Nothing listens on 8082 outside tests.
#
# Field-proven constraints (Chrome 128 / Catalina, 2026-10-11):
#  - --headless=new does NOT install unpacked extensions (ERR_BLOCKED_BY_CLIENT),
#    so this battery runs HEADED; a window appears for a few seconds.
#  - fresh user-data-dir per run (reused dirs hold a SingletonLock and abort).
#  - Chrome killed by PID once evidence lands (it may not exit on its own).

set -u
WANT="${1:?usage: ext-battery.sh <up|down>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTDIR="$ROOT/extension"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CAP_PORT=8082
CAPJS="/tmp/lwa-capture-server.js"
CAPDATA="/tmp/lwa-capture.jsonl"
BLOG="/tmp/lwa-ext-battery-chrome.log"

[ -f "$EXTDIR/manifest.json" ] || { echo "FAIL: extension not built at $EXTDIR"; exit 1; }

# Fresh capture server per run (kill any stale one first).
lsof -ti tcp:$CAP_PORT -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
sleep 1
cat > "$CAPJS" <<'EOF'
const http = require('http');
const fs = require('fs');
http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/capture') {
    let b = '';
    req.on('data', c => b += c);
    req.on('end', () => { fs.appendFileSync('/tmp/lwa-capture.jsonl', b.trim() + '\n'); res.writeHead(204); res.end(); });
  } else { res.writeHead(404); res.end(); }
}).listen(8082, '127.0.0.1', () => console.log('capture up'));
EOF
rm -f "$CAPDATA"
node "$CAPJS" > /tmp/lwa-capture-server.log 2>&1 &
NODEPID=$!
sleep 1
# Prove the channel BEFORE trusting it (the lesson of this battery).
curl -s -X POST -d '{"smoke":true}' "http://127.0.0.1:$CAP_PORT/capture" -o /dev/null
grep -q smoke "$CAPDATA" 2>/dev/null || { echo "FAIL: capture channel dead"; kill $NODEPID 2>/dev/null; exit 1; }
rm -f "$CAPDATA"   # drop the smoke line; only real captures count

PROFILE="/tmp/lwa-battery-profile-$$"
rm -rf "$PROFILE"
"$CHROME" --load-extension="$EXTDIR" --user-data-dir="$PROFILE" --no-first-run \
  --no-default-browser-check --window-size=420,320 about:blank > "$BLOG" 2>&1 &
CPID=$!

STATUS=""
i=0
while [ $i -lt 30 ]; do
  [ -s "$CAPDATA" ] && { STATUS=$(tail -1 "$CAPDATA"); break; }
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; i=$((i+1))
done
kill "$CPID" 2>/dev/null || true; sleep 1; kill -9 "$CPID" 2>/dev/null || true
kill $NODEPID 2>/dev/null || true
rm -rf "$PROFILE"

echo "evidence: capture=[$STATUS]"
OKFLAG=$(printf '%s' "$STATUS" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
case "$WANT" in
  down)
    [ "$OKFLAG" = "False" ] && { echo "PASS: SW correctly reports engine DOWN (engine stopped)"; exit 0; }
    echo "FAIL: expected ok:false, got: $STATUS"; exit 1 ;;
  up)
    [ "$OKFLAG" = "True" ] && { echo "PASS: SW reports UP (real check POST succeeded)"; exit 0; }
    echo "FAIL: expected ok:true, got: $STATUS"; exit 1 ;;
  *) echo "usage: ext-battery.sh <up|down>"; exit 2 ;;
esac
