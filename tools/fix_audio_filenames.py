"""
Rename asset files to the project's filename convention (lowercase letters,
numbers, and underscores only; underscores separate words; lowercase
extension) and update every static reference to the old name across the
project (.gd, .tscn, .tres, .import, project.godot, etc).

Usage:
    # Report what would change, without touching anything (default = dry run)
    python tools/fix_audio_filenames.py "assets/audio/sfx/Ive Got Your Back (intro)!.wav"

    # Actually rename the file(s) and rewrite references
    python tools/fix_audio_filenames.py "assets/audio/sfx/Ive Got Your Back (intro)!.wav" --apply

    # You can pass a bare filename (no directory) if it's unique in the project
    python tools/fix_audio_filenames.py "some-file_name.WAV" --apply

    # Read a list of paths from a file (one per line), e.g. output of validate-audio-files.py
    python tools/fix_audio_filenames.py --from-file offenders.txt --apply

    # Auto-discover every non-compliant .wav/.ogg/.mp3 under the project and fix them all
    python tools/fix_audio_filenames.py --scan --apply

What it does, per file:
    1. Computes a filename-safe version of the name (see FILENAME_PATTERN below).
    2. Greps every text file in the project (skipping .git/.godot/binary files)
       for the old `res://...` path and rewrites it to the new one.
    3. Renames the file itself (via `git mv` when the repo/file allow it, so
       history is preserved; falls back to a plain rename otherwise).
    4. If a Godot `<file>.import` sidecar exists next to it, renames that too
       and fixes its `source_file=` line.

Limitations:
    - Only catches *static* references (literal `res://...` strings). Paths
      built dynamically at runtime (e.g. string concatenation) won't be found.
    - Only rewrites the exact `res://<old path>` string by default. Bare
      occurrences of the old filename without the res:// prefix (e.g. inside
      a comment or display string) are reported but not changed, since those
      are more likely to be prose than a path reference -- use
      --replace-bare-filename to also rewrite those.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Same convention enforced by .github/scripts/validate-audio-files.py:
# lowercase letters/numbers only, underscores as the sole word separator,
# lowercase extension.
FILENAME_PATTERN = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*\.[a-z0-9]+$")

SKIP_DIRS = {".git", ".godot", ".import", "node_modules", "__pycache__", ".venv"}
MAX_TEXT_FILE_SIZE = 5 * 1024 * 1024  # skip anything bigger; not hand-authored text
DEFAULT_SCAN_EXTENSIONS = {".wav", ".ogg", ".mp3"}


def sanitize_filename(name):
    stem, ext = os.path.splitext(name)
    ext = re.sub(r"[^a-z0-9]", "", ext.lower()) or "dat"
    stem = re.sub(r"[^a-z0-9]+", "_", stem.lower())
    stem = re.sub(r"_+", "_", stem).strip("_") or "file"
    return f"{stem}.{ext}"


def find_project_root(start):
    current = start.resolve()
    for candidate in [current, *current.parents]:
        if (candidate / "project.godot").is_file() or (candidate / ".git").is_dir():
            return candidate
    return start.resolve()


def iter_project_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fname in filenames:
            path = Path(dirpath) / fname
            try:
                if path.stat().st_size > MAX_TEXT_FILE_SIZE:
                    continue
            except OSError:
                continue
            yield path


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            return f.read()
    except (UnicodeDecodeError, OSError):
        return None


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def res_path(root, path):
    rel = os.path.relpath(path, root).replace(os.sep, "/")
    return f"res://{rel}"


def git_tracked(root, path):
    if shutil.which("git") is None:
        return False
    result = subprocess.run(
        ["git", "ls-files", "--error-unmatch", str(path)],
        cwd=root, capture_output=True, text=True,
    )
    return result.returncode == 0


def move_file(root, old_path, new_path, use_git):
    new_path.parent.mkdir(parents=True, exist_ok=True)
    if use_git:
        result = subprocess.run(
            ["git", "mv", str(old_path), str(new_path)],
            cwd=root, capture_output=True, text=True,
        )
        if result.returncode == 0:
            return
    os.rename(old_path, new_path)


def resolve_target(root, arg):
    p = Path(arg)
    if p.is_file():
        return [p.resolve()]
    p2 = root / arg
    if p2.is_file():
        return [p2.resolve()]

    basename = os.path.basename(arg)
    matches = [
        f for f in iter_project_files(root)
        if f.name == basename
    ]
    return matches


def scan_offenders(root, extensions):
    offenders = []
    for path in iter_project_files(root):
        if path.suffix.lower() in extensions and not FILENAME_PATTERN.match(path.name):
            offenders.append(path)
    return offenders


class RenamePlan:
    def __init__(self, root, old_path):
        self.root = root
        self.old_path = old_path
        self.new_name = sanitize_filename(old_path.name)
        self.new_path = old_path.with_name(self.new_name)
        self.old_res = res_path(root, old_path)
        self.new_res = res_path(root, self.new_path)
        self.text_updates = []   # list of (file_path, occurrences)
        self.bare_leftovers = [] # list of (file_path, occurrences) not auto-fixed
        self.import_sidecar = old_path.with_name(old_path.name + ".import")

    @property
    def already_compliant(self):
        return self.old_path.name == self.new_name

    @property
    def collides(self):
        return self.new_path.exists() and self.new_path != self.old_path


def scan_references(plan, replace_bare):
    for path in iter_project_files(plan.root):
        if path in (plan.old_path, plan.import_sidecar):
            continue
        text = read_text(path)
        if text is None:
            continue

        res_count = text.count(plan.old_res)
        if res_count:
            plan.text_updates.append((path, res_count))

        remainder = text.replace(plan.old_res, "") if res_count else text
        bare_count = remainder.count(plan.old_path.name)
        if bare_count:
            plan.bare_leftovers.append((path, bare_count))


def apply_references(plan, replace_bare):
    for path, _count in plan.text_updates:
        text = read_text(path)
        if text is None:
            continue
        new_text = text.replace(plan.old_res, plan.new_res)
        if replace_bare:
            new_text = new_text.replace(plan.old_path.name, plan.new_name)
        if new_text != text:
            write_text(path, new_text)

    if replace_bare:
        for path, _count in plan.bare_leftovers:
            text = read_text(path)
            if text is None:
                continue
            new_text = text.replace(plan.old_path.name, plan.new_name)
            if new_text != text:
                write_text(path, new_text)


def apply_rename(plan):
    use_git = git_tracked(plan.root, plan.old_path)
    move_file(plan.root, plan.old_path, plan.new_path, use_git)

    if plan.import_sidecar.is_file():
        new_sidecar = plan.new_path.with_name(plan.new_path.name + ".import")
        use_git_sidecar = git_tracked(plan.root, plan.import_sidecar)
        move_file(plan.root, plan.import_sidecar, new_sidecar, use_git_sidecar)
        text = read_text(new_sidecar)
        if text is not None:
            new_text = text.replace(plan.old_res, plan.new_res)
            if new_text != text:
                write_text(new_sidecar, new_text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("filenames", nargs="*", help="Paths (or unique bare filenames) to fix")
    parser.add_argument("--from-file", metavar="FILE", help="Read newline-separated paths from FILE")
    parser.add_argument("--scan", action="store_true", help="Auto-discover non-compliant audio files under the project root")
    parser.add_argument("--extensions", default=",".join(sorted(DEFAULT_SCAN_EXTENSIONS)),
                         help="Comma-separated extensions to consider for --scan (default: %(default)s)")
    parser.add_argument("--root", default=".", help="Project root (default: auto-detected from cwd)")
    parser.add_argument("--apply", action="store_true", help="Actually make changes (default is dry-run/report-only)")
    parser.add_argument("--force", action="store_true", help="On name collision, append a numeric suffix instead of skipping")
    parser.add_argument("--replace-bare-filename", action="store_true",
                         help="Also rewrite bare occurrences of the old filename without a res:// prefix (e.g. in comments/strings)")
    args = parser.parse_args()

    root = find_project_root(Path(args.root))

    targets = list(args.filenames)
    if args.from_file:
        targets.extend(
            line.strip() for line in Path(args.from_file).read_text(encoding="utf-8").splitlines() if line.strip()
        )
    if args.scan:
        extensions = {("." + e.lstrip(".")).lower() for e in args.extensions.split(",") if e.strip()}
        targets.extend(str(p) for p in scan_offenders(root, extensions))

    if not targets:
        parser.error("no filenames given -- pass paths, --from-file, or --scan")

    print(f"Project root: {root}")
    print("Mode: APPLY (files will be changed)" if args.apply else "Mode: DRY RUN (pass --apply to make changes)")
    print()

    had_errors = False
    seen_old_paths = set()

    for raw in targets:
        matches = resolve_target(root, raw)
        if not matches:
            print(f"[skip] '{raw}': no such file found under {root}")
            had_errors = True
            continue
        if len(matches) > 1:
            print(f"[skip] '{raw}': ambiguous, matches multiple files:")
            for m in matches:
                print(f"    {m.relative_to(root)}")
            print("  Pass a full relative path to disambiguate.")
            had_errors = True
            continue

        old_path = matches[0]
        if old_path in seen_old_paths:
            continue
        seen_old_paths.add(old_path)

        plan = RenamePlan(root, old_path)

        if plan.already_compliant:
            print(f"[ok]   {plan.old_res} -- already follows the naming convention")
            continue

        if plan.collides:
            if not args.force:
                print(f"[skip] {plan.old_res} -> {plan.new_name}: target already exists (use --force to auto-suffix)")
                had_errors = True
                continue
            base_stem, ext = os.path.splitext(plan.new_name)
            n = 2
            while plan.new_path.exists():
                plan.new_name = f"{base_stem}_{n}{ext}"
                plan.new_path = old_path.with_name(plan.new_name)
                plan.new_res = res_path(root, plan.new_path)
                n += 1

        scan_references(plan, args.replace_bare_filename)

        print(f"[rename] {plan.old_res}")
        print(f"      -> {plan.new_res}")
        if plan.text_updates:
            for path, count in plan.text_updates:
                print(f"    updates {count}x in {path.relative_to(root)}")
        else:
            print("    no static res:// references found")
        if plan.bare_leftovers and not args.replace_bare_filename:
            print("    NOTE: bare occurrences of the old filename (no res:// prefix) found but left as-is"
                  " (pass --replace-bare-filename to also rewrite these):")
            for path, count in plan.bare_leftovers:
                print(f"      {count}x in {path.relative_to(root)}")
        if plan.import_sidecar.is_file():
            print(f"    .import sidecar: {plan.import_sidecar.name} -> {plan.new_path.name}.import")

        if args.apply:
            apply_references(plan, args.replace_bare_filename)
            apply_rename(plan)
            print("    done.")
        print()

    if args.apply:
        print("Renamed files' Godot import cache (.godot/imported/) is stale; "
              "open the project in the editor once (or run a headless import) to let Godot regenerate it.")

    sys.exit(1 if had_errors else 0)


if __name__ == "__main__":
    main()
