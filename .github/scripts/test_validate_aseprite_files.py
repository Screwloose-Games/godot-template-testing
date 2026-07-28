"""
Tests for validate-aseprite-files.py -- run the EXACT logic CI runs, locally.

    python .github/scripts/test_validate_aseprite_files.py

No third-party dependencies (CI and most dev machines only have bare `python`),
so this is a plain-assert runner rather than pytest.

Aseprite fixtures are SYNTHESIZED rather than committed as binaries. The tag
chunk is the only part of the format this validator interprets, so building the
bytes here means the tests document the layout they depend on -- and a spec
change shows up as an obvious edit rather than an opaque blob swap.
"""

import contextlib
import importlib.util
import io
import os
import struct
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# Load the hyphenated module by path.
_spec = importlib.util.spec_from_file_location(
    "validate_aseprite_files", os.path.join(HERE, "validate-aseprite-files.py")
)
vaf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vaf)


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

def build_tags_chunk(tags):
    """tags: list of (name, from_frame, to_frame, direction, repeat)."""
    body = struct.pack("<H", len(tags)) + b"\x00" * 8
    for name, from_frame, to_frame, direction, repeat in tags:
        encoded = name.encode("utf-8")
        # 17 fixed bytes: from, to, direction, repeat, 6 reserved, 3 RGB, 1 extra
        body += struct.pack("<HHBH", from_frame, to_frame, direction, repeat)
        body += b"\x00" * 6
        body += b"\x00" * 3
        body += b"\x00"
        body += struct.pack("<H", len(encoded)) + encoded
    return struct.pack("<IH", len(body) + 6, vaf.TAGS_CHUNK) + body


def build_aseprite(path, tags, width=32, height=32, frames=1):
    chunks = build_tags_chunk(tags) if tags is not None else b""
    chunk_count = 1 if tags is not None else 0

    frame_body = chunks
    frame_header = struct.pack(
        "<IHHH", 16 + len(frame_body), vaf.FRAME_MAGIC, chunk_count, 100
    ) + b"\x00\x00" + struct.pack("<I", chunk_count)
    frame = frame_header + frame_body

    header = bytearray(128)
    struct.pack_into("<I", header, 0, 128 + len(frame))
    struct.pack_into("<H", header, 4, vaf.ASEPRITE_MAGIC)
    struct.pack_into("<H", header, 6, frames)
    struct.pack_into("<H", header, 8, width)
    struct.pack_into("<H", header, 10, height)
    struct.pack_into("<H", header, 12, 32)  # color depth: RGBA

    with open(path, "wb") as fh:
        fh.write(bytes(header) + frame)
    return path


def build_png(path, width, height):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(vaf.PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IEND", b""))
    return path


def touch_import(path):
    with open(path + ".import", "w", encoding="utf-8") as fh:
        fh.write("[remap]\n")


def errors_for(path):
    v = vaf.ArtFileValidator(path)
    v.validate()
    return v.errors


@contextlib.contextmanager
def rules(**flags):
    """Temporarily flip module-level rule switches.

    ENFORCE_TAGS_REQUIRED and ENFORCE_ONE_SHOT_REPEAT ship OFF because they
    contradict the art currently committed in these repos, so the tests covering
    them have to turn them on explicitly.
    """
    previous = {k: getattr(vaf, k) for k in flags}
    for k, v in flags.items():
        setattr(vaf, k, v)
    try:
        yield
    finally:
        for k, v in previous.items():
            setattr(vaf, k, v)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_parses_tags():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [("idle_loop", 0, 3, 0, 0), ("attack", 4, 7, 0, 1)])
        sprite = vaf.AsepriteFile(p)
        assert sprite.width == 32 and sprite.height == 32, (sprite.width, sprite.height)
        assert [t.name for t in sprite.tags] == ["idle_loop", "attack"]
        assert sprite.tags[1].frame_count == 4, sprite.tags[1].frame_count
        assert sprite.tags[0].is_loop is True
        assert sprite.tags[1].is_loop is False
    print("PASS test_parses_tags")


