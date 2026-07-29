#!/usr/bin/env python3
"""Tests for model_spec.py — reading, schema-checking and reducing a spec.

Runs standalone (`python tools/gltf-validator/test_model_spec.py`) like the
validators in .github/scripts/, and also under pytest. Needs numpy and pyyaml;
the jsonschema tests skip themselves when it is absent.

test_validate_gltf_spec.py already covers the verdicts evaluate_model_against_spec
produces. This file covers what was built around it:

* the schema check, which is new -- schemas/model-spec.schema.json has always
  existed and nothing has ever validated against it, so a key with a typo in it
  was ignored in silence and the check the artist asked for never ran;
* verdicts_failed, the reducer CI was missing when it gated on "did the renderer
  finish" instead of "did the model pass";
* check_external_resources, promoted from a bail-out in the middle of the render
  path to a named check, because a .gltf committed without its .bin is the
  failure that actually reaches main.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import model_spec  # noqa: E402

HAVE_JSONSCHEMA = model_spec._import_jsonschema() is not None


def write_spec(text: str) -> Path:
    path = Path(tempfile.mkdtemp()) / "sm_thing.gltf.spec.yaml"
    path.write_text(text, encoding="utf-8")
    return path


def gltf(images=(), buffers=()) -> SimpleNamespace:
    return SimpleNamespace(
        images=[SimpleNamespace(uri=uri) for uri in images],
        buffers=[SimpleNamespace(uri=uri) for uri in buffers],
    )


# --------------------------------------------------------------------------
# Spec paths
# --------------------------------------------------------------------------


def test_the_spec_is_named_for_the_whole_model_filename():
    """sm_rain_barrel.gltf pairs with sm_rain_barrel.gltf.spec.yaml.

    Not sm_rain_barrel.spec.yaml -- the validator looks for exactly the first
    name and silently skips anything else, which is why the near-miss matters.
    """
    assert model_spec.spec_path_for("a/sm_rain_barrel.gltf") == "a/sm_rain_barrel.gltf.spec.yaml"


def test_a_spec_path_maps_back_to_its_model():
    assert model_spec.model_path_for("a/sm_rain_barrel.gltf.spec.yaml") == "a/sm_rain_barrel.gltf"


def test_a_path_that_is_not_a_spec_is_returned_unchanged():
    assert model_spec.model_path_for("a/sm_rain_barrel.gltf") == "a/sm_rain_barrel.gltf"


# --------------------------------------------------------------------------
# Finding the schema on either side of the Docker boundary
# --------------------------------------------------------------------------


def test_the_schema_is_looked_for_above_a_checkout():
    """From tools/gltf-validator/, the repo root is two directories up.

    Compared against the resolved module path rather than a literal "/repo":
    on Windows a rooted path resolves onto the current drive (C:\\repo\\...), so
    asserting against the bare string passes on Linux and fails everywhere else.
    """
    module = Path("/repo/tools/gltf-validator/model_spec.py")
    candidates = model_spec._schema_candidates(module, Path("/somewhere/else"))
    assert len(candidates) == 2, "checkout candidate then working directory"
    assert candidates[0] == module.resolve().parents[2] / model_spec.SCHEMA_RELATIVE_PATH
    assert candidates[0].parent.name == "schemas"


def test_a_flattened_image_layout_falls_back_to_the_working_directory():
    """The regression that took the renderer down.

    The validator image copies this module to /app, which has no third parent.
    Indexing .parents past the root raises IndexError rather than yielding a path
    that merely fails .exists(), so building the candidate list blew up at import
    time -- before the working-directory fallback, where the repo is mounted and
    the schema really is, could be tried.
    """
    candidates = model_spec._schema_candidates(
        Path("/app/model_spec.py"), Path("/workspace")
    )
    assert candidates == [Path("/workspace") / model_spec.SCHEMA_RELATIVE_PATH]


def test_the_working_directory_is_always_a_candidate():
    for module_path in (Path("/app/model_spec.py"), Path("/r/tools/v/model_spec.py")):
        candidates = model_spec._schema_candidates(module_path, Path("/workspace"))
        assert Path("/workspace") / model_spec.SCHEMA_RELATIVE_PATH in candidates


# --------------------------------------------------------------------------
# Reading
# --------------------------------------------------------------------------


def test_a_missing_spec_reads_as_an_empty_dict():
    """A model with no spec passes everything. That is the documented default."""
    assert model_spec.read_spec_file("does/not/exist.gltf.spec.yaml") == {}


def test_an_empty_spec_file_reads_as_an_empty_dict():
    """yaml.safe_load returns None for an empty document, not {}."""
    assert model_spec.read_spec_file(write_spec("")) == {}


def test_a_spec_reads_its_keys():
    spec = model_spec.read_spec_file(write_spec("width: 1.5\npoly_count_budget: 500\n"))
    assert spec == {"width": 1.5, "poly_count_budget": 500}


# --------------------------------------------------------------------------
# Schema validation — the gap this closes
# --------------------------------------------------------------------------


def test_a_valid_spec_has_no_problems():
    if not HAVE_JSONSCHEMA:
        return
    spec = {
        "width": 1.0,
        "height": 1.8,
        "up_direction": "+Y",
        "facing_direction": "-Z",
        "poly_count_budget": 500,
        "textures_expected": [{"name": "base_color"}],
        "animations_expected": [{"name": "idle"}],
    }
    assert model_spec.validate_spec_schema(spec, "sm_thing.gltf.spec.yaml") == []


def test_a_misspelled_key_is_an_error_not_a_shrug():
    """poly_budget for poly_count_budget: the exact failure this check exists for.

    Before the schema check, the key was ignored and the poly budget was simply
    never enforced -- an artist who wrote it would see a green tick.
    """
    if not HAVE_JSONSCHEMA:
        return
    problems = model_spec.validate_spec_schema({"poly_budget": 500}, "sm_thing.gltf.spec.yaml")
    assert problems, "an unrecognised key must be reported"
    assert "poly_budget" in problems[0], problems
    assert "never runs" in problems[0], "the message should say why it matters"


def test_a_wrongly_typed_value_is_an_error():
    if not HAVE_JSONSCHEMA:
        return
    assert model_spec.validate_spec_schema({"poly_count_budget": "lots"}, "s.yaml")


def test_an_axis_outside_the_enum_is_an_error():
    if not HAVE_JSONSCHEMA:
        return
    assert model_spec.validate_spec_schema({"up_direction": "up"}, "s.yaml")


def test_a_negative_dimension_is_an_error():
    if not HAVE_JSONSCHEMA:
        return
    assert model_spec.validate_spec_schema({"width": -1}, "s.yaml")


def test_an_empty_spec_is_not_a_problem():
    assert model_spec.validate_spec_schema({}, "s.yaml") == []


def test_a_spec_that_is_not_a_mapping_is_an_error():
    problems = model_spec.validate_spec_schema(["width", 1], "s.yaml")
    assert problems and "mapping" in problems[0], problems


def test_a_missing_jsonschema_degrades_to_a_problem_not_a_crash():
    """Running without jsonschema must say what went unchecked, not explode."""
    original = model_spec._import_jsonschema
    model_spec._import_jsonschema = lambda: None
    try:
        problems = model_spec.validate_spec_schema({"width": 1.0}, "sm_thing.gltf.spec.yaml")
    finally:
        model_spec._import_jsonschema = original
    assert len(problems) == 1, problems
    assert "NOT" in problems[0], "it must be obvious the spec went unchecked"
    assert "pip install jsonschema" in problems[0], "and say how to fix it"


def test_the_schema_is_found_from_the_repo():
    assert model_spec._find_schema().exists(), (
        "schemas/model-spec.schema.json should resolve from a checkout; if this "
        "fails the schema check silently degrades to 'schema not found'"
    )


# --------------------------------------------------------------------------
# Reducing verdicts to a pass/fail
# --------------------------------------------------------------------------


def test_ok_verdicts_pass():
    assert model_spec.verdicts_failed({"width": "OK", "height": "OK"}) == []


def test_fail_verdicts_fail():
    assert model_spec.verdicts_failed({"width": "OK", "height": "FAIL"}) == ["height"]


def test_a_fail_with_an_explanation_still_fails():
    results = {"unapplied_transforms": "FAIL - leftover rotation on node 0. Apply it..."}
    assert model_spec.verdicts_failed(results) == ["unapplied_transforms"]


def test_info_verdicts_pass():
    """INFO is a declaration nobody can act on; a red cross there is noise."""
    results = {"facing_direction": "INFO - spec declares -Z. Not machine-checkable..."}
    assert model_spec.verdicts_failed(results) == []


def test_unknown_verdicts_fail():
    """An unmeasurable dimension is not a passing dimension."""
    results = {"up_direction": "UNKNOWN (could not determine from the node graph)"}
    assert model_spec.verdicts_failed(results) == ["up_direction"]


def test_an_empty_result_set_passes():
    """A model with no spec has no verdicts, and that is a pass by design."""
    assert model_spec.verdicts_failed({}) == []


# --------------------------------------------------------------------------
# External resources
# --------------------------------------------------------------------------


def test_a_missing_buffer_is_reported():
    missing = model_spec.check_external_resources(
        gltf(buffers=["sm_thing.bin"]), "/nowhere/sm_thing.gltf"
    )
    assert missing == ["buffer: sm_thing.bin"], missing


def test_a_present_buffer_is_not_reported():
    directory = Path(tempfile.mkdtemp())
    (directory / "sm_thing.bin").write_bytes(b"\0")
    missing = model_spec.check_external_resources(
        gltf(buffers=["sm_thing.bin"]), directory / "sm_thing.gltf"
    )
    assert missing == [], missing


def test_a_missing_texture_is_reported():
    missing = model_spec.check_external_resources(
        gltf(images=["t_wood.png"]), "/nowhere/sm_thing.gltf"
    )
    assert missing == ["texture: t_wood.png"], missing


def test_a_percent_encoded_texture_is_resolved_before_looking():
    """"rain barrel.png" is stored as "rain%20barrel.png" and must still be found."""
    directory = Path(tempfile.mkdtemp())
    (directory / "rain barrel.png").write_bytes(b"\0")
    missing = model_spec.check_external_resources(
        gltf(images=["rain%20barrel.png"]), directory / "sm_thing.gltf"
    )
    assert missing == [], missing


def test_an_embedded_data_uri_is_not_a_missing_file():
    missing = model_spec.check_external_resources(
        gltf(images=["data:image/png;base64,iVBORw0KGgo="]), "/nowhere/sm_thing.gltf"
    )
    assert missing == [], missing


def test_a_glb_buffer_with_no_uri_is_not_missing():
    """A .glb keeps geometry in an internal chunk; no uri is correct there."""
    assert model_spec.check_external_resources(gltf(buffers=[None]), "/nowhere/m.glb") == []


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
    if not HAVE_JSONSCHEMA:
        print("note: jsonschema is not installed, so the schema cases were skipped")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run_standalone())
