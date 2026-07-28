#!/usr/bin/env python3
"""Tests for validate-pipeline-doc.py.

Runs standalone (`python .github/scripts/test_validate_pipeline_doc.py`) like the
sibling test files, and also under pytest.

The point of most of these is negative: each check gets a document that breaks
exactly one thing, so a check that silently stops working is caught here rather
than by a reviewer wondering why CI went quiet.
"""

from __future__ import annotations

import copy
import importlib.util
import re
import sys
import tempfile
from pathlib import Path

import yaml

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parents[1]
DOC_PATH = REPO_ROOT / "documentation" / "pipeline" / "pipeline.yaml"


def _load_validator_module():
    path = SCRIPTS_DIR / "validate-pipeline-doc.py"
    spec = importlib.util.spec_from_file_location("validate_pipeline_doc", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validate = _load_validator_module()


def load_doc() -> dict:
    return yaml.safe_load(DOC_PATH.read_text(encoding="utf-8"))


def problems_for(doc: dict) -> list[str]:
    """Validate an in-memory document against the real repo, return problem strings."""
    return [str(problem) for problem in validate.Validator(doc, DOC_PATH).run()]


def static_3d(doc: dict) -> dict:
    return next(p for p in doc["pipelines"] if p["id"] == "static_3d")


def find_step(pipeline: dict, step_id: str) -> dict:
    for phase in pipeline["phases"]:
        for step in phase["steps"]:
            if step["id"] == step_id:
                return step
    raise AssertionError(f"no step {step_id}")


# --------------------------------------------------------------------------
# The real document


def test_real_document_is_valid():
    assert problems_for(load_doc()) == []


def test_real_document_declares_loops():
    """The whole reason this file exists: the pipeline is not a straight line."""
    pipeline = static_3d(load_doc())
    loops = [e for e in pipeline["edges"] if e["kind"] in ("rework", "repeat")]
    assert loops, "the static 3D pipeline must record how work flows backwards"
    assert all(phase["loop"]["is_iterative"] for phase in pipeline["phases"])


def test_every_authoritative_phase_can_be_left():
    """An iterative phase without exit criteria is a trap, not a loop."""
    for pipeline in load_doc()["pipelines"]:
        if pipeline["status"] != "authoritative":
            continue
        for phase in pipeline["phases"]:
            if phase["loop"]["is_iterative"]:
                assert phase["loop"].get("exit_criteria"), (
                    f"{pipeline['id']}.{phase['id']} loops but says nothing about "
                    "how to leave"
                )


# --------------------------------------------------------------------------
# Negative cases, one broken thing each


def test_dangling_edge_is_caught():
    doc = load_doc()
    static_3d(doc)["edges"].append(
        {"from": "art.export_gltf", "to": "art.does_not_exist", "kind": "forward"}
    )
    assert any("unknown step" in p for p in problems_for(doc))


def test_unreachable_step_is_caught():
    doc = load_doc()
    pipeline = static_3d(doc)
    pipeline["edges"] = [e for e in pipeline["edges"] if e["to"] != "level_design.populate_level"]
    problems = problems_for(doc)
    assert any("unreachable" in p and "populate_level" in p for p in problems)


def test_bad_entry_step_is_caught():
    doc = load_doc()
    static_3d(doc)["entry_step"] = "art.nope"
    assert any("entry_step" in p for p in problems_for(doc))


def test_flattening_the_pipeline_is_caught():
    """Delete every loop and the document must refuse to validate."""
    doc = load_doc()
    pipeline = static_3d(doc)
    pipeline["edges"] = [e for e in pipeline["edges"] if e["kind"] == "forward"]
    for phase in pipeline["phases"]:
        phase["loop"]["is_iterative"] = False
    problems = problems_for(doc)
    assert any("is_iterative" in p for p in problems)
    assert any("straight line" in p for p in problems)


def test_self_edge_must_be_repeat():
    doc = load_doc()
    static_3d(doc)["edges"].append(
        {"from": "art.model", "to": "art.model", "kind": "forward"}
    )
    assert any("self-edge" in p for p in problems_for(doc))


def test_rework_edge_requires_a_condition():
    doc = load_doc()
    static_3d(doc)["edges"].append(
        {"from": "programming.create_prefab_scene", "to": "art.model", "kind": "rework"}
    )
    assert any("condition" in p for p in problems_for(doc))


def test_image_hash_mismatch_is_caught():
    doc = load_doc()
    doc["images"][0]["sha256"] = "0" * 64
    assert any("sha256 mismatch" in p for p in problems_for(doc))


def test_missing_image_file_is_caught():
    doc = load_doc()
    doc["images"][0]["file"] = "images/not_a_real_screenshot.png"
    assert any("file not found" in p for p in problems_for(doc))


def test_unknown_screenshot_reference_is_caught():
    doc = load_doc()
    step = find_step(static_3d(doc), "art.export_gltf")
    step["screenshots"][0]["image_id"] = "nonexistent_image"
    assert any("unknown image" in p for p in problems_for(doc))


def test_orphaned_image_is_caught():
    doc = load_doc()
    step = find_step(static_3d(doc), "art.export_gltf")
    step["screenshots"] = []
    assert any("no step references it" in p for p in problems_for(doc))


def test_missing_enforcement_path_is_caught():
    doc = load_doc()
    pipeline = static_3d(doc)
    pipeline["conventions"]["rules"][0]["enforced_by"][0]["path"] = (
        ".github/workflows/no-such-workflow.yml"
    )
    assert any("does not exist" in p for p in problems_for(doc))


def test_missing_issue_template_is_caught():
    doc = load_doc()
    find_step(static_3d(doc), "art.claim_asset")["opened_by_issue_template"] = (
        ".github/ISSUE_TEMPLATE/nope.yaml"
    )
    assert any("opened_by_issue_template" in p for p in problems_for(doc))


def test_regex_disagreeing_with_its_examples_is_caught():
    doc = load_doc()
    pattern = static_3d(doc)["conventions"]["naming_patterns"][0]
    pattern["examples"]["valid"].append("SM_RainBarrel.GLTF")
    problems = problems_for(doc)
    assert any("listed as valid but does not match" in p for p in problems)


def test_invalid_example_that_matches_is_caught():
    doc = load_doc()
    pattern = static_3d(doc)["conventions"]["naming_patterns"][0]
    pattern["examples"]["invalid"].append("sm_rain_barrel.gltf")
    assert any("listed as invalid but matches" in p for p in problems_for(doc))


def test_uncompilable_regex_is_caught():
    doc = load_doc()
    static_3d(doc)["conventions"]["naming_patterns"][0]["regex"] = "^sm_[a-z"
    assert any("does not compile" in p for p in problems_for(doc))


def test_unknown_artifact_kind_is_caught():
    doc = load_doc()
    find_step(static_3d(doc), "art.export_gltf")["outputs"].append(
        {"artifact_kind": "not_a_kind"}
    )
    assert any("unknown artifact kind" in p for p in problems_for(doc))


def test_unknown_role_is_caught():
    doc = load_doc()
    find_step(static_3d(doc), "art.model")["role"] = "wizard"
    assert any("unknown role" in p for p in problems_for(doc))


def test_step_id_must_match_its_phase():
    doc = load_doc()
    pipeline = static_3d(doc)
    step = find_step(pipeline, "art.model")
    step["id"] = "integration.model"
    problems = problems_for(doc)
    assert any("must agree" in p for p in problems)


def test_code_mirror_drift_is_caught():
    """Change a constant in a script without changing the document -> failure."""
    doc = load_doc()
    mirror = next(m for m in doc["code_mirrors"] if m["id"] == "max_texture_dimension")
    mirror["value"] = 2048
    problems = problems_for(doc)
    assert any("stale" in p and "MAX_TEXTURE_DIMENSION" in p for p in problems)


def test_code_mirror_missing_symbol_is_caught():
    doc = load_doc()
    doc["code_mirrors"].append(
        {
            "id": "invented",
            "path": ".github/scripts/validate-audio-files.py",
            "symbol": "NO_SUCH_CONSTANT",
            "value": 1,
        }
    )
    assert any("no symbol" in p for p in problems_for(doc))


def test_every_declared_code_mirror_currently_matches():
    """Guards the mirrors themselves, independent of the rest of the document."""
    doc = load_doc()
    validator = validate.Validator(doc, DOC_PATH)
    validator.check_code_mirrors()
    assert [str(p) for p in validator.problems] == []


# --------------------------------------------------------------------------
# Schema

def test_schema_rejects_unknown_keys():
    doc = load_doc()
    doc["surprise"] = "unexpected"
    assert any("surprise" in p for p in problems_for(doc))


def test_yaml_round_trips_through_the_cli():
    doc = load_doc()
    with tempfile.TemporaryDirectory() as tmp:
        copied = Path(tmp) / "pipeline.yaml"
        copied.write_text(yaml.safe_dump(doc), encoding="utf-8")
        # The images are resolved relative to the document, so a copy elsewhere
        # is expected to fail on exactly that and nothing else.
        problems = [
            str(p) for p in validate.Validator(doc, copied).run()
        ]
        assert all("file not found" in p for p in problems), problems


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
