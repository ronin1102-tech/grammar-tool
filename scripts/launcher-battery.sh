#!/bin/sh
# launcher-battery.sh — J12 battery: launcher failure UX for the JDK (v1 spec
# §3.2: "JDK missing/unpatched → dialog pointing at scripts/patch-jdk.sh").
#
#   L1  unpatched JDK (fresh extract of the cached Temurin tarball — the real
#       thing, never patched) → preflight fails naming patch-jdk.sh
#   L2  the patched JDK in ~/jdks passes the same preflight (positive control)
#   L3  JDK that dies at boot with the dyld JavaRuntimeSupport error (probe
#       skipped/missed) → died-during-startup path names patch-jdk.sh
#   L4  JDK missing → message names fetch-engine.sh and patch-jdk.sh
#
# Uses the launcher's test hooks only (LWA_HEADLESS, LWA_JAVA, LWA_PORT,
# LWA_PREFLIGHT_ONLY). Runs on a spare port so a running daily engine on 8081
# is never touched; data/engine.pid is saved and restored around L3.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/scripts/launcher.sh"
JDK_VERSION="jdk-17.0.20.1+1"
JDK_TGZ="$HOME/jdks/temurin17-jdk.tar.gz"
PATCHED_JAVA="$HOME/jdks/$JDK_VERSION/Contents/Home/bin/java"
TMP="/tmp/lwa-launcher-battery-$$"
PORT=8091
FAILS=0

check() { # $1=name $2=0|1 (pass?) $3=detail
  if [ "$2" = "1" ]; then echo "PASS $1"; else echo "FAIL $1 — $3"; FAILS=$((FAILS + 1)); fi
}
run() { # env-prefixed launcher start; prints output, sets RC
  OUT=$(env LWA_HEADLESS=1 LWA_PORT=$PORT "$@" sh "$L" start 2>&1); RC=$?
}

rm -rf "$TMP"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

if lsof -ti tcp:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: spare port $PORT is in use — free it first"; exit 1
fi

# L1: unpatched JDK
if [ -e /System/Library/Frameworks/JavaRuntimeSupport.framework ]; then
  echo "SKIP L1 — this macOS ships JavaRuntimeSupport; nothing to patch here"
elif ! xcode-select -p >/dev/null 2>&1; then
  echo "SKIP L1 — no CommandLineTools (otool); probe is skipped by design, L3 covers it"
elif [ ! -f "$JDK_TGZ" ]; then
  check "L1 unpatched JDK names patch-jdk.sh" 0 "no cached tarball at $JDK_TGZ (run scripts/fetch-engine.sh)"
else
  tar xzf "$JDK_TGZ" -C "$TMP"
  run LWA_JAVA="$TMP/$JDK_VERSION/Contents/Home/bin/java" LWA_PREFLIGHT_ONLY=1
  case "$OUT" in *patch-jdk.sh*) ok=1 ;; *) ok=0 ;; esac
  [ $RC -eq 1 ] || ok=0
  check "L1 unpatched JDK names patch-jdk.sh" $ok "rc=$RC out=$OUT"
fi

# L2: patched JDK passes preflight (positive control — no engine spawned)
run LWA_JAVA="$PATCHED_JAVA" LWA_PREFLIGHT_ONLY=1
case "$OUT" in *"preflight ok"*) ok=1 ;; *) ok=0 ;; esac
[ $RC -eq 0 ] || ok=0
check "L2 patched JDK passes preflight" $ok "rc=$RC out=$OUT"

# L3: JDK dies at boot with the dyld JRS error (simulated binary, no dylibs
# for the probe to see) → post-mortem names patch-jdk.sh
mkdir -p "$TMP/fake/Contents/Home/bin" "$TMP/fake/Contents/Home/lib"
cat > "$TMP/fake/Contents/Home/bin/java" <<'EOF'
#!/bin/sh
echo "dyld: Library not loaded: /System/Library/Frameworks/JavaRuntimeSupport.framework/Versions/A/JavaRuntimeSupport" >&2
exit 1
EOF
chmod +x "$TMP/fake/Contents/Home/bin/java"
[ -f "$ROOT/data/engine.pid" ] && cp "$ROOT/data/engine.pid" "$TMP/engine.pid.bak"
run LWA_JAVA="$TMP/fake/Contents/Home/bin/java"
if [ -f "$TMP/engine.pid.bak" ]; then cp "$TMP/engine.pid.bak" "$ROOT/data/engine.pid"; else rm -f "$ROOT/data/engine.pid"; fi
case "$OUT" in *patch-jdk.sh*) ok=1 ;; *) ok=0 ;; esac
[ $RC -eq 1 ] || ok=0
check "L3 JRS death at boot names patch-jdk.sh" $ok "rc=$RC out=$OUT"

# L4: JDK missing
run LWA_JAVA="$TMP/nonexistent/bin/java"
case "$OUT" in *fetch-engine.sh*patch-jdk.sh*) ok=1 ;; *) ok=0 ;; esac
[ $RC -eq 1 ] || ok=0
check "L4 missing JDK names fetch-engine.sh + patch-jdk.sh" $ok "rc=$RC out=$OUT"

echo "---"
[ $FAILS -eq 0 ] && echo "LAUNCHER BATTERY: ALL GREEN" || echo "LAUNCHER BATTERY: FAILURES PRESENT"
[ $FAILS -eq 0 ]
