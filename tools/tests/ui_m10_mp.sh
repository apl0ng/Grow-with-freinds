#!/usr/bin/env bash
# M10 ui two-process suite: chat + pings between a host and a client (tools/tests/ui_m10_mp_{host,client}.gd).
#   tools/tests/ui_m10_mp.sh [port]        (default port 7862; env UI_M10_PORT overrides; logs in $UI_M10_LOGS or a temp dir)
# Both logs are echoed in full so a runner (tools/test_all.sh) can count "  ok   -" / "FAIL" lines and scan for
# unannounced ERROR lines. Exit 0 only if both processes pass.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${UI_M10_PORT:-${1:-7862}}"
LOGS="${UI_M10_LOGS:-$(mktemp -d -t ui_m10_mp.XXXXXX)}"
mkdir -p "$LOGS"
BODY=(-s res://tools/tests/run_test.gd --)

echo "=== ui_m10_mp: host + client on port $PORT (logs: $LOGS)"
timeout 150 "$GODOT" --headless --path . "${BODY[@]}" --body=res://tools/tests/ui_m10_mp_host.gd --port="$PORT" --timeout=120 \
  >"$LOGS/ui_m10_mp_host.log" 2>&1 &
hpid=$!
sleep 3
timeout 150 "$GODOT" --headless --path . "${BODY[@]}" --body=res://tools/tests/ui_m10_mp_client.gd --port="$PORT" --timeout=120 \
  >"$LOGS/ui_m10_mp_client.log" 2>&1
crc=$?
wait $hpid; hrc=$?
echo "--- host log"; cat "$LOGS/ui_m10_mp_host.log"
echo "--- client log"; cat "$LOGS/ui_m10_mp_client.log"
if [[ $hrc -ne 0 || $crc -ne 0 ]]; then echo "ui_m10_mp: FAIL (host exit $hrc, client exit $crc)"; exit 1; fi
echo "ui_m10_mp: PASS (host exit $hrc, client exit $crc)"
