#!/usr/bin/env bash
# M18 spores multi-process suite (spores agent): a host and two clients as separate headless processes on the real game
# stack (tools/tests/spores_mp_body.gd), plain game. Alpha harvests a ripe Black Damp tray (the real request): the host
# fogs him and walks into the cloud itself; Alpha sees the cloud, his own grey screen and muffled Master bus, his own
# cough and the host's, the haze on the host. Both run out; the air clears on both peers. A second cloud hangs long;
# Bravo joins late and gets the cloud and who is fogged, then walks in himself. The end of the shift clears all three.
#   tools/tests/spores_mp.sh               # port 7939
#   SPORES_MP_PORT=9239 tools/tests/spores_mp.sh
# Logs: $SPORES_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error its body did not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${SPORES_MP_PORT:-7939}"
LOGS="${SPORES_MP_LOGS:-$(mktemp -d -t sporesmp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/spores_*.log
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

echo "== spores_mp (port $PORT, logs $LOGS)"
PIDS=()
launch() { # name args...
  local name=$1; shift
  timeout 200 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/spores_mp_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/spores_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}
wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    grep -q "^RESULT:" "$LOGS/spores_host.log" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}
launch host --role=host --timeout=180
if wait_for_line "$LOGS/spores_host.log" SPORES_HOST_READY 30; then
  launch alpha --role=client --who=a --timeout=170
  if wait_for_line "$LOGS/spores_host.log" SPORES_LATE_GO 120; then
    launch bravo --role=client --who=b --timeout=120
  else
    echo "  (the host never asked for the late joiner)"
  fi
else
  echo "  (host never became ready)"
fi
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/spores_$name.log"
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
if [[ $overall -eq 0 ]]; then echo "SPORES_MP: PASS"; else echo "SPORES_MP: FAIL"; fi
exit $overall
