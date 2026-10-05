#!/usr/bin/env bash
# tools/test_all.sh - unified headless test runner (QA milestone 7).
#
#   tools/test_all.sh                        run everything (about 3 minutes on 4 cores)
#   tools/test_all.sh --only qa_4p,smoke     run a subset (names from --list)
#   tools/test_all.sh --list                 list the suites in run order
#   GODOT=/path/to/godot QA_BASE_PORT=8100 TEST_ALL_LOGS=/tmp/mylogs tools/test_all.sh
#
# Order: tools/check.sh -> single-process suites -> multi-process suites -> tools/smoke.sh -> QA suites.
# Ports: multi-process suites get unique UDP ports from QA_BASE_PORT (default 7900): econ_mp +11, net_test
#   +21..+32, qa_robust +71, qa_solo +72, qa_mouse_x11 +73, qa_4p +50, qa_m10_4p +52, qa_mp_robust +80, review_core +74,
#   review_core_mp +95/+96, review_core_slots +97. A base whose ports are already bound
#   (e.g. by a leftover process) is skipped in steps of 100. smoke.sh keeps its fixed 7801/7802; the
#   self-spawning suites (items_net/items_e2e/farm_net/farm_world/flow_mp/econ_test) pick random ports.
# Leftovers: every suite runs in its own session (setsid) under `timeout`; afterwards any process still in that
#   session is killed (pkill -s), so only processes this runner started are ever touched.
# Result per suite: passed / failed = "PASS..." or "  ok   -" lines vs "FAIL..." lines over every process log,
#   seconds, and ERROR / SCRIPT ERROR lines that the test did not announce right before with
#   "(expected error next: ...)" or "(up to N error(s) tolerated next: ...)". Any unannounced error line, a
#   failed check, a non-zero exit or zero passed checks fails the suite.
#   Not counted: "WARNING: N ObjectDB instances were leaked at exit" (engine warning about the Sfx autoload's
#   generated AudioStreamWAV objects at shutdown; harmless).
# qa_mouse_x11 needs a real display server (headless always reads MOUSE_MODE_VISIBLE): it runs under xvfb-run
#   (software GL, Dummy audio) and is reported as SKIP when xvfb-run is not installed.
# Exit code 0 only if every suite passed. Logs: $TEST_ALL_LOGS (default: a fresh temp dir, printed at the end).
set -u
cd "$(dirname "$0")/.."
export GODOT="${GODOT:-godot}"
LOGDIR="${TEST_ALL_LOGS:-$(mktemp -d -t test_all.XXXXXX)}"
mkdir -p "$LOGDIR"
# setsid + pkill -s isolate every suite in its own session on Linux; Git Bash (Windows) has neither, so the runner
# degrades to plain background jobs there (M10 lead).
HAVE_SETSID=0
if command -v setsid >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1; then HAVE_SETSID=1; fi

ALL_SUITES=(check art_test models_test models_station_test models_item_test models_props_test models_env_test models_arch_test models_char_test models_plant_test world_test items_test items_test_minimal farm_test econ_test flow_test items_net_test items_e2e_test
  farm_net_test farm_world_test flow_mp_test econ_mp_test net_test smoke qa_robust qa_solo qa_4p qa_mp_robust
  review_play_mp review_ui review_core review_core_mp review_core_slots review_viewmodel discipline lan firewall voice_test voice_mp physics physics_mp ui_m10 ui_m10_mp events events_mp hostile hostile_mp strains flame flame_mp disrupt disrupt_mp
  review_m10 review_m10_mp review_m12 review_m12_mp qa_m10_4p qa_m12_4p lobby lobby_mp mayhem mayhem_mp loop loop_mp level alley alley_mp
  replay replay_off replay_mp mayhem2 mayhem2_mp career career_mp economy polish variety variety_mp
  hats hats_mp finale finale_mp mayhem3 mayhem3_mp cart cart_mp quit
  radio radio_mp emotes emotes_mp spores spores_mp
  settings settings_mp
  qa_mouse_x11)

ONLY=""
case "${1:-}" in
  --list) printf '%s\n' "${ALL_SUITES[@]}"; exit 0 ;;
  --only) ONLY=",${2:-},"; ;;
  "") ;;
  *) echo "usage: tools/test_all.sh [--list | --only name1,name2]"; exit 2 ;;
esac

# --- ports -----------------------------------------------------------------------------------------------------
port_busy() { # port -> 0 if some UDP socket is bound to it
  local hex; hex=$(printf ':%04X ' "$1")
  grep -qi "$hex" /proc/net/udp /proc/net/udp6 2>/dev/null
}
BASE="${QA_BASE_PORT:-7900}"
for attempt in 1 2 3 4 5; do
  busy=0
  for off in 11 14 15 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87 88 89 90 91 92 93 94 95 96 98 99; do
    if port_busy $((BASE + off)); then busy=1; break; fi
  done
  [[ $busy -eq 0 ]] && break
  echo "note: UDP port $((BASE + off)) is in use (leftover process?), moving the port base from $BASE to $((BASE + 100))"
  BASE=$((BASE + 100))
