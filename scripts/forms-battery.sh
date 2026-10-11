#!/bin/sh
# forms-battery.sh — J6 battery: content-script extraction + secret guards.
# Usage: forms-battery.sh
#
# Runs the fixture page (served on 127.0.0.1:8083) in isolated headed Chrome;
# the in-page driver types into guarded and public fields; the SW's field-check
# evidence lands on the 8082 capture channel. Asserts T1–T6 from
# docs/extension-content-script.md.
#
# Preconditions handled here: engine started if down; fresh capture servers;
# fresh Chrome profile (SingletonLock lesson). Evidence channel is smoke-tested
# before use (J5 lesson: prove the channel before trusting assertions).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SCRATCH="$ROOT/tests/fixtures"
CAPDATA="/tmp/lwa-capture.jsonl"
SENTINEL="/tmp/lwa-forms-done"
BLOG="/tmp/lwa-forms-chrome.log"

# 0. Engine up (real operating condition).
if ! curl -s -o /dev/null --max-time 2 http://localhost:8081/v2/languages; then
  echo "engine down — starting via launcher…"
  LWA_HEADLESS=1 sh "$ROOT/scripts/launcher.sh" start || { echo "FAIL: engine would not start"; exit 1; }
fi

# 1. Capture server (8082) + smoke.
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
rm -f "$CAPDATA"
node /tmp/lwa-capture-server.js > /tmp/lwa-capture-server.log 2>&1 &
NODE1=$!
sleep 1
curl -s -X POST -d '{"smoke":true}' http://127.0.0.1:8082/capture -o /dev/null
grep -q smoke "$CAPDATA" 2>/dev/null || { echo "FAIL: capture channel dead"; kill $NODE1 2>/dev/null; exit 1; }
rm -f "$CAPDATA"

# 2. Fixture server (8083).
lsof -ti tcp:8083 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true; sleep 1
rm -f "$SENTINEL"
node "$SCRATCH/fixture-server.js" > /tmp/lwa-fixture-server.log 2>&1 &
NODE2=$!
sleep 1

# 3. Chrome (headed, fresh profile) → fixture with battery driver.
PROFILE="/tmp/lwa-forms-profile-$$"
rm -rf "$PROFILE"
"$CHROME" --load-extension="$ROOT/extension" --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=900,700 \
  "http://127.0.0.1:8083/?battery=1" > "$BLOG" 2>&1 &
CPID=$!

# 4. Wait for the sentinel (driver finished), then for evidence to land:
# the last fixture field (12k chars) takes the engine seconds to check; the
# sentinel only means the DRIVER finished. Wait for the huge-field capture
# (or a hard cap), then collect.
i=0
while [ $i -lt 45 ]; do
  [ -f "$SENTINEL" ] && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; i=$((i+1))
done
j=0
while [ $j -lt 15 ]; do
  grep -q '"field":"huge"' "$CAPDATA" 2>/dev/null && break
  kill -0 "$CPID" 2>/dev/null || break
  sleep 1; j=$((j+1))
done
kill "$CPID" 2>/dev/null || true; sleep 1; kill -9 "$CPID" 2>/dev/null || true
kill $NODE1 $NODE2 2>/dev/null || true
rm -rf "$PROFILE"

[ -f "$SENTINEL" ] || { echo "FAIL: fixture driver never finished (see $BLOG)"; exit 1; }

# 5. Assertions.
python3 - "$CAPDATA" <<'EOF'
import json, sys, os

path = sys.argv[1]
caps = []
raw = open(path, "rb").read().decode("utf-8", "replace") if os.path.exists(path) else ""
for line in raw.splitlines():
    line = line.strip()
    if line:
        try: caps.append(json.loads(line))
        except Exception: pass

fails = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (" — " + detail if detail and not cond else ""))
    if not cond: fails.append(name)

fields = [c.get("field") for c in caps if c.get("kind") == "field-check"]

# T1/T2: secret guards — nothing from pw/cc, and the secret values appear nowhere.
check("T1 password never sent", "pw" not in fields and "hunter2" not in raw)
check("T2 cc-number never sent", "cc" not in fields and "4111" not in raw)

pub = [c for c in caps if c.get("field") == "public"]
rich = [c for c in caps if c.get("field") == "rich"]
huge = [c for c in caps if c.get("field") == "huge"]

# T3: public textarea checked with working matches.
check("T3 textarea checked w/ matches",
      bool(pub) and max((c.get("matchesCount", 0) for c in pub), default=0) >= 2,
      "captures=%s" % [c.get("matchesCount") for c in pub])

# T4: contenteditable checked.
check("T4 contenteditable checked",
      bool(rich) and max((c.get("matchesCount", 0) for c in rich), default=0) >= 1,
      "captures=%s" % [c.get("matchesCount") for c in rich])

# T5: debounce — the 5-keystroke burst (parts 1..5) must yield exactly one
# capture, carrying the FINAL text.
p5 = [c for c in pub if "part 5" in (c.get("sample") or "")]
p14 = [c for c in pub if any(("part %d" % n) in (c.get("sample") or "") for n in (1, 2, 3, 4))]
check("T5 debounce collapses burst", len(p5) == 1 and len(p14) == 0,
      "part5=%d part1-4=%d" % (len(p5), len(p14)))

# T6: 10 000-char cap enforced before send.
check("T6 char cap (12000 -> 10000)",
      bool(huge) and huge[-1].get("textLength") == 10000,
      "huge textLength=%s" % [c.get("textLength") for c in huge])

print("---")
print("captures by field:", {f: fields.count(f) for f in set(fields)})
sys.exit(1 if fails else 0)
EOF
RC=$?
[ $RC -eq 0 ] && echo "FORMS BATTERY: ALL GREEN" || echo "FORMS BATTERY: FAILURES PRESENT"
exit $RC
