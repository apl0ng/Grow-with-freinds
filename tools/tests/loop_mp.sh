#!/usr/bin/env bash
# M14 loop multi-process suite (loop agent): a host and one client ("a", Alpha) as separate headless processes on the
# real game stack (tools/tests/loop_mp_body.gd). Alpha hangs a bundle on a drying rack through the real Interactable
# RPC; both peers watch `dry_left` fall and the bundle cure; Alpha takes it and deposits it: both see the cured bonus
# and STAT_CURED. Then a bundle taken off early (the remainder synced, the plain value) and a rack the host filled
# ("Rack is full." on the client).
#   tools/tests/loop_mp.sh                 # port 7976
#   LOOP_PORT=8300 tools/tests/loop_mp.sh
# Logs: $LOOP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error its body did not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${LOOP_PORT:-7976}"
LOGS="${LOOP_LOGS:-$(mktemp -d -t loopmp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/loop_*.log
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

echo "== loop_mp (port $PORT, logs $LOGS)"
PIDS=()
launch() { # name args...
  local name=$1; shift
  timeout 170 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/loop_mp_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/loop_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}
wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    grep -q "^RESULT:" "$LOGS/loop_host.log" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}
launch host --role=host --timeout=150
if wait_for_line "$LOGS/loop_host.log" LOOP_HOST_READY 30; then
  launch alpha --role=client --who=a --timeout=140
else
  echo "  (host never became ready)"
fi
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/loop_$name.log"
  passes=$(grep -c "^  ok   -" "$log"); fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  errs=$(count_errors "$log")
  printf '  %-8s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -" "$log" | sed 's/^/      /'
  [[ $errs -ne 0 ]] && grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 2 ]] && { echo "  only ${#PIDS[@]}/2 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "LOOP_MP: PASS"; else echo "LOOP_MP: FAIL"; fi
exit $overall
