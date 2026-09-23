#!/usr/bin/env bash
# End-to-end smoke tests. Usage: tools/smoke.sh [solo|mp|all]  (default all)
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
mode="${1:-all}"
status=0

run_solo() {
  echo "=== SOLO smoke"
  timeout 240 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/smoke_solo.gd --port=7801 2>&1 | tee /tmp/smoke_solo.log | grep -E "^\[|ok   -|FAIL|SCRIPT ERROR|ERROR:" 
  if ! grep -q "> PASS" /tmp/smoke_solo.log; then echo "SOLO FAILED"; status=1; else echo "SOLO PASS"; fi
}
run_mp() {
  echo "=== HOST+CLIENT smoke"
  timeout 300 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/smoke_host.gd --port=7802 >/tmp/smoke_host.log 2>&1 &
  hpid=$!
  sleep 3
  timeout 300 "$GODOT" --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/smoke_client.gd --port=7802 >/tmp/smoke_client.log 2>&1
  crc=$?
  wait $hpid; hrc=$?
  echo "--- host log"; grep -E "^\[|ok   -|FAIL|SCRIPT ERROR|ERROR:" /tmp/smoke_host.log
  echo "--- client log"; grep -E "^\[|ok   -|FAIL|SCRIPT ERROR|ERROR:" /tmp/smoke_client.log
  if [[ $hrc -ne 0 || $crc -ne 0 ]]; then echo "MP FAILED (host=$hrc client=$crc)"; status=1; else echo "MP PASS"; fi
}
case "$mode" in
  solo) run_solo ;;
  mp) run_mp ;;
  *) run_solo; run_mp ;;
esac
exit $status