def test_clean_file_has_no_errors():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [("idle_loop", 0, 3, 0, 0), ("attack", 4, 7, 0, 1)])
        touch_import(p)
        assert errors_for(p) == [], errors_for(p)
    print("PASS test_clean_file_has_no_errors")


def test_missing_import_sidecar_flagged():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [("attack", 0, 1, 0, 1)])
        errs = errors_for(p)
        assert any("import sidecar" in e for e in errs), errs
    print("PASS test_missing_import_sidecar_flagged")


def test_untagged_file_accepted_by_default():
    # One file per animation with no tags is how the gladiator art is authored,
    # so the default configuration must not reject it.
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "gladiator_idle.aseprite")
        build_aseprite(p, [])
        touch_import(p)
        assert errors_for(p) == [], errors_for(p)
    print("PASS test_untagged_file_accepted_by_default")


def test_untagged_file_flagged_when_rule_enabled():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [])
        touch_import(p)
        with rules(ENFORCE_TAGS_REQUIRED=True):
            errs = errors_for(p)
        assert any("No animation tags" in e for e in errs), errs
    print("PASS test_untagged_file_flagged_when_rule_enabled")


def test_one_shot_repeat_enforced_when_rule_enabled():
    with tempfile.TemporaryDirectory() as d:
        # repeat=0 on a non-loop tag is the violation the issue template calls out.
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [("attack", 0, 3, 0, 0)])
        touch_import(p)
        with rules(ENFORCE_ONE_SHOT_REPEAT=True):
            errs = errors_for(p)
            assert any("one-shot" in e and "attack" in e for e in errs), errs

            # The same tag renamed to a loop is exempt.
            p2 = os.path.join(d, "walker.aseprite")
            build_aseprite(p2, [("attack_loop", 0, 3, 0, 0)])
            touch_import(p2)
            assert errors_for(p2) == [], errors_for(p2)

        # With the rule off (the shipped default) the original file is clean.
        assert errors_for(p) == [], errors_for(p)
    print("PASS test_one_shot_repeat_enforced_when_rule_enabled")


def test_duplicate_and_bad_tag_names():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [("attack", 0, 1, 0, 1), ("attack", 2, 3, 0, 1)])
        touch_import(p)
        assert any("Duplicate tag name" in e for e in errors_for(p)), errors_for(p)

        p2 = os.path.join(d, "golem.aseprite")
        build_aseprite(p2, [("Walk Right", 0, 1, 0, 1)])
        touch_import(p2)
        assert any("does not follow the naming convention" in e for e in errors_for(p2))
    print("PASS test_duplicate_and_bad_tag_names")


def test_filename_convention():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "Spider Enemy.aseprite")
        build_aseprite(p, [("attack", 0, 1, 0, 1)])
        touch_import(p)
        errs = errors_for(p)
        assert any("naming convention" in e for e in errs), errs
    print("PASS test_filename_convention")


def test_oversized_canvas_and_png():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "huge.aseprite")
        build_aseprite(p, [("attack", 0, 1, 0, 1)], width=2048, height=64)
        touch_import(p)
        assert any("exceeds the" in e for e in errors_for(p)), errors_for(p)

        png = build_png(os.path.join(d, "huge.png"), 4096, 16)
        touch_import(png)
        assert any("exceeds the" in e for e in errors_for(png)), errors_for(png)

        ok = build_png(os.path.join(d, "small.png"), 64, 64)
        touch_import(ok)
        assert errors_for(ok) == [], errors_for(ok)
    print("PASS test_oversized_canvas_and_png")


def test_path_convention():
    with tempfile.TemporaryDirectory() as d:
        good = os.path.join(d, "game", "spider", "animations")
        os.makedirs(good)
        p = os.path.join(good, "spider.aseprite")
        build_aseprite(p, [("attack", 0, 1, 0, 1)])
        touch_import(p)
        assert errors_for(p) == [], errors_for(p)

        bad = os.path.join(d, "game", "spider", "animations")
        p2 = os.path.join(bad, "wrong_name.aseprite")
        build_aseprite(p2, [("attack", 0, 1, 0, 1)])
        touch_import(p2)
        assert any("does not follow the convention" in e for e in errors_for(p2))

        # Outside game/ the convention does not apply.
        outside = os.path.join(d, "prototypes")
        os.makedirs(outside)
        p3 = os.path.join(outside, "whatever.aseprite")
        build_aseprite(p3, [("attack", 0, 1, 0, 1)])
        touch_import(p3)
        assert errors_for(p3) == [], errors_for(p3)
    print("PASS test_path_convention")


