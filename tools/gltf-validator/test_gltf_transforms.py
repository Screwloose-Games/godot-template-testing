#!/usr/bin/env python3
"""Tests for gltf_transforms.py — the unapplied-transform check.

Runs standalone (`python tools/gltf-validator/test_gltf_transforms.py`) like the
validators in .github/scripts/, and also under pytest. Needs only numpy, so it
runs outside the validator's Docker image.

Most cases are hand-built glTF JSON, for the same reason as test_gltf_axes.py: a
fixture you can read in the diff beats a binary nobody can inspect. The
exception is test-fixtures/unapplied_rotation_90z.gltf, which is a real Blender
export kept verbatim — see the fixture section at the bottom.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gltf_axes  # noqa: E402
import gltf_transforms  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "test-fixtures"


def load(document: dict):
    """Turn a glTF JSON document into something with pygltflib's attribute shape."""
    raw = json.loads(json.dumps(document))  # round-trip: catches non-serialisable fixtures
    return SimpleNamespace(
        scene=raw.get("scene", 0),
        scenes=[SimpleNamespace(nodes=scene.get("nodes")) for scene in raw.get("scenes", [])],
        nodes=[
            SimpleNamespace(
                name=node.get("name"),
                mesh=node.get("mesh"),
                children=node.get("children"),
                rotation=node.get("rotation"),
                translation=node.get("translation"),
                scale=node.get("scale"),
                matrix=node.get("matrix"),
            )
            for node in raw.get("nodes", [])
        ],
        skins=[
            SimpleNamespace(joints=skin.get("joints"), skeleton=skin.get("skeleton"))
            for skin in raw.get("skins", [])
        ],
        animations=[
            SimpleNamespace(
                channels=[
                    SimpleNamespace(target=SimpleNamespace(node=channel.get("target", {}).get("node")))
                    for channel in animation.get("channels", [])
                ]
            )
            for animation in raw.get("animations", [])
        ],
    )


def load_file(path: Path):
    return load(json.loads(path.read_text(encoding="utf-8")))


def axis_quaternion(axis: str, degrees: float) -> list[float]:
    """Quaternion (x, y, z, w) for a rotation about a cardinal axis."""
    half = math.radians(degrees) / 2
    sin, cos = math.sin(half), math.cos(half)
    return {"x": [sin, 0, 0, cos], "y": [0, sin, 0, cos], "z": [0, 0, sin, cos]}[axis]


def asset(nodes: list[dict], roots: list[int] | None = None, **extra) -> dict:
    return {
        "scene": 0,
        "scenes": [{"nodes": roots if roots is not None else [0]}],
        "nodes": nodes,
        **extra,
    }


def kinds(report) -> list[str]:
    return [finding.kind for finding in report.findings]


# --------------------------------------------------------------------------
# Clean exports — nothing to report


def test_clean_export_has_nothing_to_report():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"name": "sm_rain_barrel", "mesh": 0}])))
    assert report.findings == []
    assert report.ok


def test_identity_trs_written_out_explicitly_is_clean():
    """Some exporters write the defaults rather than omitting them."""
    node = {"mesh": 0, "rotation": [0, 0, 0, 1], "translation": [0, 0, 0], "scale": [1, 1, 1]}
    assert gltf_transforms.find_unapplied_transforms(load(asset([node]))).findings == []


def test_identity_matrix_is_clean():
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    assert gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "matrix": identity}]))).findings == []


def test_exporter_float_noise_is_not_a_finding():
    """A quaternion round-trip must not be mistaken for an unapplied rotation."""
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 0.001)}])))
    assert report.findings == []


def test_transform_on_a_node_with_no_mesh_under_it_is_ignored():
    """A stray empty off to the side cannot affect the mesh, so it is not our problem."""
    document = asset(
        [{"name": "Scene", "children": [1, 2]}, {"name": "sm_crate", "mesh": 0}, {"name": "Light", "rotation": axis_quaternion("x", 45)}]
    )
    assert gltf_transforms.find_unapplied_transforms(load(document)).findings == []


# --------------------------------------------------------------------------
# Failing cases — the authoring mistakes this check exists to catch


def test_unapplied_rotation_fails():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"name": "Cube", "mesh": 0, "rotation": axis_quaternion("y", 90)}])))
    assert kinds(report) == ["rotation"]
    assert not report.ok
    assert report.failures[0].severity == "fail"


def test_rotation_finding_names_both_the_gltf_and_the_blender_axis():
    """The artist fixes this in Blender, so the message has to speak Blender."""
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 90)}])))
    detail = report.failures[0].detail
    assert "90.0 deg about glTF +Y" in detail
    assert "+Z in Blender" in detail  # glTF +Y is Blender's up


def test_rotation_finding_explains_the_fix():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 90)}])))
    assert "Apply > Rotation" in report.failures[0].remedy


