#!/usr/bin/env bash
# M15 alley multi-process suite (alley agent): host + client A (joins in the alley, throws the ball through the hoop)
# + client B (joins late, before shift 2: reads the counter and the board it never saw written). Every process runs
# with --lobby. Scenario and assertions: tools/tests/alley_mp_body.gd.
#   tools/tests/alley_mp.sh                    # port 7982
#   ALLEY_MP_PORT=8282 tools/tests/alley_mp.sh
# Logs: $ALLEY_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce, or if the three peers did not read the same LAST SHIFT lines
# off the board (each prints them as "ALLEY_BOARD: ...").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${ALLEY_MP_PORT:-7982}"
LOGS="${ALLEY_MP_LOGS:-$(mktemp -d -t alleymp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/alley_mp_*.log
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 200 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/alley_mp_body.gd --lobby --port="$PORT" --round-sec=900 "$@" >"$LOGS/alley_mp_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

wait_marker() { # marker file tries -> 0 when the marker showed up
  local marker=$1 file=$2 tries=$3
  for ((i = 0; i < tries; i++)); do
    grep -q "$marker" "$file" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

echo "== alley_mp (port $PORT, logs $LOGS)"
launch host --role=host --timeout=180
if wait_marker ALLEY_HOST_READY "$LOGS/alley_mp_host.log" 300; then
  launch a --role=a --timeout=170
  if wait_marker ALLEY_MP_SCORED "$LOGS/alley_mp_host.log" 1200; then
    launch b --role=b --timeout=120
  else
    echo "  (the counter never reached 2 in round 2 on the host)"
  fi
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/alley_mp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-4s exit=%-3s %3d passed %3d failed   %s\n' "$name" "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 3 ]] && { echo "  only ${#PIDS[@]}/3 processes were launched"; overall=1; }

# The board is the same on every peer: the three ALLEY_BOARD lines must be identical.
boards=$(grep -h '^ALLEY_BOARD: ' "$LOGS"/alley_mp_host.log "$LOGS"/alley_mp_a.log "$LOGS"/alley_mp_b.log 2>/dev/null | tr -d '\r')
board_count=$(printf '%s\n' "$boards" | grep -c '^ALLEY_BOARD: ')
board_kinds=$(printf '%s\n' "$boards" | grep '^ALLEY_BOARD: ' | sort -u | wc -l)
if [[ $board_count -eq 3 && $board_kinds -eq 1 ]]; then
  echo "  ok   - the three peers read the same board: ${boards%%$'\n'*}"
else
  echo "  FAIL - the peers did not read the same board ($board_count lines, $board_kinds different):"
  printf '%s\n' "$boards" | sed 's/^/      /'
  overall=1
fi
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "ALLEY_MP: PASS"; else echo "ALLEY_MP: FAIL"; fi
exit $overall
