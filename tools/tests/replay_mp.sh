#!/usr/bin/env bash
# M15 replay multi-process suite (replay agent): a host, one client that joins at once ("a", Alpha) and one that joins
# while the shift runs ("b", Bravo), as separate headless processes on the real game stack with --replay
# (tools/tests/replay_mp_body.gd). The host sets conditions and a market, then lets shift 2 roll its own: every peer
# must show the same conditions, market, chips, briefing, payment due and unlocks, the late joiner too; a client's
# deposit pays the market value on every peer; a locked strain asked for by a client is refused by the host; a
# cheaper seed is charged at the day's price.
#   tools/tests/replay_mp.sh                      # port 7984
#   REPLAY_MP_PORT=8284 tools/tests/replay_mp.sh
# Logs: $REPLAY_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error its body did not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${REPLAY_MP_PORT:-7984}"
LOGS="${REPLAY_MP_LOGS:-$(mktemp -d -t replaymp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/replay_mp_*.log
overall=0

count_errors() { # log -> number of unannounced ERROR / SCRIPT ERROR lines
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

echo "== replay_mp (port $PORT, logs $LOGS)"
PIDS=()
launch() { # name args...
  local name=$1; shift
  timeout 190 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/replay_mp_body.gd --port="$PORT" --replay --run=B5VP --round-sec=900 "$@" >"$LOGS/replay_mp_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}
wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    grep -q "^RESULT:" "$LOGS/replay_mp_host.log" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}
launch host --role=host --timeout=170
if wait_for_line "$LOGS/replay_mp_host.log" REPLAY_HOST_READY 30; then
  launch alpha --role=client --who=a --timeout=160
  if wait_for_line "$LOGS/replay_mp_host.log" REPLAY_SHIFT_RUNNING 90; then
    launch bravo --role=client --who=b --timeout=140
  else
    echo "  (the host never started the shift)"
  fi
else
  echo "  (host never became ready)"
fi
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/replay_mp_$name.log"
  passes=$(grep -c "^  ok   -" "$log"); fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  errs=$(count_errors "$log")
  printf '  %-8s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -" "$log" | sed 's/^/      /'
  [[ $errs -ne 0 ]] && grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 3 ]] && { echo "  only ${#PIDS[@]}/3 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "REPLAY_MP: PASS"; else echo "REPLAY_MP: FAIL"; fi
exit $overall
