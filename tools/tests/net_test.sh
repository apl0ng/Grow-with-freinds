#!/usr/bin/env bash
# Headless multi-process network tests for Net / Game / World / Player (owner: net/player agent).
#   tools/tests/net_test.sh            # all scenarios
#   tools/tests/net_test.sh pair trio  # a subset: solo | pair | trio | full | drop | nohost
# Each Godot process prints PASS:/FAIL: lines and "RESULT: PASS|FAIL"; its exit code matches.
# Logs are kept in $NET_TEST_LOGS (default: a temp dir, printed at the end).
# NET_TEST_ISOLATED=1: every process strips other systems' runtime nodes (Room/Stations, HUD) right after the
#   world is created, and ANY error from the multiplayer module fails the run (strict attribution).
# Default (full world, integration): fails on errors located in net/player files, or multiplayer-module errors
#   that name the Player's synced properties / spawner; other systems' errors are listed as warnings.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
BASE_PORT="${NET_TEST_PORT:-7799}"
LOGS="${NET_TEST_LOGS:-$(mktemp -d)}"
mkdir -p "$LOGS"
SCENARIOS=("$@")
[[ ${#SCENARIOS[@]} -eq 0 ]] && SCENARIOS=(solo pair trio full drop nohost)
overall=0
PIDS=()

launch() { # name script args...
  local name=$1 script=$2; shift 2
  local extra=()
  [[ "${NET_TEST_ISOLATED:-0}" == "1" ]] && extra=(--isolated)
  timeout 100 "$GODOT" --headless --path . -s "res://tools/tests/$script" -- "$@" "${extra[@]}" >"$LOGS/$name.log" 2>&1 &
  PIDS+=("$!:$name")
}

wait_for_line() { # file pattern seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "  (timed out waiting for '$2' in $(basename "$1"))"
  return 1
}

collect() { # waits for every launched process and reports
  local entry pid name code
  for entry in "${PIDS[@]}"; do
    pid=${entry%%:*}; name=${entry#*:}
    wait "$pid"; code=$?
    local passes fails result
    passes=$(grep -c '^PASS:' "$LOGS/$name.log")
    fails=$(grep -c '^FAIL:' "$LOGS/$name.log")
    result=$(grep '^RESULT:' "$LOGS/$name.log" | tail -1)
    printf '  %-14s exit=%-3s %3d passed %3d failed   %s\n' "$name" "$code" "$passes" "$fails" "${result:-NO RESULT LINE}"
    grep '^FAIL:' "$LOGS/$name.log" | sed 's/^/      /'
    # Engine/script errors: listed (deduplicated) always. Attribution uses only each error's "at:" location
    # line, never the backtrace (other systems' parse errors surface while Game loads the world).
    local summary mine
    summary=$(awk '/SCRIPT ERROR|^ERROR:/ {msg=$0; getline; sub(/^[ \t]+/, "", $0); print msg "  <" $0 ">"}' "$LOGS/$name.log" \
      | grep -vE 'at exit|RID allocations|Couldn.t create an ENet host|enet_connection\.cpp|enet_multiplayer_peer\.cpp' | sort | uniq -c | sort -rn || true)
    if [[ -n "$summary" ]]; then
      echo "      engine/script errors in $name.log (count, message <location>):"
      echo "$summary" | head -15 | cut -c1-200 | sed 's/^/        /'
      mine=$(echo "$summary" | grep -E '<at: .*res://(scripts/core/(net|game)\.gd|scripts/player/|scenes/player/|scenes/world/world\.|scenes/main_menu/|tools/tests/net_)' || true)
      if [[ "${NET_TEST_ISOLATED:-0}" == "1" ]]; then
        mine+=$(echo "$summary" | grep -E '<at: .*modules/multiplayer/' || true)
      else
        mine+=$(echo "$summary" | grep -E '<at: .*modules/multiplayer/' | grep -E 'net_position|net_yaw|net_pitch|crouching|Players|PlayerSpawner' || true)
      fi
      if [[ -n "$mine" ]]; then
        echo "      ^ errors attributed to net/player code -> FAIL"; code=1
      fi
    fi
    [[ $code -ne 0 || $fails -ne 0 || -z "$result" ]] && overall=1
  done
  PIDS=()
}

port=$BASE_PORT
for sc in "${SCENARIOS[@]}"; do
  port=$((port + 2))
  echo "== $sc (port $port)"
  case $sc in
    solo)
      launch solo net_solo.gd --port=$port
      ;;
    pair)
      launch pair_host net_host.gd --port=$port --scenario=pair
      wait_for_line "$LOGS/pair_host.log" HOST_READY 30 && launch pair_client net_client.gd --port=$port --scenario=pair --who=a
      ;;
    trio)
      launch trio_host net_host.gd --port=$port --scenario=trio
      wait_for_line "$LOGS/trio_host.log" HOST_READY 30 && launch trio_a net_client.gd --port=$port --scenario=trio --who=a
      wait_for_line "$LOGS/trio_a.log" A_READY 40 && launch trio_b net_client.gd --port=$port --scenario=trio --who=b
      ;;
    full)
      launch full_host net_host.gd --port=$port --scenario=full
      wait_for_line "$LOGS/full_host.log" HOST_READY 30 && launch full_idle net_client.gd --port=$port --scenario=full --who=idle
      wait_for_line "$LOGS/full_idle.log" A_READY 40 && launch full_reject net_client.gd --port=$port --scenario=full --who=reject
      ;;
    drop)
      launch drop_host net_host.gd --port=$port --scenario=drop
      wait_for_line "$LOGS/drop_host.log" HOST_READY 30 && launch drop_client net_client.gd --port=$port --scenario=drop --who=a
      ;;
    nohost)
      launch nohost_client net_client.gd --port=$port --scenario=nohost --who=nohost
      ;;
    *) echo "unknown scenario $sc"; overall=1 ;;
  esac
  collect
done

echo "logs: $LOGS"
if [[ $overall -eq 0 ]]; then echo "NET TEST: PASS"; else echo "NET TEST: FAIL"; fi
exit $overall
