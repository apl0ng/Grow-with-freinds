#!/usr/bin/env bash
# Check only specific files (scripts/scenes/resources), e.g.
#   tools/check_files.sh res://scripts/stations/grow_plot.gd res://scenes/stations/grow_plot.tscn
# Rebuild the class_name cache first if you added a new class_name:  godot --headless --path . --import
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
LOG="$(mktemp)"
timeout 300 "$GODOT" --headless --path . -s res://tools/check_all.gd -- "$@" >"$LOG" 2>&1
grep -E "check_all|FAIL" "$LOG"
if grep -qE "SCRIPT ERROR|ERROR:|Parse Error|failures: [1-9]" "$LOG"; then
  echo "-- errors:"; grep -E -A3 "SCRIPT ERROR|ERROR:|Parse Error" "$LOG" | head -60; rm -f "$LOG"; echo "CHECK FAILED"; exit 1
fi
rm -f "$LOG"; echo "CHECK OK"
