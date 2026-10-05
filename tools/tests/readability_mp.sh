#!/usr/bin/env bash
# M19 readability multi-process suite (readability agent): host + client A (joins at once) + client B (joins in the
# middle of the shift, after the costs were booked). Scenario and assertions: tools/tests/readability_mp_body.gd.
#   tools/tests/readability_mp.sh                       # port 7917
#   READABILITY_MP_PORT=8200 tools/tests/readability_mp.sh
# Logs: $READABILITY_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce, or if the three processes did not print the same report lines
# ("READ_LINES|...") and the same toasts after the burst ("READ_TOASTS|...").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${READABILITY_MP_PORT:-7917}"
LOGS="${READABILITY_MP_LOGS:-$(mktemp -d -t readabilitymp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/readability_mp_*.log
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 200 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/readability_mp_body.gd --port="$PORT" --events --round-sec=900 "$@" >"$LOGS/readability_mp_$name.log" 2>&1 &
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

echo "== readability_mp (port $PORT, logs $LOGS)"
launch host --role=host --timeout=180
if wait_marker READ_HOST_READY "$LOGS/readability_mp_host.log" 300; then
  launch a --role=a --timeout=170
  if wait_marker READ_COSTS "$LOGS/readability_mp_host.log" 1500; then
    launch b --role=b --timeout=120
  else
    echo "  (the host never booked the costs)"
  fi
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/readability_mp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-4s exit=%-3s %3d passed %3d failed   %s\n' "$name" "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 3 ]] && { echo "  only ${#PIDS[@]}/3 processes were launched"; overall=1; }

# The same report lines and the same toasts on every peer.
for tag in READ_LINES READ_TOASTS; do
  host_line=$(grep "^$tag|" "$LOGS/readability_mp_host.log" 2>/dev/null | tail -1 | tr -d '\r')
  for name in a b; do
    peer_line=$(grep "^$tag|" "$LOGS/readability_mp_$name.log" 2>/dev/null | tail -1 | tr -d '\r')
    if [[ -z "$host_line" || "$host_line" != "$peer_line" ]]; then
      echo "  $tag differs: host '$host_line' / $name '$peer_line'"
      overall=1
    else
      echo "  ok   - $tag: $name matches the host"
    fi
  done
done
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "READABILITY_MP: PASS"; else echo "READABILITY_MP: FAIL"; fi
exit $overall
