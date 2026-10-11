#!/bin/sh
# gmail-battery.sh — J8 battery: Gmail-class compose surface, G1–G5 per
# docs/extension-gmail.md. Rig discipline unchanged: capture smoke first,
# fresh profile, Chrome killed by PID, sentinel-then-evidence wait.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SCRATCH="$ROOT/tests/fixtures"
CAPDATA="/tmp/lwa-capture.jsonl"
SENTINEL="/tmp/lwa-forms-done"
REPORT="/tmp/lwa-driver-report.json"
BLOG="/tmp/lwa-gmail-chrome.log"

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
    req.on('end', () => { fs.appendFileSync('/tmp/lwa-capture.jsonl', b.trim() + '\n'); res.writeHead(204); res.end(); });
  } else { res.writeHead(404); res.end(); }
}).listen(8082, '127.0.0.1', () => console.log('capture up'));
EOF
rm -f "$CAPDATA" "$REPORT" "$SENTINEL"
node /tmp/lwa-capture-server.js > /tmp/lwa-capture-server.log 2>&1 &
NODE1=$!
sleep 1
curl -s -X POST -d '{"smoke":true}' http://127.0.0.1:8082/capture -o /dev/null
grep -q smoke "$CAPDATA" 2>/dev/null || { echo "FAIL: capture channel dead"; kill $NODE1 2>/dev/null; exit 1; }
rm -f "$CAPDATA"

lsof -ti tcp:8083 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1
node "$SCRATCH/fixture-server.js" > /tmp/lwa-fixture-server.log 2>&1 &
NODE2=$!
sleep 1

PROFILE="/tmp/lwa-gmail-profile-$$"
rm -rf "$PROFILE"
"$CHROME" --load-extension="$ROOT/extension" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=1100,800 \
  "http://127.0.0.1:8083/gmail?battery=1" > "$BLOG" 2>&1 &
CPID=$!

i=0
while [ $i -lt 45 ]; do
  [ -f "$SENTINEL" ] && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; i=$((i+1))
done
j=0
while [ $j -lt 10 ]; do
  grep -q '"kind":"apply"' "$CAPDATA" 2>/dev/null && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; j=$((j+1))
done
sleep 3
kill "$CPID" 2>/dev/null || true; sleep 1; kill -9 "$CPID" 2>/dev/null || true
kill $NODE1 $NODE2 2>/dev/null || true
rm -rf "$PROFILE"

[ -f "$SENTINEL" ] || { echo "FAIL: driver never finished (see $BLOG)"; exit 1; }

python3 - "$CAPDATA" "$REPORT" <<'EOF'
import json, sys, os

caps = []
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace") if os.path.exists(sys.argv[1]) else ""
for line in raw.splitlines():
    line = line.strip()
    if line:
        try: caps.append(json.loads(line))
        except Exception: pass
rep = {}
if os.path.exists(sys.argv[2]):
    try: rep = json.load(open(sys.argv[2]))
    except Exception: pass

if rep.get("driverError"):
    print("FAIL driver crashed: " + rep["driverError"][:300]); sys.exit(1)

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" — " + detail) if (detail and not cond) else ""))
    if not cond: fails.append(name)

fc = [c for c in caps if c.get("kind") == "field-check"]
ov = [c for c in caps if c.get("kind") == "overlay"]
ap = [c for c in caps if c.get("kind") == "apply"]

# G5 (checked first — G1's field name depends on the provider)
gfields = [c.get("field") for c in fc if str(c.get("field", "")).startswith("gmail-compose:")]
check("G5 field ids carry the gmail-compose label", bool(gfields), "fields=%s" % sorted(set(
    str(c.get("field")) for c in fc)))

gfc = [c for c in fc if str(c.get("field", "")).startswith("gmail-compose:")]
# G1: multi-paragraph body checked; textLength 87 = textContent concatenation
# of both paragraphs (innerText would give 103 with newline separators — we
# ship textContent semantics). 3 matches prove offsets span <p> and <br>.
check("G1 dialog body checked, cross-paragraph offsets",
      bool(gfc) and gfc[-1].get("textLength") == 87 and max((c.get("matchesCount", 0) for c in gfc), default=0) >= 2,
      "textLength=%s matches=%s" % ([c.get("textLength") for c in gfc], [c.get("matchesCount") for c in gfc]))

# G2: overlay rects inside the compose body box (±6px; bottom +40 grace)
gov = [c for c in ov if str(c.get("field", "")).startswith("gmail-compose:")]
fr = rep.get("bodyRect") or [0, 0, 0, 0]
inside = all(
    r[0] >= fr[0] - 6 and r[1] >= fr[1] - 6 and
    r[0] + r[2] <= fr[0] + fr[2] + 6 and r[1] + r[3] <= fr[1] + fr[3] + 40
    for c in gov for r in (c.get("rects") or [])
) if gov and fr != [0, 0, 0, 0] else False
check("G2 overlay rects inside compose body", bool(gov) and inside,
      "counts=%s bodyRect=%s" % ([c.get("count") for c in gov], fr))

# G3: click applied matches[0]; auto re-check carried corrected text
after_apply = rep.get("afterApply") or ""
rechecked = any(c.get("sample", "").startswith("There was a obvious") for c in gfc)
check("G3 click applies + auto re-check",
      rep.get("clicked") is True and after_apply.startswith("There was") and rechecked,
      "afterApply=%r recheck=%s" % (after_apply[:60], rechecked))

# G4: THE undo proof (J7's honest-untested item)
check("G4 undo restores original (correction on native undo stack)",
      rep.get("undoRestores") is True,
      "before=%r afterUndo=%r" % ((rep.get("before") or "")[:40], (rep.get("afterUndo") or "")[:40]))

# G6 (lifecycle): dialog removed -> bridge cleared
check("G6 dialog close clears overlay", rep.get("clearedAfterClose") is True,
      "rectsBeforeClose=%s" % rep.get("rectsBeforeClose"))

# privacy re-assert
check("privacy: password never captured", "hunter2-gmail" not in raw)

print("---")
print("kinds:", {k: sum(1 for c in caps if c.get("kind") == k) for k in set(c.get("kind") for c in caps)})
sys.exit(1 if fails else 0)
EOF
RC=$?
[ $RC -eq 0 ] && echo "GMAIL BATTERY: ALL GREEN" || echo "GMAIL BATTERY: FAILURES PRESENT"
exit $RC
