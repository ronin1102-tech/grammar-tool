#!/bin/sh
# patch-jdk.sh — make a Temurin 17 JDK/JRE run on macOS Catalina 10.15.
#
# Current Temurin builds ship several dylibs with load commands on
# JavaRuntimeSupport.framework, which does not exist on Catalina. The one on
# the LanguageTool server's load path (libawt.dylib) imports ZERO JRS symbols,
# so the reference is vestigial and safe to repoint (nm -u proves it — see
# docs/PHASE_0_VERIFICATION_AND_V1_SPEC.md §1.2). UI-path dylibs that DO use
# JRS symbols stay broken for GUI apps; LanguageTool server mode never loads
# them, and LT GUI mode is unsupported on Catalina by design.
#
# Usage:   patch-jdk.sh <jdk-Contents-Home>
# Example: patch-jdk.sh ~/jdks/jdk-17.0.20.1+1/Contents/Home
# Idempotent: re-running on a patched JDK is a no-op.
set -e

LIB="${1:?usage: patch-jdk.sh <jdk-Contents-Home>}/lib"
[ -d "$LIB" ] || { echo "FAIL: no lib directory at $LIB"; exit 1; }

JRS="/System/Library/Frameworks/JavaRuntimeSupport.framework/Versions/A/JavaRuntimeSupport"
PATCHED=0
for f in "$LIB"/*.dylib; do
  if otool -L "$f" | grep -q JavaRuntimeSupport; then
    install_name_tool -change "$JRS" "/usr/lib/libSystem.B.dylib" "$f"
    codesign -f -s - "$f" 2>/dev/null
    PATCHED=$((PATCHED + 1))
    echo "patched: $(basename "$f")"
  fi
done

# Verify: zero JRS load commands may remain anywhere in lib/
REMAINING=0
for f in "$LIB"/*.dylib; do
  otool -L "$f" | grep -q JavaRuntimeSupport && REMAINING=$((REMAINING + 1))
done
if [ "$REMAINING" -ne 0 ]; then
  echo "FAIL: $REMAINING dylib(s) in $LIB still reference JavaRuntimeSupport"
  exit 1
fi
echo "OK: $PATCHED dylib(s) patched, 0 JavaRuntimeSupport references remain in $LIB"
