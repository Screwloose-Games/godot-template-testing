# Run this with: python .github/scripts/validate-aseprite-files.py --file-list art_files.txt
# (positional args also work for one-off manual checks: ... validate-aseprite-files.py foo.aseprite bar.png)
#
# NOTE: don't invoke this via `$(cat art_files.txt)` -- unquoted shell command
# substitution word-splits on spaces, which silently corrupts any filename that
# contains a space (exactly the kind of filename this script needs to flag).
# --file-list reads the file directly, one path per line, with no shell involved.
#
# This deliberately has ZERO third-party dependencies, matching
# validate-audio-files.py. Aseprite itself is not installable in CI -- it ships
# as a paid binary or a source build -- but it doesn't need to be: the .aseprite
# format is a documented binary layout, so the header and tag chunks are read
# directly with `struct`. PNG dimensions come out of the IHDR chunk the same way,
# so Pillow isn't needed either.
#
# Rules come from .github/ISSUE_TEMPLATE/create_aseprite_animations.yaml, which
# already states them as acceptance criteria.

import argparse
import json
import os
import re
import struct
import sys

# ---------------------------------------------------------------------------
# Configuration -- every rule below can be turned off from here.
# ---------------------------------------------------------------------------

ASEPRITE_EXTENSIONS = (".aseprite", ".ase")
IMAGE_EXTENSIONS = (".png",)
ALL_EXTENSIONS = ASEPRITE_EXTENSIONS + IMAGE_EXTENSIONS

# Same convention as the audio validator: lowercase letters/numbers only,
# underscores as the sole word separator, lowercase extension.
FILENAME_PATTERN = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*\.[a-z0-9]+$")

# Tag names follow the same casing rule, minus the extension.
TAG_NAME_PATTERN = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*$")

# Inherited from resize_large_pngs.py, which capped width at 1024. That script
# enforced the limit by destructively rewriting artist source files in place;
# here the same constraint is a blocking check that leaves the file alone.
MAX_TEXTURE_DIMENSION = 1024

# --- The two rules below are OFF by default. Read this before switching them on.
#
# The Aseprite issue template describes one file per game object containing every
# animation as a tag. The art actually in these repos does not work that way:
# prototypes/galdiator-animations/ has one file PER animation
# (gladiator_idle.aseprite, gladiator_attack.aseprite, ...) with zero tags, and
# game-planner/spider_enemy.aseprite tags `idle` and `climb` as repeat=0 because
# they loop -- without any _loop suffix.
#
# Both rules are therefore correct against the written convention and wrong
# against the committed art. Turning either on without first migrating the
# existing files will fail every art PR. Flip them to True once the art and the
# convention actually agree.

# "Each animation is defined as a tag within the .aseprite file."
# When False, an untagged file is accepted (one-file-per-animation layout);
# tags that DO exist are still checked for uniqueness and naming.
ENFORCE_TAGS_REQUIRED = False

# "Tags for one-shot animations are configured with repeat: 1."
# A tag is treated as looping -- and therefore exempt -- when its name ends in
# LOOP_TAG_SUFFIX. Every other tag must declare repeat == 1.
ENFORCE_ONE_SHOT_REPEAT = False
LOOP_TAG_SUFFIX = "_loop"

# "An .aseprite file is created and saved in the correct directory:
#  assets/art/2d/{game_object}/animations/{game_object}.aseprite"
# Enforced as: the file's stem must match its parent or grandparent directory,
# which accepts both assets/art/2d/spider/spider.aseprite and
# assets/art/2d/spider/animations/spider.aseprite.
ENFORCE_PATH_CONVENTION = True
PATH_CONVENTION_ROOT = "assets/art/2d"

# "Submit a pull request with the .aseprite file, `.import` file, and all changes."
REQUIRE_IMPORT_SIDECAR = True

# ---------------------------------------------------------------------------
# Binary format parsing
# ---------------------------------------------------------------------------

