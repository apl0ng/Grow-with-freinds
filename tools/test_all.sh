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
#   +21..+32, qa_robust +71, qa_solo +72, qa_mouse_x11 +73, qa_4p +50, qa_mp_robust +80, review_core +74,
#   review_core_mp review_core_slots +95/+96. A base whose ports are already bound
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

ALL_SUITES=(check art_test models_test models_station_test models_item_test models_props_test models_env_test models_arch_test models_char_test models_plant_test world_test items_test items_test_minimal farm_test econ_test flow_test items_net_test items_e2e_test
  farm_net_test farm_world_test flow_mp_test econ_mp_test net_test smoke qa_robust qa_solo qa_4p qa_mp_robust
  review_play_mp review_ui review_core review_core_mp review_viewmodel qa_mouse_x11)

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
  for off in 11 21 22 23 24 25 26 27 28 29 30 31 32 50 71 72 73 74 80 91 92 95 96; do
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
  setsid timeout -k 10 "$tmo" "$@" >"$log" 2>&1 </dev/null &
  sid=$!
  CURRENT_SID=$sid
  wait "$sid"; rc=$?
  CURRENT_SID=""
  t1=$(date +%s.%N)
  # Anything this suite left behind (it is in our session): TERM, then KILL.
  if pgrep -s "$sid" >/dev/null 2>&1; then
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
