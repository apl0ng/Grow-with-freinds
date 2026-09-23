#!/usr/bin/env bash
# Multi-process robustness test (QA milestone 7): host + Alpha + Bravo + an unregistered "Ghost" peer.
# Scenario and assertions: tools/tests/qa_mp_robust_body.gd.
#   tools/tests/qa_mp_robust.sh                 # port 7980
#   QAMP_PORT=8200 tools/tests/qa_mp_robust.sh
# Logs: $QAMP_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error that its body did not announce ("(expected error next: ...)" / "(... tolerated next ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${QAMP_PORT:-7980}"
LOGS="${QAMP_LOGS:-$(mktemp -d -t qamp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/qamp_*.log
PIDS=()

launch() { # name args...
  local name=$1; shift
  timeout 150 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/qa_mp_robust_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/qamp_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

echo "== qa_mp_robust (port $PORT, logs $LOGS)"
launch host --role=host --timeout=120
for ((i = 0; i < 300; i++)); do
  grep -q QAMP_HOST_READY "$LOGS/qamp_host.log" 2>/dev/null && break
  sleep 0.1
done
if grep -q QAMP_HOST_READY "$LOGS/qamp_host.log" 2>/dev/null; then
  launch alpha --role=client --who=a --timeout=110
  launch bravo --role=client --who=b --timeout=110
  launch ghost --role=client --who=u --timeout=60
else
  echo "  (host never became ready)"
fi

overall=0
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/qamp_$name.log"
  passes=$(grep -c "^  ok   -" "$log")
  fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  # Error lines are announced by the bodies; the bodies' own logger decides (unexpected ones fail the RESULT).
  errs=$(grep -cE "SCRIPT ERROR|^ERROR:" "$log")
  printf '  %-6s exit=%-3s %3d passed %3d failed %2d error lines (announced/tolerated by the body)   %s\n' \
    "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -\|^      error:" "$log" | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 4 ]] && { echo "  only ${#PIDS[@]}/4 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "QAMP: PASS"; else echo "QAMP: FAIL"; fi
exit $overall
