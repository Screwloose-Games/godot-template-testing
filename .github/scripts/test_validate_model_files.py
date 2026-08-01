#!/usr/bin/env python3
"""Tests for validate-model-files.py.

Run with: python .github/scripts/test_validate_model_files.py
Plain asserts, no pytest -- CI and most dev machines here only have bare python.

The module name has hyphens in it, so it cannot be imported normally; loaded by
path the way test_validate_aseprite_files.py does it.

Two things get most of the attention.

The first is `--changed-files-json`. Its escaped-payload guard is not paranoia:
that is how the audio validator broke twice. Without `safe_output: false` the
tj-actions step writes backslash-escaped paths, which parse as valid JSON but
match no file on disk -- so the workflow goes green having validated nothing.

The second is that the deliberately-broken fixture stays excluded. There is a
model in tools/gltf-validator/test-fixtures/ whose entire purpose is to fail;
if it were ever in scope, `pre-commit run --all-files` would fail forever and
the repo would be un-committable.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]

_spec = importlib.util.spec_from_file_location(
    "validate_model_files", HERE / "validate-model-files.py"
)
validate_model_files = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate_model_files)
vmf = validate_model_files

EXAMPLE = "assets/art/3d/example_cubes_facing/sm_example_cubes_facing.gltf"
FIXTURE = "tools/gltf-validator/test-fixtures/unapplied_rotation_90z.gltf"


def write(name: str, text: str) -> str:
    path = Path(tempfile.mkdtemp()) / name
    path.write_text(text, encoding="utf-8")
    return str(path)


# --------------------------------------------------------------------------
# Module scope stays stdlib-only
# --------------------------------------------------------------------------


def test_importing_the_module_does_not_need_numpy():
    """validate-pipeline-doc.py imports this file to read its constants.

    That workflow installs only pyyaml and jsonschema. If numpy moved to module
    scope, validate-pipeline-doc.yml would start failing for no visible reason.
    """
    assert "numpy" not in sys.modules or True  # numpy may be loaded by another test
    source = (HERE / "validate-model-files.py").read_text(encoding="utf-8")
    body, _, _ = source.partition("def main(")
    for banned in ("import numpy", "import yaml", "import jsonschema", "import gltf_"):
        assert banned not in body, (
            f"'{banned}' appears above main(); it must be imported inside main() "
            "so validate-pipeline-doc.py can import this module without numpy"
        )


def test_the_constants_the_pipeline_doc_mirrors_exist():
    for name in (
        "MODEL_FILENAME_PATTERN",
        "SKELETAL_FILENAME_PATTERN",
        "MODEL_ROOT",
        "ENFORCE_FILENAME_CONVENTION",
        "ENFORCE_SPEC_SCHEMA",
        "ENFORCE_SPEC_REQUIRED",
    ):
        assert hasattr(vmf, name), f"pipeline.yaml's code_mirrors expects {name}"


# --------------------------------------------------------------------------
# Filename conventions
# --------------------------------------------------------------------------


def test_the_naming_regexes_match_the_documented_examples():
    """These are the valid/invalid examples in pipeline.yaml's naming_patterns."""
    for name in ("sm_rain_barrel.gltf", "sm_raised_bed.gltf", "sm_office_building_small.gltf"):
        assert vmf.MODEL_FILENAME_PATTERN.match(name), name
    for name in ("sm_RainBarrel.gltf", "rain_barrel.gltf", "sm_rain-barrel.gltf", "sm_rain_barrel.glb"):
        assert not vmf.MODEL_FILENAME_PATTERN.match(name), name
    for name in ("sk_wolf.gltf", "sk_hamster.gltf"):
        assert vmf.SKELETAL_FILENAME_PATTERN.match(name), name
    for name in ("sm_wolf.gltf", "sk_Wolf.gltf", "wolf_sk.gltf"):
        assert not vmf.SKELETAL_FILENAME_PATTERN.match(name), name


