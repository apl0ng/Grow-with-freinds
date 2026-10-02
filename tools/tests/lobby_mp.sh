#!/usr/bin/env bash
# M14 lobby multi-process suite (lobby agent): host + clients A and B (join in the alley) + client C (joins DURING the
# first shift). Every process runs with --lobby. Scenario and assertions: tools/tests/lobby_mp_body.gd.
#   tools/tests/lobby_mp.sh                    # port 7967
#   LOBBY_MP_PORT=8267 tools/tests/lobby_mp.sh
# Logs: $LOBBY_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce ("(expected error next: ...)" / "(... tolerated next ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${LOBBY_MP_PORT:-7967}"
LOGS="${LOBBY_MP_LOGS:-$(mktemp -d -t lobbymp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/lobby_mp_*.log
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 170 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/lobby_mp_body.gd --lobby --port="$PORT" --round-sec=900 "$@" >"$LOGS/lobby_mp_$name.log" 2>&1 &
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

echo "== lobby_mp (port $PORT, logs $LOGS)"
launch host --role=host --timeout=150
if wait_marker LOBBY_HOST_READY "$LOGS/lobby_mp_host.log" 300; then
  launch a --role=a --timeout=140
  launch b --role=b --timeout=140
  if wait_marker LOBBY_MP_PLAYING "$LOGS/lobby_mp_host.log" 600; then
    launch c --role=c --timeout=120
  else
    echo "  (the van never left: no first shift on the host)"
  fi
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/lobby_mp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-4s exit=%-3s %3d passed %3d failed   %s\n' "$name" "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 4 ]] && { echo "  only ${#PIDS[@]}/4 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "LOBBY_MP: PASS"; else echo "LOBBY_MP: FAIL"; fi
exit $overall
