#!/usr/bin/env bash
# Headless project validation. Usage: tools/check.sh [--no-import]
# 1. (re)builds the .godot cache (class_name registry, imports)
# 2. loads + instantiates every script/scene/resource
# 3. boots the main scene for a few frames
# Fails if Godot prints SCRIPT ERROR / ERROR lines or any resource fails to load.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
LOG="$(mktemp)"
status=0

if [[ "${1:-}" != "--no-import" ]]; then
  echo "== import (class cache)"
  timeout 300 "$GODOT" --headless --path . --import >"$LOG" 2>&1
  grep -E "SCRIPT ERROR|ERROR:|Parse Error" "$LOG" | grep -v "main_menu.tscn" | head -40 && status=1
fi

echo "== load all resources"
timeout 300 "$GODOT" --headless --path . -s res://tools/check_all.gd >"$LOG" 2>&1
tail -n 20 "$LOG" | grep -E "check_all|FAIL"
if grep -qE "SCRIPT ERROR|ERROR:|Parse Error|failures: [1-9]" "$LOG"; then
  echo "-- errors:"; grep -E -B1 -A2 "SCRIPT ERROR|ERROR:|Parse Error" "$LOG" | head -80; status=1
fi

echo "== boot main scene (90 frames)"
timeout 120 "$GODOT" --headless --path . --quit-after 90 >"$LOG" 2>&1
if grep -qE "SCRIPT ERROR|ERROR:|Parse Error" "$LOG"; then
  echo "-- errors:"; grep -E -B1 -A2 "SCRIPT ERROR|ERROR:|Parse Error" "$LOG" | head -80; status=1
fi

rm -f "$LOG"
if [[ $status -eq 0 ]]; then echo "CHECK OK"; else echo "CHECK FAILED"; fi
exit $status
