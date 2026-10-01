#!/usr/bin/env bash
# M12 hostile multi-process suite (hostile agent): host + client A. Scenario and assertions: tools/tests/hostile_mp_body.gd
# (the client sees the hostile node appear and move, gets bitten, sees the death).
#   tools/tests/hostile_mp.sh                    # port 7956
#   HOSTILE_MP_PORT=8300 tools/tests/hostile_mp.sh
# Logs: $HOSTILE_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce ("(expected error next: ...)" / "(... tolerated next ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${HOSTILE_MP_PORT:-7956}"
LOGS="${HOSTILE_MP_LOGS:-$(mktemp -d -t hostilemp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/hostile_mp_*.log
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 150 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/hostile_mp_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/hostile_mp_$name.log" 2>&1 &
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

count_errors() { # log -> number of unannounced ERROR / SCRIPT ERROR lines (same rule as tools/test_all.sh)
  awk '
    /\(expected error next:/ { budget++; next }
    /error\(s\) tolerated next:/ {
      cnt = 0; if (match($0, /up to [0-9]+/)) cnt = substr($0, RSTART + 6, RLENGTH - 6)
      s = $0; sub(/.*tolerated next: /, "", s); sub(/(, engine-only)?\)[[:space:]]*$/, "", s)
      ntol++; tsub[ntol] = s; tcnt[ntol] = cnt; next
    }
    /SCRIPT ERROR|^ERROR:/ {
      if (budget > 0) { budget--; next }
      hit = 0
      for (i = 1; i <= ntol; i++) if (tcnt[i] > 0 && index($0, tsub[i]) > 0) { tcnt[i]--; hit = 1; break }
      if (hit) next
      n++
    }
    END { print n + 0 }' "$1"
}

echo "== hostile_mp (port $PORT, logs $LOGS)"
launch host --role=host --timeout=130
if wait_marker HOSTILE_HOST_READY "$LOGS/hostile_mp_host.log" 300; then
  launch a --role=a --timeout=120
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/hostile_mp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  errs=$(count_errors "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-4s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  [[ $errs -ne 0 ]] && grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 2 ]] && { echo "  only ${#PIDS[@]}/2 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "HOSTILE_MP: PASS"; else echo "HOSTILE_MP: FAIL"; fi
exit $overall
