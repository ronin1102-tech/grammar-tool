#!/bin/sh
# launcher.sh — boots and manages the local LanguageTool engine for LWA.
#
# Usage: launcher.sh [start|stop|status|restart|open]   (default: open)
#   open    double-click behavior: start if stopped, else state dialog
#
# LWA_HEADLESS=1  dialogs/notifications become log lines + exit codes
#                 (automated-test mode; never spawns osascript)
# LWA_CHOICE=...  answers the "already running" dialog in headless mode
#                 (stop | restart | ok)
# LWA_JAVA=...    override the java binary (test hook)
# LWA_PREFLIGHT_ONLY=1  run the start-path file/JDK checks, then exit 0
#                 without spawning the engine (test hook, launcher-battery.sh)
#
# Deliberately NO `set -e`: readiness polls and teardown probes fail on
# purpose during normal operation; every failure path is handled explicitly.
# See memory: "set -e discipline in daemon-launcher scripts".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${LWA_PORT:-8081}"
PIDFILE="$ROOT/data/engine.pid"
LOG="$ROOT/data/engine.log"
JAVA="${LWA_JAVA:-$HOME/jdks/jdk-17.0.20.1+1/Contents/Home/bin/java}"
ENGINE_JAR="$ROOT/engine/LanguageTool-6.6/languagetool-server.jar"
CONF="$ROOT/engine/server.properties"
URL="http://localhost:$PORT"

say() { # $1=message  $2(optional)=dialog|notify
  if [ "$LWA_HEADLESS" = "1" ]; then
    echo "LWA: $1"
  elif [ "$2" = "dialog" ]; then
    osascript -e "display dialog \"$1\" with title \"Local Writing Assistant\" buttons {\"OK\"} default button \"OK\"" >/dev/null 2>&1
  else
    osascript -e "display notification \"$1\" with title \"Local Writing Assistant\"" >/dev/null 2>&1
  fi
}

fail() { # $1=message — error path: dialog in GUI, line + exit 1 in headless
  if [ "$LWA_HEADLESS" = "1" ]; then
    echo "LWA-ERROR: $1"
  else
    osascript -e "display dialog \"$1\" with title \"Local Writing Assistant\" buttons {\"OK\"} default button \"OK\" with icon caution" >/dev/null 2>&1
  fi
  exit 1
}

