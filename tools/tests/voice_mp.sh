#!/usr/bin/env bash
# Two-process voice test (M10, voice agent): a headless host and client exchange real voice frames over ENet.
# The client talks first (the host must see speaking_changed(client, true/false)), then the host talks back.
#   tools/tests/voice_mp.sh                       # port VOICE_MP_PORT (default 7845)
#   VOICE_MP_LOGS=dir tools/tests/voice_mp.sh     # keep the two logs there (default: a temp dir, printed)
#   VOICE_MP_ARGS=--throttle-off ...              # extra user args for both bodies (diagnostic: no ENet throttle drops)
# Exit code 0 only when both processes exit 0 (each prints "[voice_host|voice_client] N passed, M failed -> PASS").
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
PORT="${VOICE_MP_PORT:-7845}"
LOGS="${VOICE_MP_LOGS:-$(mktemp -d)}"
EXTRA="${VOICE_MP_ARGS:-}"
mkdir -p "$LOGS"
RUN=(-s res://tools/tests/run_test.gd --)

# shellcheck disable=SC2086
timeout 120 "$GODOT" --headless --path . "${RUN[@]}" --body=res://tools/tests/voice_mp_host.gd --port="$PORT" $EXTRA \
  >"$LOGS/voice_host.log" 2>&1 &
hpid=$!
for ((i = 0; i < 300; i++)); do
  grep -q "HOST_READY" "$LOGS/voice_host.log" 2>/dev/null && break
  sleep 0.1
done
# shellcheck disable=SC2086
timeout 120 "$GODOT" --headless --path . "${RUN[@]}" --body=res://tools/tests/voice_mp_client.gd --port="$PORT" $EXTRA \
  >"$LOGS/voice_client.log" 2>&1
crc=$?
wait "$hpid"; hrc=$?

echo "--- host log"; grep -E "^\[|ok   -|FAIL|SCRIPT ERROR|ERROR:" "$LOGS/voice_host.log"
echo "--- client log"; grep -E "^\[|ok   -|FAIL|SCRIPT ERROR|ERROR:" "$LOGS/voice_client.log"
echo "logs: $LOGS"
if [[ $hrc -eq 0 && $crc -eq 0 ]]; then
  echo "VOICE MP: PASS"; exit 0
fi
echo "VOICE MP: FAIL (host=$hrc client=$crc)"; exit 1
