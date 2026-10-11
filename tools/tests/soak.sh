#!/usr/bin/env bash
# M22 soak (soak agent, RELEASE.md R2, CONTRACTS "M22", "Soak"): a host and three clients as separate headless Godot
# processes play the chill game (--chill --replay --lobby --run=B5VP --events, each process with its own temp career
# and settings file) with scripted workers; with the proxy, Alpha and Bravo connect through tools/tests/udp_proxy.gd
# (80 ms +- 20 each way, 2% loss). Scenario and assertions: tools/tests/soak_body.gd.
#
#   tools/tests/soak.sh                                   # short mode (about 6 min), no proxy, port 7907
#   SOAK_PROXY=1 SOAK_PORT=7908 tools/tests/soak.sh       # short mode through the proxy (listens on SOAK_PORT + 1)
#   SOAK_MINUTES=45 tools/tests/soak.sh                   # long mode for the lead (proxy on unless SOAK_PROXY=0)
#
# Modes: short (SOAK_MINUTES unset or 0): one run of six shifts, --round-sec=35 --growth-mult=8, the events
#   compressed by the host body (first 8 s in, then every 10-16 s). Long (SOAK_MINUTES=N): runs back to back until
#   about N minutes are used, --round-sec=170 --growth-mult=3, the chill preset's own event timing; run 2 misses
#   shift 2 on purpose (START OVER).
# Knobs: SOAK_PORT (host port; default 7907), SOAK_PROXY (0 / 1), SOAK_SEED (bots and proxy dice, default 7),
#   SOAK_ROUND_SEC, SOAK_GROWTH, SOAK_DELAY_MS (80), SOAK_JITTER_MS (20), SOAK_LOSS (0.02), SOAK_LOGS (log dir).
#   SOAK_SELFTEST=desync: a watering can's charges are changed on Charlie's peer only at the first mid-shift checkpoint
#   (the checker must report it: that run FAILS on purpose; never in test_all).
# test_all.sh: soak = SOAK_PORT=$((BASE + 7)); soak_mp = SOAK_PORT=$((BASE + 8)) SOAK_PROXY=1 (the proxy takes +9).
# Fails if any process exits non-zero, fails a check, has no RESULT line, or logs an engine/script error its body did
# not announce ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)"), or if the proxy fails.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${SOAK_PORT:-7907}"
MINUTES="${SOAK_MINUTES:-0}"
SEED="${SOAK_SEED:-7}"
if [[ "$MINUTES" == "0" ]]; then
  PROXY="${SOAK_PROXY:-0}"
  ROUND="${SOAK_ROUND_SEC:-35}"
  GROWTH="${SOAK_GROWTH:-8}"
  TMO=720
else
  PROXY="${SOAK_PROXY:-1}"
  ROUND="${SOAK_ROUND_SEC:-170}"
  GROWTH="${SOAK_GROWTH:-3}"
  TMO=$((MINUTES * 60 + 1500))
fi
PROXY_PORT=$((PORT + 1))
LOGS="${SOAK_LOGS:-$(mktemp -d -t soak.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/soak_*.log "$LOGS"/proxy.quit
QUIT_FILE="$LOGS/proxy.quit"
GODOT_QUIT_FILE="$QUIT_FILE"
command -v cygpath >/dev/null 2>&1 && GODOT_QUIT_FILE="$(cygpath -m "$QUIT_FILE")"
JOIN_AB=$PORT
[[ "$PROXY" == "1" ]] && JOIN_AB=$PROXY_PORT
COMMON=(--port="$PORT" --chill --replay --lobby --run=B5VP --events --round-sec="$ROUND" --growth-mult="$GROWTH"
  --soak-minutes="$MINUTES" --seed="$SEED" --timeout=$((TMO - 30)))
PIDS=()
PROXY_PID=""

launch() { # name args...
  local name=$1; shift
  timeout "$TMO" "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/soak_body.gd \
    "${COMMON[@]}" --career-file="user://soak_career_${name}_${PORT}.cfg" --settings-file="user://soak_settings_${name}_${PORT}.cfg" \
    "$@" >"$LOGS/soak_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

wait_marker() { # marker file seconds -> 0 when the marker showed up
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$1" "$2" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

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

MODE="short"; [[ "$MINUTES" != "0" ]] && MODE="long ($MINUTES min)"
echo "== soak: $MODE, port $PORT, proxy $([[ "$PROXY" == "1" ]] && echo "on (port $PROXY_PORT, ${SOAK_DELAY_MS:-80} ms +- ${SOAK_JITTER_MS:-20}, loss ${SOAK_LOSS:-0.02})" || echo off), round ${ROUND} s, growth x${GROWTH}, logs $LOGS"
T0=$(date +%s)
if [[ "$PROXY" == "1" ]]; then
  timeout "$TMO" "$GODOT" --headless --path . -s res://tools/tests/udp_proxy.gd -- --listen="$PROXY_PORT" --host=127.0.0.1:"$PORT" \
    --delay-ms="${SOAK_DELAY_MS:-80}" --jitter-ms="${SOAK_JITTER_MS:-20}" --loss="${SOAK_LOSS:-0.02}" --seed="$SEED" \
    --max-sec=$((TMO - 10)) --quit-file="$GODOT_QUIT_FILE" --stats-sec=60 >"$LOGS/soak_proxy.log" 2>&1 &
  PROXY_PID=$!
  if ! wait_marker UDP_PROXY_READY "$LOGS/soak_proxy.log" 30; then
    echo "  (the proxy never became ready)"
  fi
fi
launch host --role=host
if wait_marker SOAK_HOST_READY "$LOGS/soak_host.log" 60; then
  launch alpha --role=client --who=a --join-port="$JOIN_AB"
  launch bravo --role=client --who=b --join-port="$JOIN_AB"
  launch charlie --role=client --who=c --join-port="$PORT" ${SOAK_SELFTEST:+--soak-selftest="$SOAK_SELFTEST"}
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/soak_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  errs=$(count_errors "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  printf '  %-8s exit=%-3s %4d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | head -40 | sed 's/^/      /'
  [[ $errs -ne 0 ]] && grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -24 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 4 ]] && { echo "  only ${#PIDS[@]}/4 game processes were launched"; overall=1; }
if [[ -n "$PROXY_PID" ]]; then
  touch "$QUIT_FILE"
  wait "$PROXY_PID"; pcode=$?
  perrs=$(count_errors "$LOGS/soak_proxy.log")
  printf '  %-8s exit=%-3s %2d errors   %s\n' proxy "$pcode" "$perrs" "$(grep '^UDP_PROXY_DONE' "$LOGS/soak_proxy.log" | tail -1)"
  if [[ $pcode -ne 0 || $perrs -ne 0 ]]; then overall=1; fi
fi
grep -h "^SOAK_SUMMARY" "$LOGS/soak_host.log" 2>/dev/null | sed 's/^/  /'
grep -hE "^SOAK: .*(old peer left|back in the menu)" "$LOGS"/soak_*.log 2>/dev/null | sed 's/^/  /'
echo "  wall clock: $(( $(date +%s) - T0 )) s"
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "SOAK: PASS"; else echo "SOAK: FAIL"; fi
exit $overall