done
for p in 7801 7802; do port_busy $p && echo "warning: UDP port $p (tools/smoke.sh) is in use; the smoke suite may fail"; done

# --- runner ------------------------------------------------------------------------------------------------------
# Suites run in their own session, so Ctrl-C would not reach them: stop the running one explicitly.
CURRENT_SID=""
on_interrupt() {
  echo; echo "test_all: interrupted, stopping the running suite"
  if [[ -n "$CURRENT_SID" ]]; then pkill -TERM -s "$CURRENT_SID" 2>/dev/null; sleep 1; pkill -KILL -s "$CURRENT_SID" 2>/dev/null; fi
  exit 130
}
trap on_interrupt INT TERM
ROWS=()
OVERALL=0
TOTAL_P=0; TOTAL_F=0; TOTAL_E=0
T_ALL0=$(date +%s.%N)

# count_errors file... -> prints the number of unannounced error lines, writes them to $LOGDIR/<suite>.errors
count_errors() {
  # "(expected error next: ...)" covers the next error line; "(up to N error(s) tolerated next: SUBSTR[, engine-only])"
  # covers up to N later error lines that contain SUBSTR.
  awk -v out="$ERRFILE" '
    FNR == 1 { budget = 0; ntol = 0 }
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
      n++; print FILENAME ": " $0 >> out; getline nxt; print "      " nxt >> out
    }
    END { print n + 0 }' "$@"
}

# run_suite name timeout_sec count_glob command...
#   count_glob: "" = count / scan the suite's own output; otherwise a glob of per-process logs to use instead.
run_suite() {
  local name=$1 tmo=$2 glob=$3; shift 3
  if [[ -n "$ONLY" && "$ONLY" != *",$name,"* ]]; then return; fi
  local log="$LOGDIR/$name.log"
  ERRFILE="$LOGDIR/$name.errors"
  rm -f "$ERRFILE"
  printf '== %-20s ' "$name"
  local t0 t1 rc sid
  t0=$(date +%s.%N)
  if [[ $HAVE_SETSID -eq 1 ]]; then
    setsid timeout -k 10 "$tmo" "$@" >"$log" 2>&1 </dev/null &
  else
    # Git Bash on Windows has no setsid / session ids: run in our own session, no leftover sweep.
    timeout -k 10 "$tmo" "$@" >"$log" 2>&1 </dev/null &
  fi
  sid=$!
  CURRENT_SID=$sid
  wait "$sid"; rc=$?
  CURRENT_SID=""
  t1=$(date +%s.%N)
  # Anything this suite left behind (it is in our session): TERM, then KILL.
  if [[ $HAVE_SETSID -eq 1 ]] && pgrep -s "$sid" >/dev/null 2>&1; then
    echo -n "(cleaning up leftovers: $(pgrep -s "$sid" -l | awk '{print $2}' | sort | uniq -c | xargs)) "
    pkill -TERM -s "$sid" 2>/dev/null; sleep 1; pkill -KILL -s "$sid" 2>/dev/null
  fi
  local files=("$log")
  if [[ -n "$glob" ]]; then
    # shellcheck disable=SC2206
    files=($glob)
  fi
  local passed failed errors
  if [[ "$name" == "check" ]]; then
    local loaded fails_n
    loaded=$(grep -oE 'loaded [0-9]+ resources' "$log" | grep -oE '[0-9]+' | head -1)
    fails_n=$(grep -oE 'loaded [0-9]+ resources, [0-9]+ failures' "$log" | grep -oE '[0-9]+ failures' | grep -oE '[0-9]+' | head -1)
    passed=$(( ${loaded:-0} - ${fails_n:-0} ))
    failed=$(( ${fails_n:-0} + $(grep -c "CHECK FAILED" "$log") ))
  elif grep -qE '^[a-z_]+: ([0-9]+ models, )?[0-9]+ checks, [0-9]+ failures' "$log"; then
    # Suites that print "<name>: N checks, M failures" (art_test, models_*_test)
    local summary
    summary=$(grep -oE '^[a-z_]+: ([0-9]+ models, )?[0-9]+ checks, [0-9]+ failures' "$log" | tail -1)
    local checks fails_a
    checks=$(echo "$summary" | grep -oE '[0-9]+ checks' | grep -oE '[0-9]+')
    fails_a=$(echo "$summary" | grep -oE '[0-9]+ failures' | grep -oE '[0-9]+')
    passed=$(( ${checks:-0} - ${fails_a:-0} ))
    failed=$(( ${fails_a:-0} + $(grep -cE '^\s*FAIL\b' "$log") ))
  else
    passed=$(cat "${files[@]}" 2>/dev/null | grep -cE '^\s*(PASS\b|ok   -)')
    failed=$(cat "${files[@]}" 2>/dev/null | grep -cE '^\s*FAIL\b')
  fi
  errors=$(count_errors "${files[@]}" 2>/dev/null)
  errors=${errors:-0}
  local secs result="PASS"
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  if [[ $rc -ne 0 || $failed -ne 0 || $errors -ne 0 || $passed -eq 0 ]]; then result="FAIL"; OVERALL=1; fi
  [[ $rc -eq 124 || $rc -eq 137 ]] && result="TIMEOUT" && OVERALL=1
  echo "$result (exit $rc, ${secs}s)"
  if [[ "$result" != "PASS" ]]; then
    cat "${files[@]}" 2>/dev/null | grep -E '^\s*FAIL\b' | head -15 | sed 's/^/     /'
    [[ -s "$ERRFILE" ]] && head -20 "$ERRFILE" | sed 's/^/     /'
  fi
  ROWS+=("$(printf '%-20s %7d %7d %7d %8s  %s' "$name" "$passed" "$failed" "$errors" "$secs" "$result")")
  TOTAL_P=$((TOTAL_P + passed)); TOTAL_F=$((TOTAL_F + failed)); TOTAL_E=$((TOTAL_E + errors))
}

