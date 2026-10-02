#!/usr/bin/env bash
# M13 review of M12, multi-process: a host and a ROGUE client (a modified build) on the real ENet stack. The host
# launches the rogue process itself; both write to the same log. Scenario and assertions:
# tools/tests/review_m12_mp_body.gd (late join into a turning tray / a chase / a restocking cabinet / a flame / a head
# count, spoofed authority-only M12 broadcasts, fire requests, the cabinet, the short strain and the dry tank through
# the raw RPCs).
#   RM12_PORT=7964 tools/tests/review_m12_mp.sh
# Logs: $RM12_LOGS (default: a fresh temp dir). Fails if the run fails, has no RESULT line or logs an engine/script
# error that a body did not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${RM12_PORT:-7964}"
LOGS="${RM12_LOGS:-$(mktemp -d -t rm12.XXXXXX)}"
mkdir -p "$LOGS"
LOG="$LOGS/review_m12_mp.log"

echo "== review_m12_mp (host + rogue, port $PORT, logs $LOGS)"
timeout 170 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
  --body=res://tools/tests/review_m12_mp_body.gd --port="$PORT" --round-sec=900 --timeout=150 >"$LOG" 2>&1
code=$?
passes=$(grep -c "^  ok   -" "$LOG")
fails=$(grep -c "^  FAIL -" "$LOG")
result=$(grep '^RESULT:' "$LOG" | tail -1)
printf '  host exit=%-3s %3d passed %3d failed   %s\n' "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
grep "^  FAIL -\|^      error:" "$LOG" | sed 's/^/      /'
echo "logs: $LOGS"
if [[ $code -eq 0 && $fails -eq 0 && -n "$result" ]]; then echo "RM12_MP: PASS"; exit 0; fi
echo "RM12_MP: FAIL"; exit 1