ASEPRITE_MAGIC = 0xA5E0
FRAME_MAGIC = 0xF1FA
TAGS_CHUNK = 0x2018

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class AsepriteParseError(Exception):
    """Raised when a file does not conform to the .aseprite binary layout."""


class AsepriteTag:
    __slots__ = ("name", "from_frame", "to_frame", "direction", "repeat")

    def __init__(self, name, from_frame, to_frame, direction, repeat):
        self.name = name
        self.from_frame = from_frame
        self.to_frame = to_frame
        self.direction = direction
        self.repeat = repeat

    @property
    def frame_count(self):
        return self.to_frame - self.from_frame + 1

    @property
    def is_loop(self):
        return self.name.endswith(LOOP_TAG_SUFFIX)


class AsepriteFile:
    """Minimal reader for the .aseprite container.

    Only the header and the tags chunk are interpreted. Cel chunks carry
    zlib-compressed pixel data, but chunks are walked by their declared size, so
    nothing needs decompressing to reach the tags.
    """

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as fh:
            self.data = fh.read()
        self.width = 0
        self.height = 0
        self.frame_count = 0
        self.color_depth = 0
        self.tags = []
        self._parse()

    def _parse(self):
        data = self.data
        if len(data) < 128:
            raise AsepriteParseError(
                f"file is {len(data)} bytes, too short to contain a 128-byte header"
            )

        magic = struct.unpack_from("<H", data, 4)[0]
        if magic != ASEPRITE_MAGIC:
            raise AsepriteParseError(
                f"bad header magic 0x{magic:04X} (expected 0x{ASEPRITE_MAGIC:04X}) "
                "-- this is not an Aseprite file"
            )

        self.frame_count = struct.unpack_from("<H", data, 6)[0]
        self.width = struct.unpack_from("<H", data, 8)[0]
        self.height = struct.unpack_from("<H", data, 10)[0]
        self.color_depth = struct.unpack_from("<H", data, 12)[0]

        offset = 128
        for frame_index in range(self.frame_count):
            if offset + 16 > len(data):
                raise AsepriteParseError(
                    f"truncated before frame {frame_index} header"
                )
            frame_bytes, frame_magic, old_chunks, _duration = struct.unpack_from(
                "<IHHH", data, offset
            )
            if frame_magic != FRAME_MAGIC:
                raise AsepriteParseError(
                    f"bad frame magic 0x{frame_magic:04X} at frame {frame_index}"
                )
            new_chunks = struct.unpack_from("<I", data, offset + 12)[0]
            # Files written before the chunk count widened to 32 bits leave the
            # new field at zero and carry the real count in the old 16-bit one.
            chunk_count = new_chunks if new_chunks != 0 else old_chunks

            frame_end = offset + frame_bytes
            chunk_offset = offset + 16
            for _ in range(chunk_count):
                if chunk_offset + 6 > len(data):
                    raise AsepriteParseError("truncated inside a chunk header")
                chunk_size, chunk_type = struct.unpack_from("<IH", data, chunk_offset)
                if chunk_size < 6:
                    raise AsepriteParseError(
                        f"chunk declares an impossible size of {chunk_size} bytes"
                    )
                if chunk_type == TAGS_CHUNK:
                    self._parse_tags(chunk_offset + 6, chunk_offset + chunk_size)
                chunk_offset += chunk_size
                if chunk_offset > frame_end:
                    break
            offset = frame_end

    def _parse_tags(self, start, end):
        data = self.data
        if start + 10 > end:
            return
        tag_count = struct.unpack_from("<H", data, start)[0]
        cursor = start + 2 + 8  # tag count, then 8 reserved bytes

        for _ in range(tag_count):
            # 17 fixed bytes, then a length-prefixed UTF-8 name.
            # Aseprite 1.3 introduced the `repeat` WORD by claiming the first two
            # bytes of what 1.2 wrote as eight reserved zero bytes, so the fixed
            # block is 17 bytes wide in both versions and a 1.2 file simply
            # reports repeat == 0 ("unspecified").
            if cursor + 17 > end:
                raise AsepriteParseError("truncated inside the tags chunk")
            from_frame, to_frame, direction, repeat = struct.unpack_from(
                "<HHBH", data, cursor
            )
            cursor += 17

            if cursor + 2 > end:
                raise AsepriteParseError("truncated before a tag name length")
            name_length = struct.unpack_from("<H", data, cursor)[0]
            cursor += 2
            if cursor + name_length > end:
                raise AsepriteParseError("truncated inside a tag name")
            name = data[cursor:cursor + name_length].decode("utf-8", errors="replace")
            cursor += name_length

            self.tags.append(
                AsepriteTag(name, from_frame, to_frame, direction, repeat)
            )


