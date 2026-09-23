#!/usr/bin/env python3
"""Build Blender-authored models: tools/blender/models/*.py -> art/models/*.glb -> Godot import.
Owner: pipeline agent. Workflow + conventions: MODELING.md.

  python3 tools/blender/build.py                     # every model script
  python3 tools/blender/build.py oil_drum lamps      # only these scripts (file stems in models/)
  options:
    --preview [--preview-dir DIR]   also render a Cycles turntable strip per model (~1.5 s each;
                                    default dir: $TMPDIR/gwf_previews)
    --no-import                     skip the Godot import pass (Blender side only)
    --test                          run the headless model suite (tools/tests/models_test.gd) afterwards
    --shots DIR                     render the built models in-game (Toonify, toon lighting) under xvfb:
                                    DIR/<first>_sheet_1.png (close-ups) + DIR/<first>_eye.png (player view)
    --verbose                       show exporter / Godot output
    --list                          list the model scripts and exit

Idempotent: a .glb / .glb.import is only rewritten when its bytes change, so Godot only reimports what
changed and git sees no churn. Exit code 0 = every model exported, imported and passed its checks.
"""

import sys

sys.dont_write_bytecode = True  # no __pycache__ in the repo (gwf + model scripts are imported)

import fcntl  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MODELS_SRC = os.path.join(HERE, "models")
MODELS_DIR = os.path.join(REPO, "art", "models")
TOONIFY = "res://scripts/art/toonify.gd"
GODOT = os.environ.get("GODOT", "godot")

# Godot import params every art/models/*.glb gets (written into its .glb.import BEFORE the import pass,
# so imports are deterministic whoever runs them). Values are Godot variant text.
IMPORT_DEFAULTS = {
    "nodes/root_type": '"Node3D"',
    "nodes/root_name": '""',
    "nodes/root_script": None,  # filled in: Resource(toonify.gd) -> every model toonifies itself in _ready
    "nodes/apply_root_scale": "true",
    "nodes/root_scale": "1.0",
    "nodes/use_name_suffixes": "false",  # object names are just names ("-col" etc. do nothing)
    "meshes/ensure_tangents": "false",   # no textures -> no tangents needed
    "meshes/generate_lods": "false",     # low-poly already; LODs only add popping
    "meshes/create_shadow_meshes": "true",
    "animation/import": "false",         # animate in Godot (tweens), not in Blender
    # Object "Hand__L" -> node "Hand" (Godot's glTF import would otherwise rename duplicates "Hand2").
    "import_script/path": '"res://tools/blender/gwf_post_import.gd"',
}


def _toonify_resource():
    uid_file = os.path.join(REPO, "scripts", "art", "toonify.gd.uid")
    if os.path.exists(uid_file):
        uid = open(uid_file, encoding="utf-8").read().strip()
        if uid.startswith("uid://"):
            return 'Resource("%s", "%s")' % (uid, TOONIFY)
    return 'Resource("%s")' % TOONIFY


def _variant(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str) and (v.startswith("Resource(") or v.startswith('"')):
        return v
    return '"%s"' % v


def write_import_defaults(glb_path, overrides=None):
    """Merge IMPORT_DEFAULTS (+ per-model overrides) into <glb>.import. Returns True if the file changed."""
    params = dict(IMPORT_DEFAULTS)
    params["nodes/root_script"] = _toonify_resource()
    for k, v in (overrides or {}).items():
        params[k] = _variant(v)
    ipath = glb_path + ".import"
    old = open(ipath, encoding="utf-8").read() if os.path.exists(ipath) else None
    text = old or '[remap]\n\nimporter="scene"\nimporter_version=1\ntype="PackedScene"\n\n[params]\n\n'
    if "\n[params]\n" not in "\n" + text:
        text = text.rstrip("\n") + "\n\n[params]\n\n"
    head, _, section = text.partition("[params]\n")
    # The [params] section is the last one Godot writes; stop at a following section just in case.
    m = re.search(r"^\[", section, re.M)
    tail = ""
    if m:
        section, tail = section[:m.start()], section[m.start():]
    for key, val in params.items():
        line = "%s=%s" % (key, val)
        pat = re.compile(r"^%s=.*$" % re.escape(key), re.M)
        if pat.search(section):
            section = pat.sub(lambda _m: line, section, count=1)
        else:
            section = section.rstrip("\n") + "\n" + line + "\n"
    new = head + "[params]\n" + section + tail
    if new != old:
        with open(ipath, "w", encoding="utf-8") as f:
            f.write(new)
        return True
    return False


def import_state(glb_path):
    """(ok, detail) for a .glb after the Godot import pass."""
    ipath = glb_path + ".import"
    if not os.path.exists(ipath):
        return False, "no .import"
    txt = open(ipath, encoding="utf-8").read()
    if 'uid="uid://' not in txt:
        return False, "not imported (no uid)"
    m = re.search(r'^path="res://(.+?)"', txt, re.M)
    if not m or not os.path.exists(os.path.join(REPO, m.group(1))):
        return False, "imported file missing"
    if TOONIFY not in txt:
        return False, "root_script not set"
    return True, ""