def test_ninety_degrees_about_x_is_blamed_on_the_yup_conversion_first():
    """The one rotation that is more likely an export setting than an artist slip.

    Nothing in the node graph separates the two causes, so the message names the
    likelier one rather than sending the artist to Ctrl+A for a problem that
    lives in the export dialog.
    """
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("x", 90)}])))
    finding = report.failures[0]
    assert "Y-up conversion" in finding.detail
    assert "'+Y Up'" in finding.remedy


def test_other_rotations_are_not_blamed_on_the_yup_conversion():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 90)}])))
    assert "Y-up conversion" not in report.failures[0].detail


def test_forty_five_about_x_is_not_the_yup_signature():
    """The signature is 90 degrees specifically, not any rotation about X."""
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("x", 45)}])))
    assert "Y-up conversion" not in report.failures[0].detail


def test_unapplied_uniform_scale_fails():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "scale": [2, 2, 2]}])))
    assert kinds(report) == ["scale"]
    assert "not at the size its geometry claims" in report.failures[0].detail


def test_non_uniform_scale_is_called_out_as_such():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "scale": [1, 2, 1]}])))
    assert "non-uniform" in report.failures[0].detail


def test_negative_scale_is_called_out_as_mirroring():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "scale": [-1, 1, 1]}])))
    assert "mirrors the mesh" in report.failures[0].detail


def test_rotation_and_scale_are_reported_separately():
    node = {"mesh": 0, "rotation": axis_quaternion("z", 45), "scale": [2, 2, 2]}
    assert sorted(kinds(gltf_transforms.find_unapplied_transforms(load(asset([node]))))) == ["rotation", "scale"]


def test_rotation_on_a_parent_is_caught():
    """The mesh node is clean but it inherits a rotation, which is just as broken."""
    document = asset([{"name": "Scene", "rotation": axis_quaternion("x", 90), "children": [1]}, {"name": "sm_crate", "mesh": 0}])
    report = gltf_transforms.find_unapplied_transforms(load(document))
    assert kinds(report) == ["rotation"]
    assert report.failures[0].node_index == 0


def test_rotation_baked_into_a_matrix_is_caught():
    """Node written as a matrix rather than TRS — same mistake, different encoding."""
    matrix = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1]  # 90 deg about +Y
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "matrix": matrix}])))
    assert kinds(report) == ["rotation"]
    assert "90.0 deg" in report.failures[0].detail


def test_scale_baked_into_a_matrix_is_caught():
    matrix = [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1]
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "matrix": matrix}])))
    assert kinds(report) == ["scale"]


def test_180_degree_rotation_is_caught():
    """The angle/axis extraction degenerates at 180 degrees; it must still fire."""
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 180)}])))
    assert kinds(report) == ["rotation"]
    assert "180.0 deg" in report.failures[0].detail


def test_off_axis_rotation_reports_components_rather_than_a_wrong_axis_name():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": [0.5, 0.5, 0.5, 0.5]}])))
    assert kinds(report) == ["rotation"]
    assert "(" in report.failures[0].detail  # raw components, not a cardinal name


# --------------------------------------------------------------------------
# Translation — reported, but never blocking


def test_translation_warns_and_does_not_fail():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "translation": [0, 1.5, 0]}])))
    assert kinds(report) == ["translation"]
    assert report.warnings and not report.failures
    assert report.ok  # a warning must not block a build


def test_translation_alongside_a_rotation_still_only_fails_for_the_rotation():
    node = {"mesh": 0, "rotation": axis_quaternion("y", 90), "translation": [0, 1.5, 0]}
    report = gltf_transforms.find_unapplied_transforms(load(asset([node])))
    assert sorted(kinds(report)) == ["rotation", "translation"]
    assert [f.kind for f in report.failures] == ["rotation"]


# --------------------------------------------------------------------------
# Exemptions — transforms that are doing their job


def test_skin_joints_are_exempt():
    """A bone with a rotation is a bone, not a mistake."""
    document = asset(
        [{"name": "Armature", "children": [1]}, {"name": "Bone", "rotation": axis_quaternion("x", 30), "children": [2]}, {"name": "sk_wolf", "mesh": 0}],
        skins=[{"joints": [1], "skeleton": 0}],
    )
    assert gltf_transforms.find_unapplied_transforms(load(document)).findings == []


def test_animated_nodes_are_exempt():
    """A node a clip drives is meant to carry a transform."""
    document = asset(
        [{"name": "Turntable", "rotation": axis_quaternion("y", 30), "children": [1]}, {"name": "sm_prop", "mesh": 0}],
        animations=[{"channels": [{"target": {"node": 0}}]}],
    )
    assert gltf_transforms.find_unapplied_transforms(load(document)).findings == []


