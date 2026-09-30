#!/usr/bin/env bash
# Runs Grow With Friends (Godot 4.7.2) on Linux / macOS (and Git Bash on Windows).
#
#   ./launch.sh                       # main menu
#   ./launch.sh --host --name Dale    # host at once
#   ./launch.sh --join 192.168.1.20   # join a friend (ip or ip:port)
#   ./launch.sh --players 2 --fast    # two local windows (host + client) with fast growth, for testing
#   ./launch.sh --mute                # no sound
#   ./launch.sh --editor              # open the Godot editor on the project
#   ./launch.sh --import              # re-import resources (after pulling new models), then play
#
# Godot is found through $GODOT, tools/godot/, then PATH (godot, godot4, godot4.7). Install Godot 4.7.x first
# (https://godotengine.org/download). The first run imports the project's resources (the GLB models cannot load
# outside the editor without the .godot/ cache).
set -euo pipefail
cd "$(dirname "$0")"

players=1; fast=0; mute=0; host=0; join=""; name=""; port=7777; editor=0; do_import=0; fullscreen=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --players) players="$2"; shift ;;
    --fast) fast=1 ;;
    --mute) mute=1 ;;
    --host) host=1 ;;
    --join) join="$2"; shift ;;
    --name) name="$2"; shift ;;
    --port) port="$2"; shift ;;
    --editor) editor=1 ;;
    --import) do_import=1 ;;
    --fullscreen) fullscreen=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

find_godot() {
  if [[ -n "${GODOT:-}" && -x "$GODOT" ]]; then echo "$GODOT"; return; fi
  local local_bin
  for local_bin in tools/godot/Godot_v4.7.2-stable_linux.x86_64 tools/godot/godot tools/godot/Godot_v4.7.2-stable_win64.exe; do
    if [[ -x "$local_bin" ]]; then echo "$local_bin"; return; fi
  done
  local cmd
  for cmd in godot godot4 godot4.7 godot-4; do
    if command -v "$cmd" >/dev/null 2>&1; then command -v "$cmd"; return; fi
  done
  echo ""
}

godot="$(find_godot)"
if [[ -z "$godot" ]]; then
  echo "Godot 4.7.x was not found. Install it, or set GODOT=/path/to/godot." >&2
  exit 1
fi
echo "GROW WITH FRIENDS"
echo "  Godot: $godot"

if [[ $editor -eq 1 ]]; then
  "$godot" --editor --path . >/dev/null 2>&1 &
  echo "  Editor opened."
  exit 0
fi

if [[ $do_import -eq 1 || ! -d .godot/imported ]]; then
  echo "  Importing resources (first run; about ten seconds)..."
  "$godot" --headless --path . --import >/dev/null 2>&1 || true
  [[ -d .godot/imported ]] || { echo "Resource import failed." >&2; exit 1; }
fi

common=()
[[ $fast -eq 1 ]] && common+=("--fast")
[[ $mute -eq 1 ]] && common+=("--mute")
[[ "$port" != "7777" ]] && common+=("--port=$port")

start_instance() { # index user-args...
  local index="$1"; shift
  local engine=(--path .)
  if [[ $fullscreen -eq 1 && $players -eq 1 ]]; then
    engine+=(--fullscreen)
  elif [[ $players -gt 1 ]]; then
    local w=960 h=540 x y
    x=$((40 + (index % 2) * (w + 20))); y=$((60 + (index / 2) * (h + 60)))
    engine+=(--resolution "${w}x${h}" --position "$x,$y")
  fi
  echo "  Launching: ${engine[*]} -- $*"
  "$godot" "${engine[@]}" -- "$@" >/dev/null 2>&1 &
}

if [[ $players -gt 1 ]]; then
  base="${name:-Worker}"
  start_instance 0 --host "--name=${base}1" "${common[@]}"
  sleep 3
  for ((i = 1; i < players; i++)); do
    start_instance "$i" --join=127.0.0.1 "--name=${base}$((i + 1))" "${common[@]}"
    sleep 0.8
  done
  echo "  $players windows: window 1 hosts, press Enter there to start the shift."
  exit 0
fi

user_args=()
if [[ $host -eq 1 ]]; then
  user_args+=(--host)
elif [[ -n "$join" ]]; then
  target="$join"
  if [[ "$target" =~ ^(.+):([0-9]+)$ ]]; then target="${BASH_REMATCH[1]}"; common+=("--port=${BASH_REMATCH[2]}"); fi
  user_args+=("--join=$target")
fi
[[ -n "$name" ]] && user_args+=("--name=$name")
user_args+=("${common[@]}")
start_instance 0 "${user_args[@]}"
echo "  In the menu: Host opens the floor; friends join by IP or from \"Floors open nearby\"."
echo "  In the room: Enter starts the shift (host) - WASD move - E use - Q drop - RMB throw - F shove - MMB ping - T chat - V talk - Esc break"