def read_png_dimensions(path):
    """Return (width, height) from a PNG's IHDR chunk, which is always first."""
    with open(path, "rb") as fh:
        head = fh.read(24)
    if len(head) < 24 or not head.startswith(PNG_SIGNATURE):
        raise AsepriteParseError("not a PNG file (bad signature)")
    if head[12:16] != b"IHDR":
        raise AsepriteParseError("first PNG chunk is not IHDR")
    width, height = struct.unpack_from(">II", head, 16)
    return width, height


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

class ArtFileValidator:
    def __init__(self, file_path):
        self.file_path = file_path
        self.errors = []

    def validation_results(self):
        return "\n".join(self.errors) if self.errors else "No errors found."

    def validate(self):
        if not os.path.isfile(self.file_path):
            self.errors.append(f"File does not exist: {self.file_path}")
            return False

        basename = os.path.basename(self.file_path)
        if not FILENAME_PATTERN.match(basename):
            self.errors.append(
                f"Filename '{basename}' does not follow the naming convention: use only "
                "lowercase letters, numbers, and underscores (underscores separate words); "
                "no spaces, apostrophes, parentheses, exclamation marks, hyphens, or other "
                "special characters; the extension must also be lowercase "
                "(e.g. 'spider_enemy.aseprite')"
            )

        lowered = self.file_path.lower()
        if lowered.endswith(ASEPRITE_EXTENSIONS):
            self._validate_aseprite()
        elif lowered.endswith(IMAGE_EXTENSIONS):
            self._validate_png()

        return not self.errors

    def _validate_import_sidecar(self):
        if not REQUIRE_IMPORT_SIDECAR:
            return
        sidecar = self.file_path + ".import"
        if not os.path.isfile(sidecar):
            self.errors.append(
                f"Missing Godot import sidecar: expected '{os.path.basename(sidecar)}' "
                "alongside the asset. Commit the .import file with the asset so the "
                "project imports cleanly on a fresh clone."
            )

    def _validate_path_convention(self):
        if not ENFORCE_PATH_CONVENTION:
            return
        normalized = self.file_path.replace("\\", "/")
        parts = normalized.split("/")
        # Prefix match, not segment membership: the root is a multi-segment path
        # ("assets/art/2d"), so `root in parts` would never be true and would
        # silently exempt every file. Anchored to a path boundary so a sibling
        # directory like assets/art/2d_wip/ is not swept in.
        root = PATH_CONVENTION_ROOT.strip("/")
        if f"/{root}/" not in f"/{normalized}/":
            # Assets outside the 2D art tree (fixtures, tooling samples) are exempt.
            return

        stem = os.path.splitext(os.path.basename(normalized))[0]
        parent = parts[-2] if len(parts) >= 2 else ""
        grandparent = parts[-3] if len(parts) >= 3 else ""
        if stem not in (parent, grandparent):
            self.errors.append(
                f"Path does not follow the convention: '{normalized}' should live at "
                f"{PATH_CONVENTION_ROOT}/{stem}/{stem}.aseprite or "
                f"{PATH_CONVENTION_ROOT}/{stem}/animations/{stem}.aseprite -- the filename "
                f"must match its game object directory (found '{parent}')"
            )

    def _validate_aseprite(self):
        self._validate_import_sidecar()
        self._validate_path_convention()

        try:
            sprite = AsepriteFile(self.file_path)
        except AsepriteParseError as e:
            self.errors.append(f"Could not read Aseprite file: {self.file_path} ({e})")
            return
        except Exception as e:  # noqa: BLE001 - report rather than crash the run
            self.errors.append(
                f"Unexpected error reading Aseprite file: {self.file_path} ({e})"
            )
            return

        if sprite.width > MAX_TEXTURE_DIMENSION or sprite.height > MAX_TEXTURE_DIMENSION:
            self.errors.append(
                f"Canvas is {sprite.width}x{sprite.height}, which exceeds the "
                f"{MAX_TEXTURE_DIMENSION}px limit in {self.file_path}"
            )

        if not sprite.tags:
            if ENFORCE_TAGS_REQUIRED:
                self.errors.append(
                    f"No animation tags found in {self.file_path}. Each animation must be "
                    "defined as a tag in the Aseprite file -- an untagged frame range cannot "
                    "be imported as a named animation."
                )
            # Untagged is a valid one-file-per-animation layout; nothing further
            # to check without tags.
            return

        seen = {}
        for tag in sprite.tags:
            if not TAG_NAME_PATTERN.match(tag.name):
                self.errors.append(
                    f"Tag name '{tag.name}' does not follow the naming convention: "
                    "lowercase letters, numbers, and underscores only "
                    f"(in {self.file_path})"
                )
            if tag.name in seen:
                self.errors.append(
                    f"Duplicate tag name '{tag.name}' in {self.file_path} -- tag names "
                    "become animation names and must be unique"
                )
            seen[tag.name] = True

            if ENFORCE_ONE_SHOT_REPEAT and not tag.is_loop and tag.repeat != 1:
                self.errors.append(
                    f"Tag '{tag.name}' is a one-shot animation but declares repeat="
                    f"{tag.repeat} (expected 1) in {self.file_path}. Set the tag's repeat "
                    f"to 1, or rename it to '{tag.name}{LOOP_TAG_SUFFIX}' if it is meant "
                    "to loop."
                )

    def _validate_png(self):
        self._validate_import_sidecar()
        try:
            width, height = read_png_dimensions(self.file_path)
        except AsepriteParseError as e:
            self.errors.append(f"Could not read PNG: {self.file_path} ({e})")
            return
        except Exception as e:  # noqa: BLE001
            self.errors.append(f"Unexpected error reading PNG: {self.file_path} ({e})")
            return

        if width > MAX_TEXTURE_DIMENSION or height > MAX_TEXTURE_DIMENSION:
            self.errors.append(
                f"Image is {width}x{height}, which exceeds the "
                f"{MAX_TEXTURE_DIMENSION}px limit in {self.file_path}"
            )


