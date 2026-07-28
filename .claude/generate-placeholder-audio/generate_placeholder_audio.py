#!/usr/bin/env python3
"""Generate spec-compliant placeholder audio for this Godot project.

Placeholders are silent (or optionally an audible tone) files that let gameplay
hooks be wired and playtested before real music/SFX/VO exist. Every file is
tagged so it can be found again later with `--audit` and replaced before release.

The output is built to survive this repo's own CI:
  .github/workflows/validate-audio-files.yml -> .github/scripts/validate-audio-files.py
whose specs (filename pattern, WAV sample rate / bit depth / channels / length,
max file size) are IMPORTED from that script rather than duplicated here, so the
generator can never drift from the checker.

Usage:
    python .claude/skills/generate-placeholder-audio/generate_placeholder_audio.py \
        --kind sfx --name sfx_sword_hit --duration 0.4 --ticket AUDIO-123

    ... --manifest placeholders.tsv     # batch
    ... --audit                         # list placeholders still in the repo

Requires ffmpeg + ffprobe on PATH. Stdlib only.
"""

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys

# ---------------------------------------------------------------------------
# Spec: imported from the CI validator so the two can never disagree.
# ---------------------------------------------------------------------------

# Fallbacks, used only when the CI validator isn't present (e.g. the skill was
# copied into another repo). Kept identical to the validator's values.
_FALLBACK_FILENAME_PATTERN = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*\.[a-z0-9]+$")
_FALLBACK_WAV_SPECS = {
    "sample_rate": 44100,
    "bit_depth": 16,
    "channels": 1,
    "peak_volume": -1.0,
    "max_length": 10,
    "max_file_size": 49 * 1024 * 1024,
}

SAMPLE_RATE = 44100          # Hz, per the Screwloose audio guides and CI
OGG_BITRATE = "192k"         # per how_to_contribute_music.md
BARK_SOFT_MAX = 3.0          # seconds; how_to_contribute_voice_over.md says 2-3s

PLACEHOLDER_MARKER = "asset_role=placeholder"
GENERATED_BY = "generate_placeholder_audio.py"

# `_loop` is a TOKEN in the name, not necessarily the suffix: the music guide's
# own example is `main_theme_loop_v4.ogg`, so `endswith("_loop")` would miss it.
LOOP_TOKEN = re.compile(r"(?:^|_)loop(?:_|$)")


def is_looping(name):
    return bool(LOOP_TOKEN.search(name))


def find_repo_root(start):
    """Walk up from `start` looking for project.godot."""
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "project.godot")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


REPO_ROOT = find_repo_root(os.path.dirname(os.path.abspath(__file__))) or os.getcwd()
VALIDATOR_PATH = os.path.join(REPO_ROOT, ".github", "scripts", "validate-audio-files.py")


