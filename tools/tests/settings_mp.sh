#!/usr/bin/env bash
# M19 settings multi-process suite (settings agent): each player's settings stay on their own machine.
# tools/tests/settings_mp_body.gd in five headless processes on the real game stack:
#   seed host / seed client   write each side's settings into its own test file (user://settings_mp_<side>_<port>.cfg)
#   nofile                    no --settings-file: values are set and applied, nothing is ever written
#   host + client             start from those files: each reads its own at start and applies its own fov / mouse
#                             speed / invert to its own worker; a change on one side moves nothing on the other
#   tools/tests/settings_mp.sh                 # port 7915
#   SETTINGS_MP_PORT=9215 tools/tests/settings_mp.sh
# Logs: $SETTINGS_MP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error its body did not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
# The player's own user://settings.cfg is never read or written: every process but nofile has a --settings-file, and
# nofile keeps everything in memory.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${SETTINGS_MP_PORT:-7915}"
LOGS="${SETTINGS_MP_LOGS:-$(mktemp -d -t settingsmp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/settings_*.log
overall=0
HOST_FILE="user://settings_mp_host_$PORT.cfg"
CLIENT_FILE="user://settings_mp_client_$PORT.cfg"

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

echo "== settings_mp (port $PORT, logs $LOGS)"
PIDS=()
launch() { # name args...
  local name=$1; shift
  timeout 200 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/settings_mp_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/settings_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}
wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    grep -q "^RESULT:" "$1" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}
# Phase 1: the seeds (and the no-file run) side by side; the session waits for both seeds.
launch seed_host --role=seed --who=host --settings-file="$HOST_FILE" --timeout=60
launch seed_client --role=seed --who=client --settings-file="$CLIENT_FILE" --timeout=60
launch nofile --role=nofile --timeout=60
SEED_PIDS=("${PIDS[0]%%:*}" "${PIDS[1]%%:*}")
for pid in "${SEED_PIDS[@]}"; do wait "$pid"; done
# Phase 2: host and client from their files.
launch host --role=host --settings-file="$HOST_FILE" --timeout=150
if wait_for_line "$LOGS/settings_host.log" SETTINGS_HOST_READY 40; then
  launch client --role=client --settings-file="$CLIENT_FILE" --timeout=140
else
  echo "  (host never became ready)"
fi
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/settings_$name.log"
  passes=$(grep -c "^  ok   -" "$log"); fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  errs=$(count_errors "$log")
  printf '  %-12s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -" "$log" | sed 's/^/      /'
  [[ $errs -ne 0 ]] && grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 5 ]] && { echo "  only ${#PIDS[@]}/5 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "SETTINGS_MP: PASS"; else echo "SETTINGS_MP: FAIL"; fi
exit $overall