class ArtFileReport:
    """Human-readable summary of one art file, used for the PR comment."""

    def __init__(self, file_path):
        self.file_path = file_path
        self.kind = "Aseprite" if file_path.lower().endswith(ASEPRITE_EXTENSIONS) else "Image"
        self.file_size = (
            os.path.getsize(file_path) / 1024.0 if os.path.isfile(file_path) else 0.0
        )
        self.dimensions = "N/A"
        self.frames = "N/A"
        self.tags = []

        try:
            if file_path.lower().endswith(ASEPRITE_EXTENSIONS):
                sprite = AsepriteFile(file_path)
                self.dimensions = f"{sprite.width}x{sprite.height}"
                self.frames = sprite.frame_count
                self.tags = sprite.tags
            elif file_path.lower().endswith(IMAGE_EXTENSIONS):
                width, height = read_png_dimensions(file_path)
                self.dimensions = f"{width}x{height}"
        except Exception:  # noqa: BLE001 - the validator reports the real error
            pass

        validator = ArtFileValidator(file_path)
        validator.validate()
        self.errors = list(validator.errors)

    def __str__(self):
        if self.tags:
            tag_lines = "\n".join(
                f"      - {t.name}: frames {t.from_frame}-{t.to_frame} "
                f"({t.frame_count}), repeat {t.repeat}"
                for t in self.tags
            )
        else:
            tag_lines = "      (none)"
        return (
            f"{self.kind} File Report:\n"
            f"    File Path: `{self.file_path}`\n"
            f"    File Size: {self.file_size:.2f} KB\n"
            f"    Dimensions: {self.dimensions}\n"
            f"    Frames: {self.frames}\n"
            f"    Tags:\n{tag_lines}\n"
            f"    Errors: {self.errors}\n"
        )


