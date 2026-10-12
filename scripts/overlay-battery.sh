#!/bin/sh
# overlay-battery.sh — J7 battery: underlines + one-click apply, O1–O7 per
# docs/extension-overlay.md (O6/O7 = J12 S2-2, per-field overlay state). Same rig discipline as forms-battery.sh:
# capture channel smoke-tested first, fresh profile, Chrome killed by PID,
# sentinel-then-evidence wait (a click that lands means nothing if the
# re-check evidence hasn't landed yet).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SCRATCH="$ROOT/tests/fixtures"
CAPDATA="/tmp/lwa-capture.jsonl"
SENTINEL="/tmp/lwa-forms-done"
REPORT="/tmp/lwa-driver-report.json"
BLOG="/tmp/lwa-overlay-chrome.log"

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

PROFILE="/tmp/lwa-overlay-profile-$$"
rm -rf "$PROFILE"
"$CHROME" --load-extension="$ROOT/extension" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=900,700 \
  "http://127.0.0.1:8083/?battery=1" > "$BLOG" 2>&1 &
CPID=$!

i=0
while [ $i -lt 45 ]; do
  [ -f "$SENTINEL" ] && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; i=$((i+1))
done
# sentinel-then-evidence: wait for the post-click re-check of the rich field
j=0
while [ $j -lt 15 ]; do
  grep -q '"kind":"apply"' "$CAPDATA" 2>/dev/null && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; j=$((j+1))
done
# Post-apply: apply fires input -> 700ms debounce -> engine -> evidence.
# Give that whole chain room to land before collecting.
sleep 5
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

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ((" — " + detail) if (detail and not cond) else ""))
    if not cond: fails.append(name)

ov = [c for c in caps if c.get("kind") == "overlay"]
ap = [c for c in caps if c.get("kind") == "apply"]
pub_checks = [c for c in caps if c.get("kind") == "field-check" and c.get("field") == "public"]

# O1: overlays rendered on the public textarea; rects inside the field box (±6px)
pub_ov = [c for c in ov if c.get("field") == "public"]
fr = rep.get("publicFieldRect") or [0, 0, 0, 0]
counts = [c.get("count", 0) for c in pub_ov]
inside = all(
    r[0] >= fr[0] - 6 and r[1] >= fr[1] - 6 and
    r[0] + r[2] <= fr[0] + fr[2] + 6 and r[1] + r[3] <= fr[1] + fr[3] + 40
    for c in pub_ov for r in (c.get("rects") or [])
) if pub_ov and fr != [0, 0, 0, 0] else False
# First render carries the full match set (>=2); the post-apply re-render must
# carry exactly one fewer — the applied underline is GONE, the rest remain.
check("O1 overlays render on textarea, inside field bounds",
      bool(counts) and counts[0] >= 2 and counts[-1] == counts[0] - 1 and inside,
      "counts=%s fieldRect=%s" % (counts, fr))

# O2: DOM bridge live on both field types (driver read data-lwa-rects)
check("O2 dataset bridge on textarea + contenteditable",
      rep.get("publicRects", 0) >= 1 and rep.get("richRects", 0) >= 1,
      "driver saw public=%s rich=%s" % (rep.get("publicRects"), rep.get("richRects")))

# O3: click on textarea underline applied replacements[0] and re-checked
pa = rep.get("publicAfter", "")
check("O3 textarea apply + auto re-check",
      pa.startswith("There was") and
      any(a.get("field") == "public" for a in ap) and
      any(c.get("sample", "").startswith("There was") for c in pub_checks),
      "publicAfter=%r" % pa[:60])

# O4: contenteditable apply — click hits matches[0]; LT ordered "a obvious"
# before "exmaple" in run-3 evidence, so expect the a→an apply at the head.
ra = rep.get("richAfter", "")
check("O4 contenteditable apply", ra.startswith("This is an ") and ra != "This is a exmaple of rich text.",
      "richAfter=%r" % ra[:60])

# O5: privacy regression — password value appears nowhere
check("O5 password still never captured", "hunter2-secret" not in raw)

if rep.get("driverError"):
    check("driver ran", False, rep["driverError"][:300])

# O6 (J12 S2-2): checking rich did not wipe public — bars DRAWN over both
# fields at once (driver counts layer bars, not the bridge, which can go stale)
both = rep.get("bothLive") or {}
pub_bridge = len(json.loads(rep.get("pubBeforeRichApply") or "[]"))
check("O6 two fields underlined simultaneously",
      both.get("public", 0) >= 1 and both.get("rich", 0) >= 1 and both.get("public") == pub_bridge,
      "bars=%s public bridge=%s" % (both, pub_bridge))

# O7 (J12 S2-2): apply in rich left public's underlines intact (bars + bridge)
check("O7 apply in one field leaves the other's underlines intact",
      rep.get("pubBeforeRichApply", "[]") != "[]" and
      rep.get("pubAfterRichApply") == rep.get("pubBeforeRichApply") and
      both.get("public", 0) >= 1 and rep.get("pubBarsAfterRichApply") == both.get("public"),
      "bridge before=%s after=%s bars before=%s after=%s" % (rep.get("pubBeforeRichApply"), rep.get("pubAfterRichApply"),
                                                             both.get("public"), rep.get("pubBarsAfterRichApply")))

print("---")
print("kinds:", {k: sum(1 for c in caps if c.get("kind") == k) for k in set(c.get("kind") for c in caps)})
sys.exit(1 if fails else 0)
EOF
RC=$?
[ $RC -eq 0 ] && echo "OVERLAY BATTERY: ALL GREEN" || echo "OVERLAY BATTERY: FAILURES PRESENT"
exit $RC