def test_the_root_of_a_rigged_asset_is_still_checked():
    """Exempting a rig must not exempt its root -- no rig needs the asset rotated."""
    document = asset(
        [{"name": "Armature", "scale": [2, 2, 2], "children": [1]}, {"name": "sk_wolf", "mesh": 0}],
        skins=[{"joints": [1]}],
    )
    report = gltf_transforms.find_unapplied_transforms(load(document))
    assert kinds(report) == ["scale"]
    assert report.failures[0].node_index == 0


def test_transforms_below_the_root_of_a_rigged_asset_are_left_alone():
    """The wolf case: mesh parts posed by node transforms are the rig, not a mistake.

    examples/.../grey-wolf-gaits-and-jump.glb has no skin -- 59 mesh nodes posed
    by rotations five and six levels deep. Checking those produced a finding per
    body part while its root was clean.
    """
    document = asset(
        [
            {"name": "wolf_rig", "children": [1]},
            {"name": "spine", "children": [2]},
            {"name": "neck", "mesh": 0, "rotation": axis_quaternion("x", 20), "translation": [0, 0.095, 0.08]},
        ],
        animations=[{"channels": [{"target": {"node": 1}}]}],
    )
    assert gltf_transforms.find_unapplied_transforms(load(document)).findings == []


def test_a_static_asset_is_checked_all_the_way_down():
    """Without a rig there is nothing to excuse a transform partway down."""
    document = asset(
        [{"name": "Scene", "children": [1]}, {"name": "sm_crate", "mesh": 0, "scale": [2, 2, 2]}],
    )
    report = gltf_transforms.find_unapplied_transforms(load(document))
    assert kinds(report) == ["scale"]
    assert report.failures[0].node_index == 1


# --------------------------------------------------------------------------
# Malformed input — must not crash


def test_empty_asset_reports_nothing():
    assert gltf_transforms.find_unapplied_transforms(load({"scene": 0, "scenes": [{"nodes": []}], "nodes": []})).findings == []


def test_cycle_in_the_node_graph_does_not_hang():
    assert gltf_transforms.find_unapplied_transforms(load(asset([{"children": [1]}, {"children": [0]}]))).findings == []


def test_degenerate_matrix_does_not_crash():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "matrix": [0] * 16}])))
    assert isinstance(report.findings, list)


def test_format_report_is_readable_when_clean():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0}])))
    assert "No unapplied transforms" in gltf_transforms.format_report(report)


def test_format_report_includes_the_fix():
    report = gltf_transforms.find_unapplied_transforms(load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 90)}])))
    text = gltf_transforms.format_report(report)
    assert "FAIL" in text and "Fix:" in text


# --------------------------------------------------------------------------
# The real-export fixture
#
# test-fixtures/unapplied_rotation_90z.gltf is the committed export of
# assets/3d/example_cubes_facing before the rotation was applied in Blender. It
# is kept verbatim because it is the case that motivated this check: a real
# Blender 4.3 export whose object still carried a 90 degree Z rotation.
#
# Its geometry points down -Z, but gltf_axes reads the leftover node rotation
# and reports +X. That mismatch is the whole argument for failing the build on
# an unapplied transform rather than trusting the facing number.


def test_fixture_is_present_and_is_a_real_export():
    document = json.loads((FIXTURES / "unapplied_rotation_90z.gltf").read_text(encoding="utf-8"))
    assert "Blender" in document["asset"]["generator"]


def test_fixture_fails_the_unapplied_transform_check():
    report = gltf_transforms.find_unapplied_transforms(load_file(FIXTURES / "unapplied_rotation_90z.gltf"))
    assert not report.ok, "the fixture exists precisely to fail this check"
    assert [f.kind for f in report.failures] == ["rotation"]


def test_fixture_reports_the_90_degree_z_rotation_the_artist_left_in_blender():
    report = gltf_transforms.find_unapplied_transforms(load_file(FIXTURES / "unapplied_rotation_90z.gltf"))
    detail = report.failures[0].detail
    assert "90.0 deg about glTF +Y" in detail
    assert "90.0 deg about +Z in Blender" in detail


def test_fixture_also_notes_the_node_offset_without_failing_on_it():
    report = gltf_transforms.find_unapplied_transforms(load_file(FIXTURES / "unapplied_rotation_90z.gltf"))
    assert [f.kind for f in report.warnings] == ["translation"]


def test_fixture_shows_why_the_facing_number_cannot_be_trusted():
    """The point of the whole check, pinned as a test.

    gltf_axes reports +X for this asset. The geometry points -Z. Neither the
    spec's +Z nor anything else measured here means anything until the rotation
    is applied.
    """
    gltf = load_file(FIXTURES / "unapplied_rotation_90z.gltf")
    assert gltf_axes.get_model_facing_direction(gltf) == "+X"
    assert not gltf_transforms.find_unapplied_transforms(gltf).ok


# --------------------------------------------------------------------------


def run_standalone() -> int:
    tests = [(name, obj) for name, obj in sorted(globals().items()) if name.startswith("test_") and callable(obj)]
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
