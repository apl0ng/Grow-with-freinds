#!/usr/bin/env bash
# Review 9.1 multi-process regression suite: first host H, client A (re-hosts later), late joiner B.
# Scenario and assertions: tools/tests/review_core_mp_body.gd (steps handshaked through marker files).
#   tools/tests/review_core_mp.sh                  # ports 7990 and 7991
#   RCMP_PORT=8200 tools/tests/review_core_mp.sh
# Logs: $RCMP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${RCMP_PORT:-7990}"
LOGS="${RCMP_LOGS:-$(mktemp -d -t rcmp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/rcmp_*.log
SYNC=$(mktemp -d -t rcmp_sync.XXXXXX)
trap 'rm -rf "$SYNC"' EXIT
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 150 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/review_core_mp_body.gd --port="$PORT" --sync-dir="$SYNC" --round-sec=900 --timeout=130 "$@" \
    >"$LOGS/rcmp_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

echo "== review_core_mp (ports $PORT/$((PORT + 1)), logs $LOGS)"
launch h --role=h
launch a --role=a
launch b --role=b

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/rcmp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-3s exit=%-3s %3d passed %3d failed   %s\n' "$name" "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]]; then overall=1; fi
done
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "RCMP: PASS"; else echo "RCMP: FAIL"; fi
exit $overall
