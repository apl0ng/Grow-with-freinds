#!/usr/bin/env bash
# M10 physics multi-process suite (physics agent). Two stages:
#   1. physics_net_body.gd  - one process, three ENet peers in branches: a throw is one delta, every peer flies the
#                              same arc, a LATE joiner gets a mid-flight item through the spawn state, everyone lands
#                              at the same rest position.
#   2. physics_mp_body.gd   - host + client "a" (+ late client "late") as separate headless processes on the real
#                              game stack: the client throws through the real RPC and both peers land the item at the
#                              same rest position; the client shoves the host from behind while the host holds a can
#                              (the host stumbles and drops it, the client sees the stagger too); a late joiner sees an
#                              item at rest / a flight correctly.
#   tools/tests/physics_mp.sh               # port 7862
#   PHYS_PORT=8300 tools/tests/physics_mp.sh
# Logs: $PHYS_LOGS (default: a fresh temp dir). Fails if any process fails, has no RESULT line or logs an
# engine/script error its body did not announce ("(expected error next: ...)").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${PHYS_PORT:-7862}"
LOGS="${PHYS_LOGS:-$(mktemp -d -t physmp.XXXXXX)}"
mkdir -p "$LOGS"
rm -f "$LOGS"/phys_*.log
overall=0

count_errors() { # log -> number of unannounced ERROR / SCRIPT ERROR lines
  awk '/\(expected error next:/ {skip=1; next} /SCRIPT ERROR|^ERROR:/ {if (skip) {skip=0} else {n++}} END {print n+0}' "$1"
}

echo "== physics_net (one process, ENet branches)"
timeout 120 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/physics_net_body.gd \
  >"$LOGS/phys_net.log" 2>&1
code=$?
passes=$(grep -c "^  ok   -" "$LOGS/phys_net.log"); fails=$(grep -c "^  FAIL -" "$LOGS/phys_net.log"); errs=$(count_errors "$LOGS/phys_net.log")
printf '  %-8s exit=%-3s %3d passed %3d failed %2d errors\n' net "$code" "$passes" "$fails" "$errs"
grep "^  FAIL -" "$LOGS/phys_net.log" | sed 's/^/      /'
grep -A3 -E "SCRIPT ERROR|^ERROR:" "$LOGS/phys_net.log" | head -20 | sed 's/^/      /'
if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || $passes -eq 0 ]]; then overall=1; fi

echo "== physics_mp (port $PORT, logs $LOGS)"
PIDS=()
launch() { # name args...
  local name=$1; shift
  timeout 170 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- \
    --body=res://tools/tests/physics_mp_body.gd --port="$PORT" --round-sec=900 "$@" >"$LOGS/phys_$name.log" 2>&1 &
  PIDS+=("$!:$name")
}
wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    grep -q "^RESULT:" "$LOGS/phys_host.log" 2>/dev/null && return 1
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}
launch host --role=host --timeout=150
if wait_for_line "$LOGS/phys_host.log" PHYS_HOST_READY 30; then
  launch alpha --role=client --who=a --timeout=140
  if wait_for_line "$LOGS/phys_host.log" PHYS_LAUNCH_LATE 90; then
    launch late --role=client --who=late --timeout=90
  fi
else
  echo "  (host never became ready)"
fi
for entry in "${PIDS[@]}"; do
  pid=${entry%%:*}; name=${entry#*:}
  wait "$pid"; code=$?
  log="$LOGS/phys_$name.log"
  passes=$(grep -c "^  ok   -" "$log"); fails=$(grep -c "^  FAIL -" "$log")
  result=$(grep '^RESULT:' "$log" | tail -1)
  errs=$(count_errors "$log")
  printf '  %-8s exit=%-3s %3d passed %3d failed %2d errors   %s\n' "$name" "$code" "$passes" "$fails" "$errs" "${result:-NO RESULT LINE}"
  grep "^  FAIL -" "$log" | sed 's/^/      /'
  grep -A3 -E "SCRIPT ERROR|^ERROR:" "$log" | head -20 | sed 's/^/      /'
  if [[ $code -ne 0 || $fails -ne 0 || $errs -ne 0 || -z "$result" ]]; then overall=1; fi
done
[[ ${#PIDS[@]} -lt 3 ]] && { echo "  only ${#PIDS[@]}/3 processes were launched"; overall=1; }
echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "PHYSICS_MP: PASS"; else echo "PHYSICS_MP: FAIL"; fi
exit $overall
