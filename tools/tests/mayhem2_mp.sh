#!/usr/bin/env bash
# M15 mayhem2 multi-process suite (mayhem2 agent): host + client A (joins at once) + client B (joins DURING the
# raid). Scenario and assertions: tools/tests/mayhem2_mp_body.gd.
#   tools/tests/mayhem2_mp.sh                       # port 7978
#   MAYHEM2_MP_PORT=8200 tools/tests/mayhem2_mp.sh
# Logs: $MAYHEM2_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce ("(expected error next: ...)" / "(... tolerated next ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${MAYHEM2_MP_PORT:-7978}"
LOGS="${MAYHEM2_MP_LOGS:-$(mktemp -d -t mayhem2mp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/mayhem2_mp_*.log
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 200 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/mayhem2_mp_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/mayhem2_mp_$name.log" 2>&1 &
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

echo "== mayhem2_mp (port $PORT, logs $LOGS)"
launch host --role=host --timeout=180
if wait_marker MAYHEM2_HOST_READY "$LOGS/mayhem2_mp_host.log" 300; then
  launch a --role=a --timeout=170
  if wait_marker MAYHEM2_RAID "$LOGS/mayhem2_mp_host.log" 1500; then
    launch b --role=b --timeout=120
  else
    echo "  (the host never started the raid)"
  fi
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/mayhem2_mp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-4s exit=%-3s %3d passed %3d failed   %s\n' "$name" "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 3 ]] && { echo "  only ${#PIDS[@]}/3 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "MAYHEM2_MP: PASS"; else echo "MAYHEM2_MP: FAIL"; fi
exit $overall