def load_ci_spec():
    """Import FILENAME_PATTERN / WAV_FILE_SPECIFICATIONS from the CI validator.

    The validator's filename contains a hyphen, so it can't be imported by name;
    load it by path instead. Returns (pattern, specs, source_description).
    """
    if not os.path.isfile(VALIDATOR_PATH):
        return (_FALLBACK_FILENAME_PATTERN, dict(_FALLBACK_WAV_SPECS),
                "built-in fallback (CI validator not found)")
    try:
        spec = importlib.util.spec_from_file_location("_ci_audio_validator", VALIDATOR_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return (mod.FILENAME_PATTERN, dict(mod.WAV_FILE_SPECIFICATIONS),
                os.path.relpath(VALIDATOR_PATH, REPO_ROOT))
    except Exception as exc:  # pragma: no cover - defensive
        print(f"warning: could not load specs from {VALIDATOR_PATH}: {exc}", file=sys.stderr)
        return (_FALLBACK_FILENAME_PATTERN, dict(_FALLBACK_WAV_SPECS),
                "built-in fallback (CI validator failed to load)")


FILENAME_PATTERN, WAV_SPECS, SPEC_SOURCE = load_ci_spec()

# ---------------------------------------------------------------------------
# Kind routing
# ---------------------------------------------------------------------------

KINDS = {
    "music": {
        "ext": ".ogg",
        "channels": 2,
        "dir": "common/audio/music",
        "tone": ("sine", 220),
        "desc": "background music track",
    },
    "ambient": {
        "ext": ".ogg",
        "channels": 2,
        "dir": "common/audio/ambient",
        "tone": ("noise", None),
        "desc": "ambient bed",
    },
    "sfx": {
        "ext": ".wav",
        "channels": 1,
        "dir": "common/audio/sfx",
        "tone": ("sine", 880),
        "desc": "sound effect",
    },
    "bark": {
        "ext": ".wav",
        "channels": 1,
        "dir": "common/audio/vo",
        "tone": ("sine", 330),
        "desc": "vocal bark",
    },
    "dialog": {
        "ext": ".ogg",
        "channels": 1,
        "dir": "common/audio/vo",
        "tone": ("sine", 220),
        "desc": "voice-over dialog line",
    },
}


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def require_tools():
    missing = [t for t in ("ffmpeg", "ffprobe") if shutil.which(t) is None]
    if missing:
        die(f"{', '.join(missing)} not found on PATH. Install ffmpeg (it bundles ffprobe).")


# ---------------------------------------------------------------------------
# ffprobe helpers
# ---------------------------------------------------------------------------

def probe_tags(path):
    """Return the file's metadata tags as a dict.

    GOTCHA: Ogg Vorbis comments live on the STREAM, not the format container --
    `ffprobe -show_entries format_tags` returns {} for a .ogg. WAV RIFF INFO tags
    live on the format. Read both and merge so callers don't have to care.
    """
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format_tags:stream_tags",
         "-of", "json", path],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return {}
    try:
        data = json.loads(out.stdout or "{}")
    except json.JSONDecodeError:
        return {}
    tags = {}
    for stream in data.get("streams", []):
        tags.update(stream.get("tags", {}))
    tags.update(data.get("format", {}).get("tags", {}))
    return tags


def is_placeholder(path):
    tags = probe_tags(path)
    lowered = {k.lower(): (v or "") for k, v in tags.items()}
    if lowered.get("asset_role", "").lower() == "placeholder":
        return True
    blob = " ".join(lowered.get(k, "") for k in ("comment", "title", "description"))
    return "placeholder" in blob.lower()


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

def build_ffmpeg_cmd(out_path, kind, duration, tone, metadata):
    cfg = KINDS[kind]
    channels = cfg["channels"]
    layout = "mono" if channels == 1 else "stereo"

    if tone:
        tone_kind, freq = cfg["tone"]
        if tone_kind == "noise":
            # amplitude 0.2 measures ~-19 dBFS peak -- audible, far under the
            # -1 dBFS ceiling the audio guides require.
            src = f"anoisesrc=r={SAMPLE_RATE}:duration={duration}:color=pink:amplitude=0.2"
        else:
            # ffmpeg's `sine` filter emits at amplitude 1/8 (~-18.1 dBFS), NOT
            # full scale. That is already a safe, audible level -- do not boost.
            src = f"sine=frequency={freq}:sample_rate={SAMPLE_RATE}:duration={duration}"
        # Short fades so the placeholder never clicks at the edges, which the
        # sound-effects guide explicitly calls out.
        fade = min(0.02, duration / 4.0)
        afilter = (f"afade=t=in:st=0:d={fade:.4f},"
                   f"afade=t=out:st={max(duration - fade, 0):.4f}:d={fade:.4f}")
    else:
        src = f"anullsrc=r={SAMPLE_RATE}:cl={layout}:d={duration}"
        afilter = None

    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", src]
    if afilter:
        cmd += ["-af", afilter]
    for key, value in metadata.items():
        cmd += ["-metadata", f"{key}={value}"]
    cmd += ["-ac", str(channels)]
    if cfg["ext"] == ".ogg":
        cmd += ["-c:a", "libvorbis", "-b:a", OGG_BITRATE]
    else:
        cmd += ["-c:a", "pcm_s16le"]
    cmd.append(out_path)
    return cmd


