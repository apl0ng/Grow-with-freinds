#!/usr/bin/env bash
# The 30-second store clip (M24 clip, RELEASE.md R6): tools/tests/store_clip_body.gd recorded by Godot's Movie Maker at
# 1920x1080, 30 fps, with the game's sound (Movie Maker runs the Dummy audio driver: nothing plays on the speakers).
#   GODOT=<godot exe> tools/tests/store_clip.sh <absolute path>.avi [more user args for the body, e.g. --mute]
# Godot 4.7 sizes the movie from the project settings (the viewport size, or with the canvas_items stretch the window size
# overrides), never from the window, and project.godot keeps the 1280x720 base the game is laid out for. So this writes a
# temporary override.cfg next to project.godot (1920x1080 window override, borderless: the window covers a 1920x1080
# screen for about a minute; the mouse stays free), runs the body windowed and removes override.cfg on exit. It refuses
# to run when an override.cfg is already there. Never run it while a game window from this checkout is open.
set -u
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
OUT="${1:-}"
if [ -z "$OUT" ]; then
	echo "usage: tools/tests/store_clip.sh <absolute path>.avi [user args]"; exit 2
fi
shift
if [ -e override.cfg ]; then
	echo "store_clip.sh: override.cfg already exists here: not touching it"; exit 2
fi
trap 'rm -f override.cfg' EXIT INT TERM
printf '[display]\n\nwindow/size/window_width_override=1920\nwindow/size/window_height_override=1080\nwindow/size/borderless=true\n\n[editor]\n\nmovie_writer/mjpeg_quality=0.95\n' > override.cfg
timeout 600 "$GODOT" --write-movie "$OUT" --fixed-fps 30 --position 0,0 --path . \
	-s res://tools/tests/run_test.gd -- --body=res://tools/tests/store_clip_body.gd \
	--port=7978 --no-mic --chill --replay --run=B5VP --event-delay=900 --borderless "$@"
code=$?
rm -f override.cfg
exit $code