def test_not_an_aseprite_file():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "fake.aseprite")
        with open(p, "wb") as fh:
            fh.write(b"not an aseprite file, but long enough to pass the size check" * 4)
        touch_import(p)
        errs = errors_for(p)
        assert any("bad header magic" in e for e in errs), errs
    print("PASS test_not_an_aseprite_file")


def test_truncated_file_reports_cleanly():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "short.aseprite")
        with open(p, "wb") as fh:
            fh.write(b"\x00" * 10)
        touch_import(p)
        errs = errors_for(p)
        assert any("too short" in e for e in errs), errs
    print("PASS test_truncated_file_reports_cleanly")


def test_changed_files_json_filters_to_art():
    with tempfile.TemporaryDirectory() as d:
        payload = os.path.join(d, "changed.json")
        with open(payload, "w", encoding="utf-8") as fh:
            fh.write(
                '["game/spider/spider.aseprite", "README.md", "art/tile.png", '
                '"common/audio/sfx/hit.wav", "old/legacy.ase"]'
            )
        got = vaf.load_changed_files_json(payload)
        assert got == [
            "game/spider/spider.aseprite",
            "art/tile.png",
            "old/legacy.ase",
        ], got
    print("PASS test_changed_files_json_filters_to_art")


def test_escaped_json_gives_actionable_error():
    with tempfile.TemporaryDirectory() as d:
        payload = os.path.join(d, "escaped.txt")
        with open(payload, "w", encoding="utf-8") as fh:
            fh.write('[\\"game/spider/spider.aseprite\\"]')
        try:
            vaf.load_changed_files_json(payload)
        except SystemExit as e:
            assert "safe_output: false" in str(e), str(e)
        else:
            raise AssertionError("expected SystemExit on backslash-escaped JSON")
    print("PASS test_escaped_json_gives_actionable_error")


def test_report_renders():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "spider.aseprite")
        build_aseprite(p, [("idle_loop", 0, 3, 0, 0)])
        touch_import(p)
        text = str(vaf.ArtFileReport(p))
        assert "idle_loop" in text and "32x32" in text, text
    print("PASS test_report_renders")


def test_main_returns_error_flag():
    with tempfile.TemporaryDirectory() as d:
        # Hyphenated name violates the filename convention, which is on by default.
        bad = os.path.join(d, "example-gladiator.aseprite")
        build_aseprite(bad, [("attack", 0, 1, 0, 1)])
        touch_import(bad)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            has_errors = vaf.main([bad])
        assert has_errors is True

        good = os.path.join(d, "gladiator_idle.aseprite")
        build_aseprite(good, [("attack", 0, 1, 0, 1)])
        touch_import(good)
        with contextlib.redirect_stdout(io.StringIO()):
            assert vaf.main([good]) is False
    print("PASS test_main_returns_error_flag")


if __name__ == "__main__":
    test_parses_tags()
    test_clean_file_has_no_errors()
    test_missing_import_sidecar_flagged()
    test_untagged_file_accepted_by_default()
    test_untagged_file_flagged_when_rule_enabled()
    test_one_shot_repeat_enforced_when_rule_enabled()
    test_duplicate_and_bad_tag_names()
    test_filename_convention()
    test_oversized_canvas_and_png()
    test_path_convention()
    test_not_an_aseprite_file()
    test_truncated_file_reports_cleanly()
    test_changed_files_json_filters_to_art()
    test_escaped_json_gives_actionable_error()
    test_report_renders()
    test_main_returns_error_flag()
    print("\nAll validate-aseprite-files.py tests passed.")