def build_metadata(kind, name, ext, duration, ticket, desc, tone):
    looping = is_looping(name)
    what = desc or KINDS[kind]["desc"]
    comment = (f"PLACEHOLDER - {what}; replace before release; "
               f"{PLACEHOLDER_MARKER}; generated_by={GENERATED_BY}")
    if ticket:
        comment += f"; ticket={ticket}"

    md = {
        "title": f"Placeholder: {name}",
        "artist": "Build pipeline",
        "comment": comment,
    }

    if ext == ".ogg":
        # Vorbis comments keep arbitrary keys, so the structured fields survive.
        md["asset_role"] = "placeholder"
        md["generated_by"] = GENERATED_BY
        md["placeholder_kind"] = kind
        if ticket:
            md["source_ticket"] = ticket
        if looping:
            # Per how_to_make_looping_audio_tracks.md. NOTE: Godot's Vorbis
            # importer ignores these -- looping is driven by loop=true in the
            # .ogg.import sidecar, which this script also writes.
            md["LOOP"] = "true"
            md["LOOP_POINT"] = "0.000"
    # WAV: RIFF INFO only carries title/artist/comment (ffmpeg silently DROPS
    # any other key), which is why the marker is embedded in `comment` above.

    if tone:
        md["comment"] += "; audible tone placeholder"
    return md


# ---------------------------------------------------------------------------
# Godot .import sidecars
# ---------------------------------------------------------------------------

OGG_IMPORT = """[remap]

importer="oggvorbisstr"
type="AudioStreamOggVorbis"

[deps]

source_file="res://{res_path}"

[params]

loop={loop}
loop_offset=0
bpm=0
beat_count=0
bar_beats=4
"""

# `edit/loop_mode` on the WAV importer is an ENUM INDEX, not a boolean, and its first
# entry is not "off": "Detect From WAV,Disabled,Forward,Ping-Pong,Backward". Writing 1
# here reads as *Disabled*, which is how a file with a loop flag set still imported with
# AudioStreamWAV.loop_mode == LOOP_DISABLED. Forward is 2. (The .ogg importer's `loop` is
# a real bool -- only the WAV side is an index.)
WAV_LOOP_DETECT = 0
WAV_LOOP_FORWARD = 2

WAV_IMPORT = """[remap]

importer="wav"
type="AudioStreamWAV"

[deps]

source_file="res://{res_path}"

[params]

force/8_bit=false
force/mono=false
force/max_rate=false
force/max_rate_hz=44100
edit/trim=false
edit/normalize=false
edit/loop_mode={loop_mode}
edit/loop_begin=0
edit/loop_end=-1
compress/mode=2
"""


def inside_repo(path):
    rel = os.path.relpath(os.path.abspath(path), REPO_ROOT)
    return not rel.startswith(os.pardir) and not os.path.isabs(rel)


def show(path):
    """Repo-relative path when the file is in the project, absolute otherwise."""
    return os.path.relpath(path, REPO_ROOT) if inside_repo(path) else os.path.abspath(path)


def write_import_sidecar(audio_path, name, ext):
    """Write a minimal .import sidecar next to the asset.

    `uid=`, `path=` and `dest_files=` are deliberately OMITTED: those are
    generated by Godot on first import. Inventing a uid:// would create a
    duplicate/bogus resource id.

    Returns None for files outside the project -- a res:// path can't address
    them, and a sidecar containing `res://../../AppData/...` is worse than none.
    """
    if not inside_repo(audio_path):
        return None
    res_path = os.path.relpath(audio_path, REPO_ROOT).replace(os.sep, "/")
    looping = is_looping(name)
    if ext == ".ogg":
        body = OGG_IMPORT.format(res_path=res_path, loop="true" if looping else "false")
    else:
        body = WAV_IMPORT.format(res_path=res_path, loop_mode=WAV_LOOP_FORWARD if looping else WAV_LOOP_DETECT)
    import_path = audio_path + ".import"
    with open(import_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)
    return import_path


def find_godot():
    if os.environ.get("GODOT_BIN"):
        return os.environ["GODOT_BIN"]
    for candidate in ("godot", "godot4", "Godot_v4.7-stable_win64.exe"):
        found = shutil.which(candidate)
        if found:
            return found
    return None