G=(env "$GODOT" --headless --path .)
TESTS=res://tools/tests
BODY=(-s res://tools/tests/run_test.gd --)

# econ_mp_test needs a host and a client process (commands from the econ_mp_test.gd header).
econ_mp() {
  local port=$1
  "$GODOT" --headless --path . -s res://tools/tests/econ_mp_test.gd -- --econ-role=host --econ-port="$port" \
    >"$LOGDIR/econ_mp_host.log" 2>&1 &
  local hp=$!
  sleep 1.5
  "$GODOT" --headless --path . -s res://tools/tests/econ_mp_test.gd -- --econ-role=client --econ-port="$port" \
    >"$LOGDIR/econ_mp_client.log" 2>&1
  local crc=$?
  wait $hp; local hrc=$?
  echo "econ_mp_test: host exit $hrc, client exit $crc"
  [[ $hrc -eq 0 && $crc -eq 0 ]]
}
export -f econ_mp
export LOGDIR

echo "test_all: logs in $LOGDIR, port base $BASE"
run_suite check           420 "" tools/check.sh
run_suite art_test        120 "" "${G[@]}" -s $TESTS/art_test.gd
run_suite models_test     180 "" "${G[@]}" -s $TESTS/models_test.gd
run_suite models_station_test 120 "" "${G[@]}" -s $TESTS/models_station_test.gd
run_suite models_item_test 120 "" "${G[@]}" -s $TESTS/models_item_test.gd
run_suite models_props_test 120 "" "${G[@]}" -s $TESTS/models_props_test.gd
run_suite models_env_test 120 "" "${G[@]}" -s $TESTS/models_env_test.gd
run_suite models_arch_test 120 "" "${G[@]}" -s $TESTS/models_arch_test.gd
run_suite models_char_test 120 "" "${G[@]}" -s $TESTS/models_char_test.gd
run_suite models_plant_test 120 "" "${G[@]}" -s $TESTS/models_plant_test.gd
run_suite world_test      120 "" "${G[@]}" -s $TESTS/world_test.gd
run_suite items_test      120 "" "${G[@]}" -s $TESTS/items_test.gd
run_suite items_test_minimal 120 "" "${G[@]}" -s $TESTS/items_test.gd -- --minimal
run_suite farm_test       120 "" "${G[@]}" -s $TESTS/farm_test.gd
run_suite econ_test       120 "" "${G[@]}" -s $TESTS/econ_test.gd
run_suite flow_test       120 "" "${G[@]}" -s $TESTS/flow_test.gd
run_suite items_net_test  120 "" "${G[@]}" -s $TESTS/items_net_test.gd
run_suite items_e2e_test  120 "" "${G[@]}" -s $TESTS/items_e2e_test.gd
run_suite farm_net_test   120 "" "${G[@]}" -s $TESTS/farm_net_test.gd
run_suite farm_world_test 120 "" "${G[@]}" -s $TESTS/farm_world_test.gd
run_suite flow_mp_test    120 "" "${G[@]}" -s $TESTS/flow_mp_test.gd
run_suite econ_mp_test    150 "$LOGDIR/econ_mp_host.log $LOGDIR/econ_mp_client.log" bash -c "econ_mp $((BASE + 11))"
rm -rf "$LOGDIR/net"; mkdir -p "$LOGDIR/net"
run_suite net_test        300 "$LOGDIR/net/*.log" env NET_TEST_PORT=$((BASE + 20)) NET_TEST_LOGS="$LOGDIR/net" tools/tests/net_test.sh
run_suite smoke           600 "" tools/smoke.sh
run_suite qa_robust       240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/qa_robust_body.gd --port=$((BASE + 71))
run_suite qa_solo         240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/qa_solo_body.gd --port=$((BASE + 72)) --fast
rm -rf "$LOGDIR/qa4p"; mkdir -p "$LOGDIR/qa4p"
run_suite qa_4p           300 "$LOGDIR/qa4p/*.log" env QA4P_PORT=$((BASE + 50)) QA4P_LOGS="$LOGDIR/qa4p" tools/tests/qa_4p.sh
rm -rf "$LOGDIR/qamp"; mkdir -p "$LOGDIR/qamp"
run_suite qa_mp_robust    240 "$LOGDIR/qamp/*.log" env QAMP_PORT=$((BASE + 80)) QAMP_LOGS="$LOGDIR/qamp" tools/tests/qa_mp_robust.sh
# Review 9.2: favor purchases racing (two workers / slow link); host + self-spawned client, random port.
run_suite review_play_mp  150 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/review_play_mp_body.gd --timeout=120
# Review 9.3: HUD / overlays (keyboard focus vs pause + round end, Escape cancels connecting, WORKERS width);
# solo host on +91, a join attempt to the closed +92.
run_suite review_ui       150 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/review_ui_body.gd --port=$((BASE + 91)) --timeout=120
# Review 9.1: core/net/flow. Single process on +74 (MENU inertness, return_to_menu message precedence, leak-free
# session cycles, name sanitizing: invisible characters + bounded cost); four processes on +95/+96 (rogue huge-name
# registration without a host stall, rogue at a NaN position refused by the range check, late join into a failed
# shift + RETRY, host leaving, re-host after a client session with authority moving to the new host).
run_suite review_core     240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/review_core_body.gd --port=$((BASE + 74)) --timeout=200
rm -rf "$LOGDIR/rcmp"; mkdir -p "$LOGDIR/rcmp"
run_suite review_core_mp  240 "$LOGDIR/rcmp/*.log" env RCMP_PORT=$((BASE + 95)) RCMP_LOGS="$LOGDIR/rcmp" tools/tests/review_core_mp.sh
run_suite review_core_slots 240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/review_core_slots_repro.gd --port=$((BASE + 97))

# Review 9.6: first-person view-model layer (the held item never clips): render layers of every item mesh (local hand
# -> view-model layer only, floor / remote hand -> world layers), SubViewport only for the local player, frame order,
# lights, return_to_menu leaves nothing; plus a real client process. Ports +97..+99 (probed; busy ones skipped).
# Screenshots: tools/tests/review_viewmodel_preview.gd under xvfb (see its header).
run_suite review_viewmodel 150 "" "${G[@]}" -s $TESTS/review_viewmodel_test.gd -- --port=$((BASE + 97))
# M10 lead: GameState stats / write-ups / fines / back room / audits (single host on +41).
run_suite discipline      120 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/discipline_body.gd --port=$((BASE + 41))
# M11 lead: LAN discovery (beacon validation, the menu list, a real beacon on 127.0.0.1) on +51.
run_suite lan             120 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/lan_body.gd --port=$((BASE + 51))
# M11 lead: Windows Firewall helper (parsers, result words, the helper script text, a read-only netsh query) on +53.
run_suite firewall        120 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/firewall_body.gd --port=$((BASE + 53))
# M10 voice: codec, downsampler, routes, receive validation, speaking, emitters, back-room routes, settings (+43).
run_suite voice_test      120 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/voice_test.gd --port=$((BASE + 43))
# M10 voice: a real host and client exchange voice frames over ENet in both directions (+44).
rm -rf "$LOGDIR/voice"; mkdir -p "$LOGDIR/voice"
run_suite voice_mp        150 "$LOGDIR/voice/*.log" env VOICE_MP_PORT=$((BASE + 44)) VOICE_MP_LOGS="$LOGDIR/voice" tools/tests/voice_mp.sh
# M10 physics: throw arcs, hits, chute shots, shove, stagger, collision, footsteps (solo host on +61); then a
# three-stage ENet run (late joiner, host + client) on +62.
run_suite physics         180 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/physics_body.gd --port=$((BASE + 61))
rm -rf "$LOGDIR/phys"; mkdir -p "$LOGDIR/phys"
run_suite physics_mp      240 "$LOGDIR/phys/*.log" env PHYS_PORT=$((BASE + 62)) PHYS_LOGS="$LOGDIR/phys" tools/tests/physics_mp.sh
# M10 ui: HUD marks / event banner, chat, pings, back room + spectator camera, shift report, Story lines, pause voice
# settings (solo host on +45); chat + pings host <-> client (two processes on +46).
run_suite ui_m10          150 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/ui_m10_body.gd --port=$((BASE + 45)) --timeout=120
run_suite ui_m10_mp       200 "" env UI_M10_PORT=$((BASE + 46)) tools/tests/ui_m10_mp.sh
# M10 events: scheduler, inspection sight checks, back room, power cut + fuse box, audit, rat (single host on +42);
# host + two clients on +47.
run_suite events          150 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/events_body.gd --port=$((BASE + 42)) --events --round-sec=900
rm -rf "$LOGDIR/eventsmp"; mkdir -p "$LOGDIR/eventsmp"
run_suite events_mp       240 "$LOGDIR/eventsmp/*.log" env EVENTS_MP_PORT=$((BASE + 47)) EVENTS_MP_LOGS="$LOGDIR/eventsmp" tools/tests/events_mp.sh
# M12 hostile: mutation roll + twitch, the hostile plant (root / roam / eat / chase / bite / calm / fire), hostile_max,
# despawn, late-join replay by direct RPC, shift end / reset / menu (solo host + fake workers on +55); host + one client
# on +56.
run_suite hostile         200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/hostile_body.gd --port=$((BASE + 55)) --round-sec=900 --timeout=180
rm -rf "$LOGDIR/hostilemp"; mkdir -p "$LOGDIR/hostilemp"
run_suite hostile_mp      200 "$LOGDIR/hostilemp/*.log" env HOSTILE_MP_PORT=$((BASE + 56)) HOSTILE_MP_LOGS="$LOGDIR/hostilemp" tools/tests/hostile_mp.sh
# M12 strains: six strains (numbers, colours, copy), each bought / planted / grown / harvested / sold on a headless host,
# the supply window with two rows of cards, the three M12 GLBs (solo host on +54).
run_suite strains         150 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/strains_body.gd --port=$((BASE + 54))
# M12 flame: the emergency cabinet (deposit, restock, misuse), the flamethrower (fuel, cone: scorched crops, ignited workers,
# arson), server validation of fire requests (solo host on +57); a client breaks the glass and fires on +58.
run_suite flame           200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/flame_body.gd --port=$((BASE + 57)) --timeout=150
rm -rf "$LOGDIR/flame"; mkdir -p "$LOGDIR/flame"
run_suite flame_mp        240 "$LOGDIR/flame/*.log" env FLAME_PORT=$((BASE + 58)) FLAME_LOGS="$LOGDIR/flame" tools/tests/flame_mp.sh
# M12 disrupt: head count / water main off / supply shortage on a solo host (+59); host + client A + late joiner B (+60).
run_suite disrupt         200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/disrupt_body.gd --port=$((BASE + 59)) --events --round-sec=900
rm -rf "$LOGDIR/disruptmp"; mkdir -p "$LOGDIR/disruptmp"
run_suite disrupt_mp      240 "$LOGDIR/disruptmp/*.log" env DISRUPT_MP_PORT=$((BASE + 60)) DISRUPT_MP_LOGS="$LOGDIR/disruptmp" tools/tests/disrupt_mp.sh
# M11 review of M10: back-room server rule, stagger immunity, shove line of sight, stranded items, churn during every
# event, hostile inputs, copy audit (solo host + fake workers on +48); then a host + a ROGUE client process (spoofed
# owner / authority RPCs, floods, the back-room cheat over the wire) on a random port.
run_suite review_m10      300 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/review_m10_body.gd --port=$((BASE + 48)) --round-sec=900 --timeout=280
rm -rf "$LOGDIR/rm10"; mkdir -p "$LOGDIR/rm10"
run_suite review_m10_mp   200 "$LOGDIR/rm10/*.log" env RM10_LOGS="$LOGDIR/rm10" tools/tests/review_m10_mp.sh
# M13 review of M12: fire requests (stunned / flying / flood), the arson brake, the turning tray, hostile_max, the
# hostile plant's escape rules, shortage + head-count fairness, churn, the cabinet, copy, numbers (solo host + four
# fake workers on +63); then a host + a ROGUE client (late join into M12 state, spoofed authority RPCs, raw requests) on +64.
run_suite review_m12      300 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/review_m12_body.gd --port=$((BASE + 63)) --round-sec=900 --timeout=280
rm -rf "$LOGDIR/rm12"; mkdir -p "$LOGDIR/rm12"
run_suite review_m12_mp   220 "$LOGDIR/rm12/*.log" env RM12_PORT=$((BASE + 64)) RM12_LOGS="$LOGDIR/rm12" tools/tests/review_m12_mp.sh
# M10 QA (10.8): host + three clients (one late) through the whole friendslop pass: same-frame throws, chute shots,
# shove chains, an inspection with three workers in the Boss's path, the back room, power cuts, the rat, voice under
# load, chat / ping floods, hostile M10 RPCs, churn (RETRY, leaving from the back room, the host leaving), a full
# --fast shift with the scheduler on (+52; about 2 minutes).
rm -rf "$LOGDIR/qam10"; mkdir -p "$LOGDIR/qam10"
run_suite qa_m10_4p       300 "$LOGDIR/qam10/*.log" env QAM10_PORT=$((BASE + 52)) QAM10_LOGS="$LOGDIR/qam10" tools/tests/qa_m10_4p.sh
# M13 QA of M12: mutation under load, the chase, fire, events on top, churn (a host and three client processes on +65).
rm -rf "$LOGDIR/qam12"; mkdir -p "$LOGDIR/qam12"
run_suite qa_m12_4p       300 "$LOGDIR/qam12/*.log" env QA_M12_PORT=$((BASE + 65)) QA_M12_LOGS="$LOGDIR/qam12" tools/tests/qa_m12_4p.sh
# M14 lobby: the alley, the van's head count and countdown, the ride, the way back, the override, churn, the old flow
# (solo host + fake workers on +66); host + A + B + late joiner C on +67.
run_suite lobby           200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/lobby_body.gd --port=$((BASE + 66)) --lobby --timeout=180
rm -rf "$LOGDIR/lobbymp"; mkdir -p "$LOGDIR/lobbymp"
run_suite lobby_mp        240 "$LOGDIR/lobbymp/*.log" env LOBBY_MP_PORT=$((BASE + 67)) LOBBY_MP_LOGS="$LOGDIR/lobbymp" tools/tests/lobby_mp.sh
# M14 mayhem: the leak and the drive-by on a solo host (+69); host + client A + late joiner B (+70).
run_suite mayhem          200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/mayhem_body.gd --port=$((BASE + 69)) --events --round-sec=900
rm -rf "$LOGDIR/mayhemmp"; mkdir -p "$LOGDIR/mayhemmp"
run_suite mayhem_mp       260 "$LOGDIR/mayhemmp/*.log" env MAYHEM_MP_PORT=$((BASE + 70)) MAYHEM_MP_LOGS="$LOGDIR/mayhemmp" tools/tests/mayhem_mp.sh
# M14 loop: strain traits (thirsty / dark growth / spread / heavy / counted), the drying rack and cured deposits on a solo
# host with one fake worker (+75); a client hangs, watches and deposits a cured bundle on +76.
run_suite loop            200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/loop_body.gd --port=$((BASE + 75)) --round-sec=900 --timeout=180
rm -rf "$LOGDIR/loopmp"; mkdir -p "$LOGDIR/loopmp"
run_suite loop_mp         240 "$LOGDIR/loopmp/*.log" env LOOP_PORT=$((BASE + 76)) LOOP_LOGS="$LOGDIR/loopmp" tools/tests/loop_mp.sh
# M14 level: the grow hall and the loading dock (areas, doorways, the four hall trays, arrivals, items resting in the
# annexes, gunfire lanes, routes, the plant walking from the pen to a hall tray) on a solo host (+68).
run_suite level           200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/level_body.gd --port=$((BASE + 68)) --timeout=180
# M15 alley: the ball, the hoop and its counter, the notice board (solo host + a fake worker on +81); host + A + late joiner B on +82.
run_suite alley           200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/alley_body.gd --port=$((BASE + 81)) --lobby --timeout=180
rm -rf "$LOGDIR/alleymp"; mkdir -p "$LOGDIR/alleymp"
run_suite alley_mp        260 "$LOGDIR/alleymp/*.log" env ALLEY_MP_PORT=$((BASE + 82)) ALLEY_MP_LOGS="$LOGDIR/alleymp" tools/tests/alley_mp.sh
# M15 replay: shift conditions, the market, unlocks, chips / card / briefing (solo host + fake workers, --replay) on +83;
# the same body with --no-replay (all of it inert); host + client + late joiner on +84.
run_suite replay          200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/replay_body.gd --port=$((BASE + 83)) --replay --run=B5VP --timeout=180
run_suite replay_off      120 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/replay_body.gd --port=$((BASE + 83)) --no-replay
rm -rf "$LOGDIR/replaymp"; mkdir -p "$LOGDIR/replaymp"
run_suite replay_mp       240 "$LOGDIR/replaymp/*.log" env REPLAY_MP_PORT=$((BASE + 84)) REPLAY_MP_LOGS="$LOGDIR/replaymp" tools/tests/replay_mp.sh
# M15 mayhem2: the raid, the sprinklers and the collector on a solo host (+77); host + client A + late joiner B (+78).
run_suite mayhem2         200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/mayhem2_body.gd --port=$((BASE + 77)) --events --round-sec=900
rm -rf "$LOGDIR/mayhem2mp"; mkdir -p "$LOGDIR/mayhem2mp"
run_suite mayhem2_mp      260 "$LOGDIR/mayhem2mp/*.log" env MAYHEM2_MP_PORT=$((BASE + 78)) MAYHEM2_MP_LOGS="$LOGDIR/mayhem2mp" tools/tests/mayhem2_mp.sh
# M15 career: the shift's job and the career file on a solo host with one fake worker (+85); host + Alpha + the late
# joiner Bravo, each with its own temp career file (+86). Neither touches the real user://career.cfg.
run_suite career          240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/career_body.gd --port=$((BASE + 85)) --replay --run=B5VP --career-file=user://career_test_$((BASE + 85)).cfg --round-sec=900 --timeout=200
rm -rf "$LOGDIR/careermp"; mkdir -p "$LOGDIR/careermp"
run_suite career_mp       260 "$LOGDIR/careermp/*.log" env CAREER_MP_PORT=$((BASE + 86)) CAREER_MP_LOGS="$LOGDIR/careermp" tools/tests/career_mp.sh
# M15 economy: the shift model (tools/tests/econ_sim.gd) against the shipped numbers: the payment table, the four
# targets, no dominated strain, curing as a choice. Pure (no network); +79 is reserved for it.
run_suite economy         300 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/economy_body.gd --port=$((BASE + 79))
# M16 polish: three more jobs (variety / keep / raid), the cap on walking plants, the uproot sound, the empty
# flamethrower's wait (solo host + one fake worker, --replay --events, its own temp career file) on +91.
run_suite polish          200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/polish_body.gd --port=$((BASE + 91)) --replay --run=B5VP --events --career-file=user://polish_test_$((BASE + 91)).cfg --round-sec=900 --timeout=150
# M16 variety: run codes, seeded dice, cover layouts proven from the geometry, the menu's run row, the board's run line
# (solo host, lobby + replay + events) on +89; host + client + late joiner on +90. Every other suite that runs with
# --replay passes --run=B5VP: layout 0 (today's cover) and one fixed card.
run_suite variety         260 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/variety_body.gd --port=$((BASE + 89)) --replay --lobby --events --run=7K2M --round-sec=900 --timeout=220
rm -rf "$LOGDIR/varietymp"; mkdir -p "$LOGDIR/varietymp"
run_suite variety_mp      260 "$LOGDIR/varietymp/*.log" env VARIETY_MP_PORT=$((BASE + 90)) VARIETY_MP_LOGS="$LOGDIR/varietymp" tools/tests/variety_mp.sh
# M16 hats: the catalog, the career file's hat line, the locker and the sync on a solo host with one fake worker (+87);
# host + Alpha + the late joiner Bravo, each with its own temp career file (+88). Neither touches user://career.cfg.
run_suite hats            240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/hats_body.gd --port=$((BASE + 87)) --replay --lobby --run=B5VP --career-file=user://hats_test_$((BASE + 87)).cfg --round-sec=900 --timeout=200
rm -rf "$LOGDIR/hatsmp"; mkdir -p "$LOGDIR/hatsmp"
run_suite hats_mp         260 "$LOGDIR/hatsmp/*.log" env HATS_MP_PORT=$((BASE + 88)) HATS_MP_LOGS="$LOGDIR/hatsmp" tools/tests/hats_mp.sh
# M17 finale: the final notice, a run cleared, the record and the eyeshade on a solo host with fake workers (+93,
# --replay --run=B5VP, its own temp career file); host + Alpha + the late joiner Bravo, each with its own temp career
# file (+94). Neither touches the real user://career.cfg.
run_suite finale          240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/finale_body.gd --port=$((BASE + 93)) --replay --run=B5VP --career-file=user://finale_test_$((BASE + 93)).cfg --round-sec=900 --timeout=200
rm -rf "$LOGDIR/finalemp"; mkdir -p "$LOGDIR/finalemp"
run_suite finale_mp       260 "$LOGDIR/finalemp/*.log" env FINALE_MP_PORT=$((BASE + 94)) FINALE_MP_LOGS="$LOGDIR/finalemp" tools/tests/finale_mp.sh
# M17 mayhem3: the scale and the phone on a solo host with two fake workers (+33); host + client A + the late joiner B
# (B comes in while the phone rings a second time and a favor runs; every process with --events) (+34).
run_suite mayhem3         200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/mayhem3_body.gd --port=$((BASE + 33)) --events --round-sec=900
rm -rf "$LOGDIR/mayhem3mp"; mkdir -p "$LOGDIR/mayhem3mp"
run_suite mayhem3_mp      260 "$LOGDIR/mayhem3mp/*.log" env MAYHEM3_MP_PORT=$((BASE + 34)) MAYHEM3_MP_LOGS="$LOGDIR/mayhem3mp" tools/tests/mayhem3_mp.sh
# M17 cart: the hand truck on a solo host with one fake worker (+98): the dock spot in every cover layout, heavy carry,
# load / unload / full, the data round trip, the chute deposit, the raid, shift start and START OVER; a client loads,
# unloads and deposits, a late joiner sees the load (+99).
run_suite cart            240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/cart_body.gd --port=$((BASE + 98)) --round-sec=900 --timeout=220
rm -rf "$LOGDIR/cartmp"; mkdir -p "$LOGDIR/cartmp"
run_suite cart_mp         260 "$LOGDIR/cartmp/*.log" env CART_MP_PORT=$((BASE + 99)) CART_MP_LOGS="$LOGDIR/cartmp" tools/tests/cart_mp.sh
# M17 lead: the game's own quit path (window close, the menu's quit button): a hosted session with voice, sounds and a
# loop quits through Game.quit_gracefully and exits 0 (+35).
run_suite quit             60 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/quit_body.gd --port=$((BASE + 35))
# M18 radio: the walkie-talkies on a solo host with a fake worker, plain then replay on (+36); host + Alpha + Bravo +
# the late joiner Carol (+37).
run_suite radio           240 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/radio_body.gd --port=$((BASE + 36)) --run=B5VP --career-file=user://radio_test_$((BASE + 36)).cfg --round-sec=900 --timeout=220
rm -rf "$LOGDIR/radiomp"; mkdir -p "$LOGDIR/radiomp"
run_suite radio_mp        280 "$LOGDIR/radiomp/*.log" env RADIO_MP_PORT=$((BASE + 37)) RADIO_MP_LOGS="$LOGDIR/radiomp" tools/tests/radio_mp.sh
# M18 emotes: the four gestures on a solo host with one fake worker (+40); host + client + late joiner (+49).
run_suite emotes          200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/emotes_body.gd --port=$((BASE + 40)) --round-sec=900 --timeout=180
rm -rf "$LOGDIR/emotesmp"; mkdir -p "$LOGDIR/emotesmp"
run_suite emotes_mp       200 "$LOGDIR/emotesmp/*.log" env EMOTES_MP_PORT=$((BASE + 49)) EMOTES_MP_LOGS="$LOGDIR/emotesmp" tools/tests/emotes_mp.sh
# M18 spores: Black Damp's clouds and the fog on a solo host with two fake workers (+38); host + client + late
# joiner (+39).
run_suite spores          200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/spores_body.gd --port=$((BASE + 38)) --round-sec=900 --timeout=180
rm -rf "$LOGDIR/sporesmp"; mkdir -p "$LOGDIR/sporesmp"
run_suite spores_mp       260 "$LOGDIR/sporesmp/*.log" env SPORES_MP_PORT=$((BASE + 39)) SPORES_MP_LOGS="$LOGDIR/sporesmp" tools/tests/spores_mp.sh
# M19 settings: every value read, written, clamped and applied, the OPTIONS card from both menus, the version line
# (solo host, its own temp settings file) (+14); host and client with their own files, nothing leaks (+15).
run_suite settings        200 "" "${G[@]}" "${BODY[@]}" --body=$TESTS/settings_body.gd --port=$((BASE + 14)) --settings-file=user://settings_test_$((BASE + 14)).cfg --round-sec=900 --timeout=180
rm -rf "$LOGDIR/settingsmp"; mkdir -p "$LOGDIR/settingsmp"
run_suite settings_mp     260 "$LOGDIR/settingsmp/*.log" env SETTINGS_MP_PORT=$((BASE + 15)) SETTINGS_MP_LOGS="$LOGDIR/settingsmp" tools/tests/settings_mp.sh
if command -v xvfb-run >/dev/null 2>&1; then
  run_suite qa_mouse_x11  150 "" xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . --rendering-driver opengl3 \
    --rendering-method gl_compatibility --audio-driver Dummy "${BODY[@]}" --body=$TESTS/qa_mouse_body.gd --port=$((BASE + 73)) --timeout=120
elif [[ -z "$ONLY" || "$ONLY" == *",qa_mouse_x11,"* ]]; then
  echo "== qa_mouse_x11         SKIP (xvfb-run not installed)"
  ROWS+=("$(printf '%-20s %7s %7s %7s %8s  %s' qa_mouse_x11 - - - - SKIP)")
fi

T_ALL1=$(date +%s.%N)
echo
echo "================================ test_all results ================================"
printf '%-20s %7s %7s %7s %8s  %s\n' "suite" "passed" "failed" "errors" "seconds" "result"
printf '%s\n' "--------------------------------------------------------------------------------"
for r in "${ROWS[@]}"; do echo "$r"; done
printf '%s\n' "--------------------------------------------------------------------------------"
printf '%-20s %7d %7d %7d %8s  %s\n' "TOTAL (${#ROWS[@]})" "$TOTAL_P" "$TOTAL_F" "$TOTAL_E" \
  "$(awk -v a="$T_ALL0" -v b="$T_ALL1" 'BEGIN { printf "%.1f", b - a }')" "$([[ $OVERALL -eq 0 ]] && echo PASS || echo FAIL)"
echo "errors = ERROR / SCRIPT ERROR lines not announced by the test (details: <suite>.errors in the log dir)"
echo "logs: $LOGDIR"
exit $OVERALL