def load_changed_files_json(path):
    """Parse a tj-actions/changed-files `all_changed_files` JSON array (json: true)
    and return the art-file paths within it.

    The action MUST be configured with `safe_output: false`; otherwise it
    backslash-escapes special characters (spaces, (), !, ', ...) even in JSON
    mode, producing invalid JSON like [\\"a\\",\\"b\\"]. We detect that case and
    raise an actionable error instead of a raw JSONDecodeError.
    """
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    try:
        files = json.loads(raw)
    except json.JSONDecodeError as e:
        hint = ""
        if '\\"' in raw or raw.lstrip().startswith("[\\"):
            hint = (
                "\nThe input looks backslash-escaped. The tj-actions/changed-files "
                "step must set `safe_output: false` so it emits valid JSON."
            )
        raise SystemExit(f"Could not parse changed-files JSON from {path}: {e}{hint}")
    if not isinstance(files, list):
        raise SystemExit(f"Expected a JSON array in {path}, got {type(files).__name__}")
    return [f for f in files if isinstance(f, str) and f.lower().endswith(ALL_EXTENSIONS)]


def main(art_files):
    """Validate the given art files. Returns True if any file had errors."""
    validators = [ArtFileValidator(file_path) for file_path in art_files]
    reports = [ArtFileReport(file_path) for file_path in art_files]
    has_errors = False
    for validator in validators:
        if not validator.validate():
            has_errors = True
            print(f"Validation failed for {validator.file_path}:")
            for error in validator.errors:
                print(f" - {error}")
            print()
        else:
            print(f"Validation succeeded for {validator.file_path}")
    for report in reports:
        print(report)

    # GITHUB_OUTPUT is only set inside GitHub Actions; skip it for local runs/tests.
    out_path = os.environ.get("GITHUB_OUTPUT")
    if out_path and os.path.exists(out_path):
        with open(out_path, "a") as fh:
            reports_str = "\n\n".join([str(report) for report in reports])
            metadata = {
                "aseprite_reports": reports_str,
            }
            print("metadata<<EOF", file=fh)
            print(json.dumps(metadata, indent=2), file=fh)
            print("EOF", file=fh)
            print(f"has_errors={'true' if has_errors else 'false'}", file=fh)

    return has_errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("art_files", nargs="*", help="Aseprite or PNG file paths to validate")
    parser.add_argument("--file-list", metavar="FILE",
                        help="Read newline-separated art file paths from FILE (safe for filenames containing spaces)")
    parser.add_argument("--changed-files-json", metavar="FILE",
                        help="Read a tj-actions/changed-files JSON array from FILE, filter to art files, and validate them. "
                             "This is the exact code path CI uses -- point it at a saved payload to reproduce CI locally.")
    args = parser.parse_args()

    art_files = list(args.art_files)
    if args.file_list:
        with open(args.file_list, "r", encoding="utf-8") as f:
            art_files.extend(line for line in f.read().splitlines() if line.strip())
    if args.changed_files_json:
        art_files.extend(load_changed_files_json(args.changed_files_json))

    if not art_files:
        # No art files to check (e.g. the changed-files list had none) -- not an error.
        print("No Aseprite or image files to validate.")
        sys.exit(0)

    sys.exit(1 if main(art_files) else 0)
