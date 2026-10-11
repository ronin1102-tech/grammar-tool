#!/bin/sh
# Phase 0 benchmark (final config): patched Temurin JDK 17 + LT 6.6 headless.
# Usage: bench-launch.sh <xmx>   e.g. bench-launch.sh 1g
JAVA="$HOME/jdks/jdk-17.0.20.1+1/Contents/Home/bin/java"
LT="/Users/onemoretimetrizzy/workspace/grammar-tool/engine/LanguageTool-6.6"
XMX="${1:-1g}"
PORT=8081
LOG="/tmp/lt-server-$XMX.log"

START=$(date +%s)
echo "$(date +%H:%M:%S) launching java -Xmx$XMX headless (port $PORT)"

nohup "$JAVA" -Djava.awt.headless=true -Xms256m -Xmx"$XMX" \
  -cp "$LT/languagetool-server.jar" org.languagetool.server.HTTPServer \
  --port "$PORT" >> "$LOG" 2>&1 &
PID=$!
echo "$PID" > /tmp/lt-server.pid
echo "pid=$PID"

i=0
while [ $i -lt 240 ]; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://localhost:$PORT/v2/languages" 2>/dev/null)
  if [ "$code" = "200" ]; then
    NOW=$(date +%s)
    echo "READY http200 after $((NOW-START))s (Xmx=$XMX)"
    exit 0
  fi
  kill -0 "$PID" 2>/dev/null || { echo "SERVER DIED (Xmx=$XMX)"; tail -5 "$LOG"; exit 1; }
  sleep 1
  i=$((i+1))
done
echo "TIMEOUT 240s (Xmx=$XMX)"; exit 1
