#!/usr/bin/env bash
# M11 review of M10, multi-process: a host and a ROGUE client (a modified build) on the real ENet stack. The host
# picks a random port and launches the rogue process itself; both write to the same log. Scenario and assertions:
# tools/tests/review_m10_mp_body.gd (spoofed owner / cosmetic RPCs, authority-only broadcasts, voice / chat / ping
# floods, the back-room cheat over the wire).
#   tools/tests/review_m10_mp.sh
# Logs: $RM10_LOGS (default: a fresh temp dir). Fails if the run fails, has no RESULT line or logs an engine/script
# error that a body did not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
LOGS="${RM10_LOGS:-$(mktemp -d -t rm10.XXXXXX)}"
mkdir -p "$LOGS"
LOG="$LOGS/review_m10_mp.log"

echo "== review_m10_mp (host + rogue, random port, logs $LOGS)"
timeout 150 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
  --body=res://tools/tests/review_m10_mp_body.gd --round-sec=900 --timeout=130 >"$LOG" 2>&1
code=$?
passes=$(grep -c "^  ok   -" "$LOG")
fails=$(grep -c "^  FAIL -" "$LOG")
result=$(grep '^RESULT:' "$LOG" | tail -1)
printf '  host exit=%-3s %3d passed %3d failed   %s\n' "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
grep "^  FAIL -\|^      error:" "$LOG" | sed 's/^/      /'
echo "logs: $LOGS"
if [[ $code -eq 0 && $fails -eq 0 && -n "$result" ]]; then echo "RM10_MP: PASS"; exit 0; fi
echo "RM10_MP: FAIL"; exit 1
