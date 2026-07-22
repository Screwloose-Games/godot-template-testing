"""
Tests for validate-audio-files.py -- run the EXACT logic CI runs, locally.

    python .github/scripts/test_validate_audio_files.py

No third-party dependencies (CI and most dev machines only have bare `python`),
so this is a plain-assert runner rather than pytest.

The two fixtures under test-fixtures/ are real payloads captured from CI:
  - changed_files_escaped.txt : what tj-actions/changed-files emits with the
    default `safe_output: true` -- backslash-escaped, INVALID JSON. This is the
    payload that crashed the check. The test asserts we now fail on it with an
    actionable message instead of a raw traceback.
  - changed_files_clean.json  : what it emits with `safe_output: false` -- valid
    JSON. The test asserts we parse it and recover every audio path intact,
    special characters (spaces, !, ', parentheses) and all.
"""

import contextlib
import importlib.util
import io
import os
import tempfile
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "test-fixtures")

# Load the hyphenated module by path.
_spec = importlib.util.spec_from_file_location(
    "validate_audio_files", os.path.join(HERE, "validate-audio-files.py")
)
vaf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vaf)


# Names captured from the real failing PR, plus the one already-compliant file.
EXPECTED_PATHS = [
    "common/audio/music/I've Got Your Back! (Intro).ogg",
    "common/audio/music/I've Got Your Back! (Main Loop).ogg",
    "common/audio/music/Outside the Colosseum.ogg",
    "common/audio/music/To Suffer a Loss (Game Over).ogg",
    "common/audio/music/Victorious.ogg",
    "common/audio/music/We're Bird People Now.ogg",
    "common/audio/sfx/cheerwhitenoise.ogg",  # the only compliant name in the set
]

_tests = []


def test(fn):
    _tests.append(fn)
    return fn


@test
def clean_json_parses_and_keeps_every_path():
    got = vaf.load_changed_files_json(os.path.join(FIXTURES, "changed_files_clean.json"))
    assert got == EXPECTED_PATHS, got


@test
def escaped_json_fails_with_actionable_message():
    # This is the exact regression: safe_output:true output must not silently
    # crash -- it must raise SystemExit mentioning safe_output.
    try:
        vaf.load_changed_files_json(os.path.join(FIXTURES, "changed_files_escaped.txt"))
    except SystemExit as e:
        assert "safe_output" in str(e), f"unhelpful error: {e}"
    else:
        raise AssertionError("escaped JSON should have raised SystemExit")


@test
def json_loader_filters_non_audio():
    with tempfile.TemporaryDirectory() as d:
        payload = os.path.join(d, "p.json")
        with open(payload, "w", encoding="utf-8") as f:
            f.write('["a/sound.ogg","b/readme.md","c/tex.png","d/loop.WAV"]')
        got = vaf.load_changed_files_json(payload)
        assert got == ["a/sound.ogg", "d/loop.WAV"], got  # case-insensitive ext


@test
def bad_names_are_flagged_good_names_pass():
    checks = {
        "Ive Got Your Back (intro)!.wav": False,   # spaces, parens, !
        "i've_got_your_back.mp3": False,           # apostrophe
        "some-file_name.wav": False,               # hyphen
        "UPPER.ogg": False,                        # uppercase
        "name.OGG": False,                         # uppercase extension
        "ive_got_your_back_intro.ogg": True,       # the spec's own example
        "ui_click.wav": True,
        "music_title_screen_loop2.ogg": True,      # digits ok
    }
    for name, should_pass in checks.items():
        v = vaf.AudioFileValidator(name)
        basename = os.path.basename(v.file_path)
        ok = bool(vaf.FILENAME_PATTERN.match(basename))
        assert ok == should_pass, f"{name}: expected pass={should_pass}, got {ok}"


@test
def main_returns_true_when_a_file_is_bad_and_false_when_all_good():
    with tempfile.TemporaryDirectory() as d:
        bad = os.path.join(d, "Bad Name!.ogg")
        good = os.path.join(d, "good_name.ogg")
        for p in (bad, good):
            with open(p, "w", encoding="utf-8") as f:
                f.write("placeholder")
        assert vaf.main([bad, good]) is True
        assert vaf.main([good]) is False


@test
def ogg_and_mp3_do_not_crash_and_skip_wav_checks():
    # A .ogg that is not a WAV container must not raise (the original bug).
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "not_a_wav.ogg")
        with open(p, "w", encoding="utf-8") as f:
            f.write("OggS not really ogg")
        report = vaf.AudioFileReport(p)
        assert report.sample_rate == "N/A"
        assert report.errors == []  # compliant name, no WAV checks applied


@test
def real_wav_technical_checks_still_run():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "tone.wav")
        with wave.open(p, "wb") as w:
            w.setnchannels(2)          # spec wants 1 -> should be flagged
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(b"\x00\x00\x00\x00" * 100)
        v = vaf.AudioFileValidator(p)
        v.validate()
        assert any("Channel count mismatch" in e for e in v.errors), v.errors


def run():
    failures = 0
    for fn in _tests:
        try:
            # Suppress the validator's own report output so PASS/FAIL stays readable.
            with contextlib.redirect_stdout(io.StringIO()):
                fn()
            print(f"PASS {fn.__name__}")
        except Exception as e:
            failures += 1
            print(f"FAIL {fn.__name__}: {e}")
    print()
    print(f"{len(_tests) - failures}/{len(_tests)} passed")
    return failures


if __name__ == "__main__":
    raise SystemExit(1 if run() else 0)