def run_godot_import():
    godot = find_godot()
    if not godot:
        print("note: no Godot binary found (set GODOT_BIN to run the real importer); "
              "using the generated .import sidecar instead.")
        return False
    print(f"running Godot headless import via {godot} ...")
    res = subprocess.run([godot, "--headless", "--path", REPO_ROOT, "--import"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f"warning: godot --import exited {res.returncode}", file=sys.stderr)
        print(res.stderr[-2000:], file=sys.stderr)
        return False
    return True


# ---------------------------------------------------------------------------
# Validation of our own output
# ---------------------------------------------------------------------------

def run_ci_validator(paths):
    if not os.path.isfile(VALIDATOR_PATH):
        print("note: CI validator not found; skipping the CI conformance check.")
        return True
    res = subprocess.run([sys.executable, VALIDATOR_PATH] + paths,
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr, file=sys.stderr)
        return False
    return True


def describe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries",
         "stream=codec_name,sample_rate,channels,bits_per_sample:format=duration,size",
         "-of", "json", path],
        capture_output=True, text=True,
    )
    try:
        data = json.loads(out.stdout or "{}")
    except json.JSONDecodeError:
        return ""
    st = (data.get("streams") or [{}])[0]
    fm = data.get("format", {})
    bits = st.get("bits_per_sample") or 0
    depth = f"{bits}-bit, " if bits else ""
    return (f"{st.get('codec_name', '?')}, {st.get('sample_rate', '?')} Hz, "
            f"{st.get('channels', '?')} ch, {depth}"
            f"{float(fm.get('duration', 0)):.2f}s, {int(fm.get('size', 0)) / 1024:.1f} KiB")


# ---------------------------------------------------------------------------
# One placeholder
# ---------------------------------------------------------------------------

def validate_request(kind, name, duration):
    if kind not in KINDS:
        die(f"unknown kind '{kind}'; choose from {', '.join(sorted(KINDS))}")
    ext = KINDS[kind]["ext"]
    filename = name + ext

    if not FILENAME_PATTERN.match(filename):
        die(f"filename '{filename}' fails the CI naming rule ({SPEC_SOURCE}): "
            "lowercase letters, digits and underscores only -- no spaces, hyphens, "
            "capitals or punctuation. e.g. 'gladdy_bgm_arena_theme_loop_v1'")

    if duration <= 0:
        die("--duration must be greater than 0")

    if ext == ".wav":
        cap = WAV_SPECS["max_length"]
        if duration > cap:
            die(f"WAV placeholders are capped at {cap}s by CI ({SPEC_SOURCE}); "
                f"got {duration}s. Use --kind music or --kind ambient (.ogg) for "
                "anything longer.")
    if kind == "bark" and duration > BARK_SOFT_MAX:
        print(f"warning: barks should be {BARK_SOFT_MAX:g}s or shorter per the "
              f"voice-over guide; generating {duration}s anyway.")
    return ext, filename


def generate_one(args, kind, name, duration, ticket, desc, dest):
    ext, filename = validate_request(kind, name, duration)

    out_dir = dest or os.path.join(REPO_ROOT, *KINDS[kind]["dir"].split("/"))
    out_path = os.path.join(out_dir, filename)

    metadata = build_metadata(kind, name, ext, duration, ticket, desc, args.tone)
    cmd = build_ffmpeg_cmd(out_path, kind, duration, args.tone, metadata)

    if args.dry_run:
        print(" ".join(f'"{c}"' if " " in c else c for c in cmd))
        return None

    # Never silently flatten a real asset.
    if os.path.exists(out_path) and not args.force:
        if not is_placeholder(out_path):
            die(f"{show(out_path)} already exists and is NOT a placeholder -- refusing "
                "to overwrite real audio. Pass --force if you really mean it.")
        print(f"note: replacing existing placeholder {show(out_path)}")

    os.makedirs(out_dir, exist_ok=True)
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stderr, file=sys.stderr)
        die(f"ffmpeg failed for {filename}")

    size = os.path.getsize(out_path)
    if size > WAV_SPECS["max_file_size"]:
        os.remove(out_path)
        die(f"{filename} came out at {size} bytes, over the {WAV_SPECS['max_file_size']} "
            "byte CI limit; removed.")

    import_path = write_import_sidecar(out_path, name, ext)

    print(f"wrote {show(out_path)}  [{describe(out_path)}]")
    if import_path:
        print(f"wrote {show(import_path)}")
    else:
        print("note: output is outside the Godot project, so no .import sidecar was "
              "written (res:// can't address it).")
    return out_path


# ---------------------------------------------------------------------------
# Batch + audit
# ---------------------------------------------------------------------------