# JRS probe (v1 spec §3.2): an unpatched Temurin JDK still carries
# JavaRuntimeSupport load commands in lib/*.dylib, which don't resolve on
# Catalina (the framework doesn't exist there; where it does, refs resolve
# and nothing needs patching). Needs otool (CommandLineTools — also what
# patch-jdk.sh needs); without CLT we skip the probe rather than trigger
# Apple's install prompt, and the died-during-startup path below still
# names patch-jdk.sh.
jdk_unpatched() {
  [ -e /System/Library/Frameworks/JavaRuntimeSupport.framework ] && return 1
  xcode-select -p >/dev/null 2>&1 || return 1
  LIBDIR="$(dirname "$JAVA")/../lib"
  for f in "$LIBDIR"/*.dylib; do
    [ -f "$f" ] || continue
    otool -L "$f" 2>/dev/null | grep -q JavaRuntimeSupport && return 0
  done
  return 1
}

is_up()      { [ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$URL/v2/languages" 2>/dev/null || echo 000)" = "200" ]; }
port_owner() { lsof -ti tcp:"$PORT" -sTCP:LISTEN 2>/dev/null; }
engine_pid() { p=$(cat "$PIDFILE" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; }

start() {
  if is_up; then say "Engine is already running."; exit 0; fi
  [ -x "$JAVA" ] || fail "Java not found at $JAVA — run scripts/fetch-engine.sh first (it downloads the JDK and patches it with scripts/patch-jdk.sh)."
  jdk_unpatched && fail "The JDK at $JAVA is not patched for this macOS — run: sh scripts/patch-jdk.sh $(cd "$(dirname "$JAVA")/.." && pwd)"
  [ -f "$ENGINE_JAR" ] || fail "Engine not found — run scripts/fetch-engine.sh first."
  [ -f "$CONF" ] || fail "Missing engine/server.properties."
  [ "$LWA_PREFLIGHT_ONLY" = "1" ] && { echo "LWA: preflight ok"; exit 0; }
  OWNER=$(port_owner)
  [ -n "$OWNER" ] && fail "Port $PORT is already in use by pid $OWNER (not ours). Quit it or change LWA_PORT."

  mkdir -p "$ROOT/data"
  # Keep the log bounded for daily use: past 1 MB, the previous log moves to
  # engine.log.1 (one generation kept) and this start begins a fresh file.
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi
  echo "=== $(date) — starting engine ===" >> "$LOG"
  nohup "$JAVA" -Djava.awt.headless=true -Xms256m -Xmx1g \
    -cp "$ENGINE_JAR" org.languagetool.server.HTTPServer \
    --config "$CONF" --port "$PORT" >> "$LOG" 2>&1 &
  PID=$!
  echo "$PID" > "$PIDFILE"
  disown 2>/dev/null

  i=0
  while [ $i -lt 240 ]; do
    if is_up; then
      # "Ready" must mean ready-to-CHECK, not ready-to-boot: the first check
      # pays one-time language-init (10s+ on this chip). Warm up now, and
      # verify a real check succeeds before announcing ready. If init is
      # still slow, retry — the engine is up either way, this only gates
      # the "ready" announcement.
      w=0
      while [ $w -lt 3 ]; do
        wcode=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 \
          --data-urlencode "text=warmup." --data-urlencode "language=en-US" \
          "$URL/v2/check" 2>/dev/null || echo 000)
        [ "$wcode" = "200" ] && break
        sleep 2; w=$((w+1))
      done
      if is_up; then say "Writing engine ready."; exit 0; fi
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      # dyld can't find JavaRuntimeSupport = unpatched JDK (probe skipped or missed).
      tail -n 20 "$LOG" | grep -q JavaRuntimeSupport && \
        fail "The JDK is not patched for this macOS (JavaRuntimeSupport missing) — run: sh scripts/patch-jdk.sh $(cd "$(dirname "$JAVA")/.." && pwd)"
      fail "Engine process died during startup. Last log lines:
$(tail -n 6 "$LOG" | cut -c1-160)"
    fi
    sleep 1; i=$((i+1))
  done
  fail "Engine did not become ready in 240s. Check $LOG"
}

stop() {
  PID=$(engine_pid)
  # Adopt an orphan of ours (e.g. a double-launch race left the pidfile stale):
  # only if the port owner's command line is our engine.
  if [ -z "$PID" ] && is_up; then
    for CAND in $(port_owner); do
      case "$(ps -o command= -p "$CAND" 2>/dev/null)" in
        *languagetool-server.jar*) PID=$CAND; break ;;
      esac
    done
  fi
  if [ -z "$PID" ] && ! is_up; then say "Engine is not running."; rm -f "$PIDFILE"; exit 0; fi
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  i=0
  while [ $i -lt 20 ]; do
    is_up || break
    sleep 0.5; i=$((i+1))
  done
  if is_up; then
    [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
    sleep 1
  fi
  rm -f "$PIDFILE"
  if is_up; then
    fail "Could not stop the engine on port $PORT. Quit it from Activity Monitor (look for \"java\", pid $(port_owner))."
  fi
  say "Engine stopped."
}

status() {
  PID=$(engine_pid)
  if [ -z "$PID" ] && is_up; then
    for CAND in $(port_owner); do
      case "$(ps -o command= -p "$CAND" 2>/dev/null)" in
        *languagetool-server.jar*) PID=$CAND; break ;;
      esac
    done
    [ -n "$PID" ] && { echo "running (untracked orphan, pid $PID)"; exit 0; }
  fi
  if [ -n "$PID" ]; then
    echo "running (pid $PID, started $(ps -o lstart= -p "$PID" 2>/dev/null))"
    exit 0
  fi
  echo "stopped"
  exit 1
}

open_flow() {
  if ! is_up; then start; exit 0; fi
  # Stale-launch guard: engine files newer than the running server started.
  if [ -n "$(find "$ROOT/engine" -type f -newer "$PIDFILE" -print -quit 2>/dev/null)" ]; then
    if [ "$LWA_HEADLESS" = "1" ]; then CHOICE="${LWA_CHOICE:-restart}"; else
      CHOICE=$(osascript -e 'display dialog "The engine was updated since it started. Restart to use the new version?" with title "Local Writing Assistant" buttons {"Stop", "Keep running", "Restart"} default button "Restart"' -e 'button returned of result' 2>/dev/null)
    fi
    case "$CHOICE" in
      restart|Restart) stop; start; exit 0 ;;
      stop|Stop) stop; exit 0 ;;
      *) say "Engine kept running (stale version)."; exit 0 ;;
    esac
  fi
  if [ "$LWA_HEADLESS" = "1" ]; then
    say "Engine is running (pid $(engine_pid))."; exit 0
  fi
  CHOICE=$(osascript -e "display dialog \"Writing engine is running.\" with title \"Local Writing Assistant\" buttons {\"Stop\", \"Restart\", \"OK\"} default button \"OK\"" -e 'button returned of result' 2>/dev/null)
  case "$CHOICE" in
    Stop) stop ;;
    Restart) stop; start ;;
    *) exit 0 ;;
  esac
}

case "${1:-open}" in
  start)   start ;;
  stop)    stop ;;
  status)  status ;;
  restart) stop; start ;;
  open)    open_flow ;;
  *) echo "usage: launcher.sh [start|stop|status|restart|open]"; exit 2 ;;
esac