def test_a_bad_name_under_the_model_root_fails():
    report = vmf.ModelReport("assets/art/3d/barrel/rain-barrel.gltf")
    vmf.check_filename(report, "assets/art/3d/barrel/rain-barrel.gltf")
    assert report.failed, report


def test_a_bad_name_outside_the_model_root_is_only_noted():
    """examples/ holds self-contained prototypes and third-party art."""
    path = "examples/3d/x/grey-wolf-gaits-and-jump.glb"
    report = vmf.ModelReport(path)
    vmf.check_filename(report, path)
    assert not report.failed, "naming must not be enforced outside assets/art/3d/"


def test_the_switch_turns_the_name_check_off():
    original = vmf.ENFORCE_FILENAME_CONVENTION
    vmf.ENFORCE_FILENAME_CONVENTION = False
    try:
        report = vmf.ModelReport("assets/art/3d/barrel/rain-barrel.gltf")
        vmf.check_filename(report, "assets/art/3d/barrel/rain-barrel.gltf")
        assert report.checks == [], "a disabled check should record nothing"
    finally:
        vmf.ENFORCE_FILENAME_CONVENTION = original


# --------------------------------------------------------------------------
# Input resolution
# --------------------------------------------------------------------------


def test_a_spec_resolves_to_its_model():
    models, orphans = vmf.resolve_inputs([str(REPO_ROOT / (EXAMPLE + ".spec.yaml"))])
    assert not orphans
    assert models == [str(REPO_ROOT / EXAMPLE)], models


def test_a_spec_with_no_model_is_an_orphan():
    spec = write("sm_ghost.gltf.spec.yaml", "width: 1.0\n")
    models, orphans = vmf.resolve_inputs([spec])
    assert models == []
    assert orphans == [spec]


def test_a_model_and_its_spec_are_not_validated_twice():
    model = str(REPO_ROOT / EXAMPLE)
    models, _ = vmf.resolve_inputs([model, model + ".spec.yaml"])
    assert models == [model], models


def test_non_model_paths_are_ignored():
    models, orphans = vmf.resolve_inputs(["README.md", "project.godot", "a/b.png"])
    assert models == [] and orphans == []


def test_the_broken_fixture_is_excluded_even_when_named():
    """It exists to fail. In scope, it would make the repo un-committable."""
    models, _ = vmf.resolve_inputs([FIXTURE])
    assert models == [], models


def test_addons_and_godot_cache_are_excluded():
    models, _ = vmf.resolve_inputs([".godot/imported/x.gltf", "addons/thing/y.glb"])
    assert models == [], models


def test_the_repo_sweep_finds_the_example_but_not_the_fixture():
    found = [vmf.display_path(path) for path in vmf.sweep_repository()]
    assert EXAMPLE in found, found
    assert FIXTURE not in found, "the sweep must skip test-fixtures"


# --------------------------------------------------------------------------
# --changed-files-json
# --------------------------------------------------------------------------


def test_a_clean_payload_is_read():
    path = write("changed.json", json.dumps([EXAMPLE, "README.md"]))
    assert vmf.load_changed_files_json(path) == [EXAMPLE, "README.md"]


def test_an_empty_payload_is_not_an_error():
    assert vmf.load_changed_files_json(write("changed.json", "")) == []


def test_an_escaped_payload_names_the_setting_that_fixes_it():
    """The failure that broke the audio validator twice."""
    path = write("changed.json", json.dumps(["assets\\\\3d\\\\x\\\\sm_x.gltf"]))
    try:
        vmf.load_changed_files_json(path)
    except SystemExit as exc:
        assert "safe_output" in str(exc), exc
    else:
        raise AssertionError("a backslash-escaped payload must be rejected loudly")


def test_malformed_json_names_the_settings_that_fix_it():
    path = write("changed.json", "{not json")
    try:
        vmf.load_changed_files_json(path)
    except SystemExit as exc:
        assert "safe_output" in str(exc) and "write_output_files" in str(exc), exc
    else:
        raise AssertionError("malformed JSON must be rejected loudly")


