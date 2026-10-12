#!/bin/sh
# dict-battery.sh — J9 battery: user dictionary filter, U1–U5 per
# docs/extension-user-dict.md. Drives the REAL popup page (opened as a tab
# with ?battery=1), which exercises the production dict-add / field-check /
# filter paths. U4/U5 (J12 S2-4): the popup opens the /dict fixture page and
# its live overlay must follow add/remove with zero typing. Rig discipline unchanged: capture smoke first, fresh profile,
# Chrome killed by PID, sentinel-then-evidence.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PEM="$ROOT/vendor/lwa-extension.pem"
SCRATCH="$ROOT/tests/fixtures"
CAPDATA="/tmp/lwa-capture.jsonl"
SENTINEL="/tmp/lwa-forms-done"
REPORT="/tmp/lwa-driver-report.json"
BLOG="/tmp/lwa-dict-chrome.log"

[ -f "$PEM" ] || { echo "FAIL: $PEM missing"; exit 1; }
EXTID="$(openssl rsa -in "$PEM" -pubout -outform DER 2>/dev/null | shasum -a 256 | cut -c1-32)"

if ! curl -s -o /dev/null --max-time 2 http://localhost:8081/v2/languages; then
  echo "engine down — starting via launcher…"
  LWA_HEADLESS=1 sh "$ROOT/scripts/launcher.sh" start || { echo "FAIL: engine would not start"; exit 1; }
fi

lsof -ti tcp:8082 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1
cat > /tmp/lwa-capture-server.js <<'EOF'
const http = require('http');
const fs = require('fs');
http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/capture') {
    let b = '';
    req.on('data', c => b += c);
    // "dict" tells the SW's battery-hello to open the popup driver (only
    // this battery does — see background.js onInstalled).
    req.on('end', () => { fs.appendFileSync('/tmp/lwa-capture.jsonl', b.trim() + '\n'); res.writeHead(200); res.end('dict'); });
  } else { res.writeHead(404); res.end(); }
}).listen(8082, '127.0.0.1', () => console.log('capture up'));
EOF
rm -f "$CAPDATA"
node /tmp/lwa-capture-server.js > /tmp/lwa-capture-server.log 2>&1 &
NODE1=$!
sleep 1
curl -s -X POST -d '{"smoke":true}' http://127.0.0.1:8082/capture -o /dev/null
grep -q smoke "$CAPDATA" 2>/dev/null || { echo "FAIL: capture channel dead"; kill $NODE1 2>/dev/null; exit 1; }
rm -f "$CAPDATA"

lsof -ti tcp:8083 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1
rm -f "$SENTINEL" "$REPORT"
node "$SCRATCH/fixture-server.js" > /tmp/lwa-fixture-server.log 2>&1 &
NODE2=$!
sleep 1

PROFILE="/tmp/lwa-dict-profile-$$"
rm -rf "$PROFILE"
"$CHROME" --load-extension="$ROOT/extension" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=500,700 \
  "chrome-extension://$EXTID/popup.html?battery=1" > "$BLOG" 2>&1 &
CPID=$!

# Sentinel-then-evidence: wait for the dict-done capture.
i=0
while [ $i -lt 75 ]; do
  grep -q '"kind":"dict-done"' "$CAPDATA" 2>/dev/null && [ -f "$SENTINEL" ] && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; i=$((i+1))
done
sleep 2
kill "$CPID" 2>/dev/null || true; sleep 1; kill -9 "$CPID" 2>/dev/null || true
kill $NODE1 $NODE2 2>/dev/null || true
rm -rf "$PROFILE"

python3 - "$CAPDATA" "$REPORT" <<'EOF'
import json, sys, os
rep = {}
if os.path.exists(sys.argv[2]):
    try: rep = json.load(open(sys.argv[2]))
    except Exception: pass

caps = []
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace") if os.path.exists(sys.argv[1]) else ""
for line in raw.splitlines():
    line = line.strip()
    if line:
        try: caps.append(json.loads(line))
        except Exception: pass

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" — " + detail) if (detail and not cond) else ""))
    if not cond: fails.append(name)

probes = [c for c in caps if c.get("kind") == "dict-probe"]
by_phase = {c.get("phase"): c for c in probes}
if probes and by_phase.get("driverError"):
    print("FAIL driver crashed: " + str(by_phase["driverError"].get("error"))[:300]); sys.exit(1)

base = by_phase.get("baseline") or {}
sam = by_phase.get("with-sam") or {}
rem = by_phase.get("after-remove") or {}

# U1: engine flags all three words in the probe sentence.
check("U1 baseline: engine flags Sam, Xkalt, mistkae",
      base.get("engineMatches", 0) >= 3 and base.get("shownMatches") == base.get("engineMatches"),
      "baseline=%s" % base)

# U2: adding Sam filters exactly its TYPOS match; mistkae still surfaces.
check("U2 dict-add Sam filters exactly its match",
      sam.get("engineMatches") == base.get("engineMatches") and
      sam.get("shownMatches") == base.get("engineMatches", 0) - 1,
      "with-sam=%s (baseline engine=%s)" % (sam, base.get("engineMatches")))

# U3: removing Sam restores the match; dict back to baseline state.
check("U3 dict-remove restores the match",
      bool(rem) and rem.get("engineMatches") == base.get("engineMatches") and
      rem.get("shownMatches") == base.get("engineMatches"),
      "after-remove=%s" % rem)

# U4/U5 (J12 S2-4): live overlay on a real page follows the dictionary with
# zero typing — the fixture fired exactly one input event, ever.
live_add = by_phase.get("live-added") or {}
live_rem = by_phase.get("live-removed") or {}
live_checks = [c for c in caps if c.get("kind") == "field-check" and c.get("field") == "live"]
if rep.get("driverError"):
    check("fixture driver ran", False, rep["driverError"][:300])
check("U4 dict-add clears the live underline with zero typing",
      live_add.get("sawBase") is True and live_add.get("sawAdd") is True and
      rep.get("inputEvents") == 1 and rep.get("before", 0) >= 3 and rep.get("afterAdd") == rep.get("before", 0) - 1,
      "popup=%s fixture=%s" % (live_add, rep))
check("U5 dict-remove restores the live underline with zero typing",
      live_rem.get("sawRemove") is True and rep.get("afterRemove") == rep.get("before") and len(live_checks) >= 3,
      "popup=%s fixture=%s live field-checks=%d" % (live_rem, rep, len(live_checks)))

print("---")
print("phases:", [(p.get("phase"), p.get("engineMatches"), p.get("shownMatches")) for p in probes])
sys.exit(1 if fails else 0)
EOF
RC=$?
[ $RC -eq 0 ] && echo "DICT BATTERY: ALL GREEN" || echo "DICT BATTERY: FAILURES PRESENT"
exit $RC
