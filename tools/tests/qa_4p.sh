#!/usr/bin/env bash
# 4-player stress / desync test (QA milestone 7): 1 host + 3 clients (+ a refused 5th) as separate headless
# Godot processes on the real game stack. Scenario and assertions: tools/tests/qa_4p_body.gd.
#   tools/tests/qa_4p.sh              # base port 7950 (uses exactly that port)
#   QA4P_PORT=8123 tools/tests/qa_4p.sh
# Logs: $QA4P_LOGS (default: a fresh temp dir, printed at the end). Every process prints "ok   -" / "FAIL -"
# lines and a final "RESULT: PASS|FAIL ..." line; its exit code matches. This script fails if any process
# fails, is missing its RESULT line, or logs an engine/script error (the bodies also count them themselves).
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${QA4P_PORT:-7950}"
LOGS="${QA4P_LOGS:-$(mktemp -d -t qa4p.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/qa4p_*.log
COMMON=(--port="$PORT" --round-sec=900)
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 200 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/qa_4p_body.gd "${COMMON[@]}" "$@" >"$LOGS/qa4p_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    # Stop waiting if the host already finished (e.g. aborted).
    grep -q "^RESULT:" "$LOGS/qa4p_host.log" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}

echo "== qa_4p (port $PORT, logs $LOGS)"
launch host --role=host --timeout=180
if wait_for_line "$LOGS/qa4p_host.log" QA4P_HOST_READY 30; then
  launch alpha --role=client --who=a --timeout=180
  launch bravo --role=client --who=b --timeout=180
  if wait_for_line "$LOGS/qa4p_host.log" QA4P_LAUNCH_LATE 90; then
    launch charlie --role=client --who=c --timeout=150
    if wait_for_line "$LOGS/qa4p_host.log" QA4P_LAUNCH_FIFTH 60; then
      launch xtra --role=client --who=x --timeout=60
    fi
  fi
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/qa4p_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  # Engine/script errors not announced by the body as expected ("(expected error next: ...)").
  errs=$(awk '/\(expected error next:/ {skip=1; next} /SCRIPT ERROR|^ERROR:/ {if (skip) {skip=0} else {n++}} END {print n+0}' "$log")
  printf '  %-8s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -" "$log" | sed 's/^/      /'
  grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 5 ]] && { echo "  only ${#PIDS[@]}/5 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "QA4P: PASS"; else echo "QA4P: FAIL"; fi
exit $overall