def update_manifest(records, owner):
    """art/models/manifest.json: one entry per model (kind, Godot front, mount, tris, size, materials,
    script). Read by tools/tests/models_preview.gd + models_test.gd and handy for level agents. Entries of
    models not built this run are kept; entries whose .glb is gone are dropped. Written only on change."""
    path = os.path.join(MODELS_DIR, "manifest.json")
    old_text = open(path, encoding="utf-8").read() if os.path.exists(path) else None
    try:
        data = json.loads(old_text) if old_text else {}
    except ValueError:
        data = {}
    for r in records:
        if r["problems"]:
            continue
        w, h, d = r["size"]
        data[r["name"]] = {
            "kind": r["kind"], "front": r["front"], "mount": r["mount"], "tris": r["tris"],
            "size": [round(w, 3), round(h, 3), round(d, 3)], "materials": r["materials"],
            "script": "tools/blender/models/%s.py" % owner.get(r["name"], "?"),
        }
    data = {k: v for k, v in data.items() if os.path.exists(os.path.join(MODELS_DIR, k + ".glb"))}
    text = json.dumps(data, indent=1, sort_keys=True) + "\n"
    if text != old_text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


def load_script(path):
    spec = importlib.util.spec_from_file_location("gwf_model_" + os.path.basename(path)[:-3], path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = [a for a in argv if a.startswith("--")]
    preview = "--preview" in flags
    verbose = "--verbose" in flags
    preview_dir = None
    shots_dir = None
    for i, a in enumerate(argv):
        if a in ("--preview-dir", "--shots") and i + 1 < len(argv):
            if a == "--shots":
                shots_dir = os.path.abspath(argv[i + 1])
            else:
                preview_dir = os.path.abspath(argv[i + 1])
            args = [x for x in args if x != argv[i + 1]]
        elif a.startswith("--preview-dir="):
            preview_dir = os.path.abspath(a.split("=", 1)[1])
        elif a.startswith("--shots="):
            shots_dir = os.path.abspath(a.split("=", 1)[1])
    known = {"--preview", "--no-import", "--test", "--verbose", "--list", "--preview-dir", "--shots"}
    for f in flags:
        if f.split("=")[0] not in known:
            print("unknown option %s\n%s" % (f, __doc__))
            return 2

    scripts = sorted(f[:-3] for f in os.listdir(MODELS_SRC) if f.endswith(".py") and not f.startswith("_"))
    if "--list" in flags:
        print("\n".join(scripts))
        return 0
    wanted = [a[:-3] if a.endswith(".py") else a for a in args]
    missing = [w for w in wanted if w not in scripts]
    if missing:
        print("no such model script: %s (have: %s)" % (", ".join(missing), ", ".join(scripts)))
        return 2
    run_all = not wanted
    todo = wanted or scripts

    t_start = time.time()
    sys.path.insert(0, HERE)
    import gwf  # noqa: E402  (imports bpy, ~0.5 s)
    gwf.OPTIONS["preview"] = preview
    gwf.OPTIONS["verbose"] = verbose
    if preview_dir:
        gwf.OPTIONS["preview_dir"] = preview_dir

    script_fail = {}
    owner = {}
    for stem in todo:
        n_before = len(gwf.EXPORTS)
        t0 = time.time()
        print("== %s" % stem)
        try:
            gwf.reset()
            mod = load_script(os.path.join(MODELS_SRC, stem + ".py"))
            if not hasattr(mod, "build"):
                raise RuntimeError("%s.py has no build() function" % stem)
            mod.build()
            if len(gwf.EXPORTS) == n_before:
                raise RuntimeError("%s.py exported nothing (call export(...))" % stem)
        except Exception as e:  # keep going: one broken model must not block the others
            traceback.print_exc()
            script_fail[stem] = "%s: %s" % (type(e).__name__, e)
        for rec in gwf.EXPORTS[n_before:]:
            owner[rec["name"]] = stem
        print("   %.2f s" % (time.time() - t0))
    t_blender = time.time() - t_start

    update_manifest(gwf.EXPORTS, owner)

    # Import params: every model built now, plus any .glb whose .import misses our defaults.
    changed_imports = 0
    built = {r["name"]: r for r in gwf.EXPORTS if not r["problems"]}
    for f in sorted(os.listdir(MODELS_DIR)) if os.path.isdir(MODELS_DIR) else []:
        if not f.endswith(".glb"):
            continue
        name = f[:-4]
        path = os.path.join(MODELS_DIR, f)
        ipath = path + ".import"
        needs = name in built or not os.path.exists(ipath) or TOONIFY not in open(ipath, encoding="utf-8").read()
        if needs and write_import_defaults(path, built.get(name, {}).get("import_params")):
            changed_imports += 1

    godot_errors = []
    t_import = 0.0
    if "--no-import" not in flags:
        t0 = time.time()
        print("== godot --import (%d model files, %d import settings changed)" % (
            sum(1 for r in gwf.EXPORTS if r["changed"]), changed_imports))
        try:
            # Several modelers may build at once: serialise the Godot import passes on this project.
            os.makedirs(os.path.join(REPO, ".godot"), exist_ok=True)
            lock = open(os.path.join(REPO, ".godot", "gwf_import.lock"), "w")
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                proc = subprocess.run([GODOT, "--headless", "--path", REPO, "--import"], capture_output=True,
                                      text=True, timeout=600)
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                lock.close()
            out = proc.stdout + proc.stderr
            if verbose:
                print(out)
            for line in out.splitlines():
                if ("ERROR" in line or "SCRIPT ERROR" in line) and ("art/models" in line or "toonify" in line):
                    godot_errors.append(line.strip())
        except (OSError, subprocess.TimeoutExpired) as e:
            godot_errors.append("godot --import failed: %s" % e)
        t_import = time.time() - t0

    # Table
    rows = []
    fails = 0
    for rec in gwf.EXPORTS:
        status = "ok"
        notes = list(rec["warnings"])
        if rec["problems"]:
            status = "FAIL"
            notes = rec["problems"] + notes
        elif "--no-import" not in flags:
            ok, detail = import_state(rec["path"])
            if not ok:
                status = "FAIL"
                notes.insert(0, "import: " + detail)
        if status == "ok" and notes:
            status = "WARN"
        if status == "FAIL":
            fails += 1
        w, h, d = rec["size"]
        rows.append((rec["name"], rec["kind"], str(rec["tris"]), "%d" % rec["budget"],
                     "%.2f x %.2f x %.2f" % (w, h, d), rec["mount"], rec["front"], str(len(rec["materials"])),
                     "changed" if rec["changed"] else "same", status, "; ".join(notes)))
    for stem, err in script_fail.items():
        fails += 1
        rows.append(("(%s.py)" % stem, "-", "-", "-", "-", "-", "-", "-", "-", "FAIL", err))
    head = ("model", "kind", "tris", "budget", "W x H x D (m)", "mount", "front", "mats", "glb", "status", "notes")
    widths = [max(len(r[i]) for r in rows + [head]) for i in range(len(head) - 1)]
    print()
    print("  ".join(h.ljust(w) for h, w in zip(head, widths)) + "  " + head[-1])
    print("  ".join("-" * w for w in widths) + "  -----")
    for r in rows:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths)) + "  " + r[-1])
    for e in godot_errors:
        print("GODOT: " + e)
    if run_all:
        exported = {r["name"] for r in gwf.EXPORTS}
        for f in sorted(os.listdir(MODELS_DIR)) if os.path.isdir(MODELS_DIR) else []:
            if f.endswith(".glb") and f[:-4] not in exported:
                print("WARN orphan: art/models/%s is not produced by any script (delete it + its .import?)" % f)
    print("\n%d model(s), %d failed | blender %.1f s, godot import %.1f s, total %.1f s" % (
        len(gwf.EXPORTS), fails, t_blender, t_import, time.time() - t_start))
    if preview:
        print("previews: %s" % gwf.OPTIONS["preview_dir"])

    status = 1 if (fails or godot_errors) else 0
    built_ok = [r["name"] for r in gwf.EXPORTS if not r["problems"]]
    if shots_dir and built_ok and "--no-import" not in flags:
        print("== in-game shots -> %s" % shots_dir)
        cmd = ["xvfb-run", "-a", "-s", "-screen 0 1280x720x24", GODOT, "--path", REPO, "--rendering-driver",
               "opengl3", "--rendering-method", "gl_compatibility", "--resolution", "960x540", "-s",
               "res://tools/tests/models_preview.gd", "--", "--out=" + shots_dir, "--models=" + ",".join(built_ok),
               "--layout=sheet,eye", "--cols=4", "--cell=420x420", "--size=1600x900", "--prefix=" + built_ok[0]]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            for line in (proc.stdout + proc.stderr).splitlines():
                if line.startswith("models_preview: /") or "SCRIPT ERROR" in line:
                    print("  " + line)
        except (OSError, subprocess.TimeoutExpired) as e:
            print("  shots failed: %s" % e)
    if "--test" in flags and "--no-import" not in flags:
        print("== models_test")
        proc = subprocess.run([GODOT, "--headless", "--path", REPO, "-s", "res://tools/tests/models_test.gd"],
                              capture_output=True, text=True, timeout=600)
        out = proc.stdout + proc.stderr
        lines = [l for l in out.splitlines() if l.startswith(("models_test", "  FAIL", "FAIL")) or "ERROR" in l]
        print("\n".join(lines[-40:]))
        if proc.returncode != 0:
            status = 1
    return status


if __name__ == "__main__":
    code = main(sys.argv[1:])
    # bpy 4.2 (as a Python module) segfaults during interpreter teardown after any glTF export, AFTER every
    # file is written. Leave without the teardown so the exit code stays meaningful (0 = all good).
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)