def read_manifest(path):
    """TSV: kind<TAB>name<TAB>duration[<TAB>ticket[<TAB>description]]

    Blank lines and lines starting with # are ignored.
    """
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                die(f"{path}:{lineno}: need at least kind<TAB>name<TAB>duration")
            kind, name, duration = parts[0].strip(), parts[1].strip(), parts[2].strip()
            ticket = parts[3].strip() if len(parts) > 3 else None
            desc = parts[4].strip() if len(parts) > 4 else None
            try:
                duration = float(duration)
            except ValueError:
                die(f"{path}:{lineno}: duration '{duration}' is not a number")
            rows.append((kind, name, duration, ticket or None, desc or None))
    return rows


AUDIO_EXTS = (".wav", ".ogg", ".mp3")


def audit(root):
    base = root or os.path.join(REPO_ROOT, "common", "audio")
    if not os.path.isdir(base):
        die(f"nothing to audit: {base} does not exist")
    found = []
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in sorted(filenames):
            if not fn.lower().endswith(AUDIO_EXTS):
                continue
            full = os.path.join(dirpath, fn)
            if is_placeholder(full):
                tags = probe_tags(full)
                ticket = tags.get("source_ticket") or ""
                if not ticket:
                    m = re.search(r"ticket=([^;]+)", tags.get("comment", ""))
                    ticket = m.group(1).strip() if m else ""
                found.append((show(full).replace(os.sep, "/"), ticket))
    if not found:
        print(f"No placeholder audio found under {show(base)}.")
        return 0
    print(f"{len(found)} placeholder asset(s) still need real audio:\n")
    width = max(len(p) for p, _ in found)
    for path, ticket in found:
        print(f"  {path.ljust(width)}  {ticket}")
    return 0


# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(
        description="Generate spec-compliant placeholder audio for this Godot project.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Specs are read from %s" % SPEC_SOURCE,
    )
    p.add_argument("--kind", choices=sorted(KINDS),
                   help="music/ambient -> .ogg stereo; sfx/bark -> .wav mono; dialog -> .ogg mono")
    p.add_argument("--name", help="file stem, lowercase_with_underscores, no extension")
    p.add_argument("--duration", type=float, help="length in seconds")
    p.add_argument("--ticket", help="tracking ticket, e.g. AUDIO-123")
    p.add_argument("--desc", help="short description of what the real asset will be")
    p.add_argument("--dest", help="output directory override (default: per --kind)")
    p.add_argument("--tone", action="store_true",
                   help="emit an audible tone/noise instead of silence")
    p.add_argument("--force", action="store_true",
                   help="allow overwriting a file that is not a known placeholder")
    p.add_argument("--manifest", help="TSV batch file: kind<TAB>name<TAB>duration[<TAB>ticket[<TAB>desc]]")
    p.add_argument("--audit", action="store_true",
                   help="list placeholder audio still present in the repo, then exit")
    p.add_argument("--audit-root", help="directory to audit (default: common/audio)")
    p.add_argument("--dry-run", action="store_true", help="print the ffmpeg command, write nothing")
    p.add_argument("--godot-import", action="store_true",
                   help="also run `godot --headless --import` (needs GODOT_BIN or godot on PATH)")
    p.add_argument("--no-verify", action="store_true",
                   help="skip running the CI validator on the generated files")
    args = p.parse_args()

    require_tools()

    if args.audit:
        sys.exit(audit(args.audit_root))

    if args.manifest:
        jobs = read_manifest(args.manifest)
    else:
        missing = [f"--{f}" for f in ("kind", "name", "duration")
                   if getattr(args, f) in (None, "")]
        if missing:
            p.error(f"missing required argument(s): {', '.join(missing)} "
                    "(or use --manifest / --audit)")
        jobs = [(args.kind, args.name, args.duration, args.ticket, args.desc)]

    dest = os.path.abspath(args.dest) if args.dest else None
    written = []
    for kind, name, duration, ticket, desc in jobs:
        result = generate_one(args, kind, name, duration, ticket, desc, dest)
        if result:
            written.append(result)

    if not written:
        return

    if not args.no_verify:
        print(f"\nverifying against {SPEC_SOURCE} ...")
        if not run_ci_validator(written):
            die("generated files FAILED the CI audio validator (see output above)")
        print("all generated files pass CI audio validation.")

    if not any(inside_repo(w) for w in written):
        return
    if args.godot_import:
        run_godot_import()
    else:
        print("note: .import sidecars were written without uid/path -- open the project "
              "in Godot once (or pass --godot-import) so it fills them in.")


if __name__ == "__main__":
    main()
