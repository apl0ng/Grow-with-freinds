#!/usr/bin/env bash
# M12 QA (milestone M13): 4-player stress sweep of what M12 added (strains that turn, the hostile plant, the
# emergency cabinet + flamethrower, head count / water off / shortage) on the real game stack: 1 host + 3 clients as
# separate headless Godot processes (Charlie is launched LATE, in the middle of the chase). Scenarios and assertions:
# tools/tests/qa_m12_4p_body.gd (mutation under load, the chase with a back-room stay, a late join and a disconnect,
# fire, events on top, RETRY / a fresh host on the same port / a short scheduled shift / the host leaving).
#   tools/tests/qa_m12_4p.sh                 # port 7965 (uses exactly that port)
#   QA_M12_PORT=8123 QA_M12_LOGS=/tmp/qa_m12 tools/tests/qa_m12_4p.sh
# Logs: $QA_M12_LOGS (default: a fresh temp dir, printed at the end). Every process prints "ok   -" / "FAIL -" lines
# and a final "RESULT: PASS|FAIL ..." line; its exit code matches. This script fails if any process fails, is
# missing its RESULT line, or logs an engine/script error its body did not announce.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${QA_M12_PORT:-7965}"
LOGS="${QA_M12_LOGS:-$(mktemp -d -t qam12.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/qam12_*.log
# --events: the scheduler is allowed (the host body pushes its delays out of reach until the scheduled shift).
COMMON=(--port="$PORT" --round-sec=900 --events)
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 270 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/qa_m12_4p_body.gd "${COMMON[@]}" "$@" >"$LOGS/qam12_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    grep -q "^RESULT:" "$LOGS/qam12_host.log" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}

echo "== qa_m12_4p (port $PORT, logs $LOGS)"
launch host --role=host --timeout=250
if wait_for_line "$LOGS/qam12_host.log" QAM12_HOST_READY 30; then
  launch alpha --role=client --who=a --timeout=250
  launch bravo --role=client --who=b --timeout=250
  if wait_for_line "$LOGS/qam12_host.log" QAM12_LAUNCH_LATE 120; then
    launch charlie --role=client --who=c --timeout=230
  fi
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/qam12_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  # Engine/script errors not announced by the body ("(expected error next: ...)" / "(up to N error(s) tolerated next: ...)").
  errs=$(awk '
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
      if (!hit) n++
    }
    END { print n + 0 }' "$log")
  printf '  %-8s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  [[ $errs -ne 0 ]] && grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 4 ]] && { echo "  only ${#PIDS[@]}/4 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "QAM12: PASS"; else echo "QAM12: FAIL"; fi
exit $overall