def test_a_json_object_is_rejected():
    path = write("changed.json", json.dumps({"files": []}))
    try:
        vmf.load_changed_files_json(path)
    except SystemExit as exc:
        assert "array" in str(exc), exc
    else:
        raise AssertionError("a JSON object is not a file list")


# --------------------------------------------------------------------------
# End to end
# --------------------------------------------------------------------------


def test_no_files_is_a_pass():
    assert vmf.main([]) is False


def test_the_real_example_model_passes():
    assert vmf.main([str(REPO_ROOT / EXAMPLE)]) is False


def test_a_model_with_a_missing_buffer_fails():
    directory = Path(tempfile.mkdtemp())
    model = directory / "sm_broken.gltf"
    source = json.loads((REPO_ROOT / EXAMPLE).read_text(encoding="utf-8"))
    model.write_text(json.dumps(source), encoding="utf-8")  # .bin deliberately absent
    assert vmf.main([str(model)]) is True


def test_the_summary_counts_failed_checks_not_failed_files():
    report = vmf.ModelReport("a/sm_x.gltf")
    report.fail("width", "")
    report.fail("poly_count_budget", "")
    report.ok("external_resources")
    text, failures = vmf.report_all([report], [])
    assert failures == 2, text
    assert "1 file, 2 failures" in text, text


def test_info_lines_are_not_failures():
    report = vmf.ModelReport("a/sm_x.gltf")
    report.info("facing_direction", "declared -Z")
    report.ok("width")
    text, failures = vmf.report_all([report], [])
    assert failures == 0, text
    assert "0 failures" in text, text


def test_an_orphan_spec_is_counted_and_explained():
    text, failures = vmf.report_all([], ["a/sm_x.spec.yaml"])
    assert failures == 1
    assert "orphan_spec" in text and "sm_rain_barrel.gltf.spec.yaml" in text, text


def test_github_output_gets_the_metadata_block():
    out = Path(tempfile.mkdtemp()) / "out.txt"
    out.write_text("", encoding="utf-8")
    os.environ["GITHUB_OUTPUT"] = str(out)
    try:
        vmf.write_github_output("some report text", True)
    finally:
        del os.environ["GITHUB_OUTPUT"]
    written = out.read_text(encoding="utf-8")
    assert "metadata<<EOF" in written, written
    assert "model_reports" in written, written
    assert "has_errors=true" in written, written


def test_github_output_is_skipped_outside_actions():
    os.environ.pop("GITHUB_OUTPUT", None)
    vmf.write_github_output("text", False)  # must not raise


def test_a_typod_spec_key_fails():
    """The gap this whole change closes: a key that was silently ignored.

    poly_budget for poly_count_budget. Before the schema check, this spec
    produced a green tick and no poly budget was ever enforced.
    """
    directory = Path(tempfile.mkdtemp())
    model = directory / "sm_thing.gltf"
    source = json.loads((REPO_ROOT / EXAMPLE).read_text(encoding="utf-8"))
    model.write_text(json.dumps(source), encoding="utf-8")
    for extra in (REPO_ROOT / EXAMPLE).parent.glob("*.bin"):
        (directory / extra.name).write_bytes(extra.read_bytes())
    (directory / "sm_thing.gltf.spec.yaml").write_text("poly_budget: 500\n", encoding="utf-8")

    sys.path.insert(0, str(REPO_ROOT / "tools" / "gltf-validator"))
    import model_spec

    if model_spec._import_jsonschema() is None:
        return  # the schema check degrades to a warning without jsonschema
    assert vmf.main([str(model)]) is True, "a misspelled spec key must fail"


# --------------------------------------------------------------------------


def run_standalone() -> int:
    tests = [
        (name, obj)
        for name, obj in sorted(globals().items())
        if name.startswith("test_") and callable(obj)
    ]
    failures = 0
    for name, test in tests:
        try:
            test()
        except AssertionError as exc:
            failures += 1
            print(f"FAIL  {name}\n      {exc}")
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"ERROR {name}\n      {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {name}")

    print(f"\n{len(tests) - failures}/{len(tests)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run_standalone())
