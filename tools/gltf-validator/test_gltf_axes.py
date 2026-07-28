#!/usr/bin/env python3
"""Tests for gltf_axes.py — the facing/up direction checks.

Runs standalone (`python tools/gltf-validator/test_gltf_axes.py`) like the
validators in .github/scripts/, and also under pytest. Needs only numpy, so it
runs outside the validator's Docker image.

Assets are built as glTF JSON here rather than as binary fixtures. Orientation
lives entirely in the node graph, so JSON is the whole story — and a fixture you
can read in the diff beats a .glb nobody can inspect.

Every case is named for what it represents in the real pipeline: a correct
export, or a specific way an export goes wrong.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gltf_axes  # noqa: E402


def load(document: dict):
    """Turn a glTF JSON document into something with pygltflib's attribute shape."""
    raw = json.loads(json.dumps(document))  # round-trip: catches non-serialisable fixtures
    return SimpleNamespace(
        scene=raw.get("scene", 0),
        scenes=[SimpleNamespace(**scene) for scene in raw.get("scenes", [])],
        nodes=[
            SimpleNamespace(
                name=node.get("name"),
                mesh=node.get("mesh"),
                children=node.get("children"),
                rotation=node.get("rotation"),
                matrix=node.get("matrix"),
            )
            for node in raw.get("nodes", [])
        ],
    )


def axis_quaternion(axis: str, degrees: float) -> list[float]:
    """Quaternion (x, y, z, w) for a rotation about a cardinal axis."""
    half = math.radians(degrees) / 2
    sin, cos = math.sin(half), math.cos(half)
    components = {"x": [sin, 0, 0, cos], "y": [0, sin, 0, cos], "z": [0, 0, sin, cos]}
    return components[axis]


def asset(nodes: list[dict], roots: list[int] | None = None) -> dict:
    return {
        "scene": 0,
        "scenes": [{"nodes": roots if roots is not None else [0]}],
        "nodes": nodes,
    }


# --------------------------------------------------------------------------
# Passing cases — what a correct export looks like


def test_correct_export_faces_plus_z():
    """The glTF spec puts an asset's front on +Z. A clean export has no root rotation."""
    gltf = load(asset([{"name": "sm_rain_barrel", "mesh": 0}]))
    assert gltf_axes.get_model_facing_direction(gltf) == "+Z"
    assert gltf_axes.get_model_up_direction(gltf) == "+Y"


def test_identity_matrix_is_the_same_as_no_transform():
    identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    gltf = load(asset([{"name": "sm_rain_barrel", "mesh": 0, "matrix": identity}]))
    assert gltf_axes.get_model_facing_direction(gltf) == "+Z"
    assert gltf_axes.get_model_up_direction(gltf) == "+Y"


def test_uniform_scale_does_not_change_the_axes():
    """A model exported at a different scale is still oriented correctly."""
    scaled = [2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1]
    gltf = load(asset([{"name": "sm_rain_barrel", "mesh": 0, "matrix": scaled}]))
    assert gltf_axes.get_model_facing_direction(gltf) == "+Z"


def test_yaw_only_still_reads_up_as_plus_y():
    """Spinning a prop about the vertical axis changes facing but never up."""
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 90)}]))
    assert gltf_axes.get_model_up_direction(gltf) == "+Y"
    assert gltf_axes.get_model_facing_direction(gltf) == "+X"


def test_mesh_nested_under_transformless_parents():
    """Exporters commonly wrap the mesh in an empty. That must not change the answer."""
    gltf = load(
        asset(
            [
                {"name": "Scene", "children": [1]},
                {"name": "Armature", "children": [2]},
                {"name": "sk_wolf", "mesh": 0},
            ]
        )
    )
    assert gltf_axes.get_model_facing_direction(gltf) == "+Z"


def test_rotation_on_a_parent_is_composed_into_the_result():
    """A rotation two levels up still counts — that is the point of walking the chain."""
    gltf = load(
        asset(
            [
                {"name": "Scene", "rotation": axis_quaternion("x", 90), "children": [1]},
                {"name": "sm_rain_barrel", "mesh": 0},
            ]
        )
    )
    assert gltf_axes.get_model_facing_direction(gltf) == "-Y"


# --------------------------------------------------------------------------
# Failing cases — the export mistakes this check exists to catch


def test_z_up_export_is_caught():
    """The big one: exported Z-up, so the axis conversion never happened.

    Blender's up (+Z) stays on +Z instead of becoming +Y, which shows up as a
    +90 degree rotation about X. Up reads as +Z and the front as -Y.
    """
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("x", 90)}]))
    assert gltf_axes.get_model_up_direction(gltf) == "+Z"
    assert gltf_axes.get_model_facing_direction(gltf) == "-Y"


def test_conversion_applied_the_wrong_way_is_caught():
    """The same conversion applied in the wrong direction: up lands on -Z."""
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("x", -90)}]))
    assert gltf_axes.get_model_up_direction(gltf) == "-Z"
    assert gltf_axes.get_model_facing_direction(gltf) == "+Y"


def test_model_facing_backwards_is_caught():
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 180)}]))
    assert gltf_axes.get_model_facing_direction(gltf) == "-Z"


def test_upside_down_model_is_caught():
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("z", 180)}]))
    assert gltf_axes.get_model_up_direction(gltf) == "-Y"


# --------------------------------------------------------------------------
# Undeterminable cases — must return None, never a confident wrong answer


def test_off_axis_rotation_is_not_snapped_to_a_lie():
    """45 degrees is not "nearly +Z". Refusing to answer beats guessing."""
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 45)}]))
    assert gltf_axes.get_model_facing_direction(gltf) is None


def test_small_wobble_is_tolerated():
    """Float noise from an exporter must not fail an otherwise correct model."""
    gltf = load(asset([{"mesh": 0, "rotation": axis_quaternion("y", 2)}]))
    assert gltf_axes.get_model_facing_direction(gltf) == "+Z"


def test_disagreeing_roots_are_undeterminable():
    """Two objects oriented differently: there is no single answer for the asset."""
    gltf = load(
        asset(
            [
                {"mesh": 0},
                {"mesh": 1, "rotation": axis_quaternion("x", -90)},
            ],
            roots=[0, 1],
        )
    )
    assert gltf_axes.get_model_facing_direction(gltf) is None


def test_agreeing_roots_are_fine():
    gltf = load(asset([{"mesh": 0}, {"mesh": 1}], roots=[0, 1]))
    assert gltf_axes.get_model_facing_direction(gltf) == "+Z"


def test_asset_with_no_mesh_is_undeterminable():
    gltf = load(asset([{"name": "Empty"}]))
    assert gltf_axes.get_model_facing_direction(gltf) is None


def test_empty_asset_is_undeterminable():
    gltf = load({"scene": 0, "scenes": [{"nodes": []}], "nodes": []})
    assert gltf_axes.get_model_facing_direction(gltf) is None
    assert gltf_axes.get_model_up_direction(gltf) is None


def test_cycle_in_the_node_graph_does_not_hang():
    """Malformed input must fail, not spin forever."""
    gltf = load(asset([{"children": [1]}, {"children": [0]}]))
    assert gltf_axes.get_model_facing_direction(gltf) is None


def test_degenerate_matrix_does_not_produce_nan():
    zero = [0] * 16
    gltf = load(asset([{"mesh": 0, "matrix": zero}]))
    assert gltf_axes.get_model_facing_direction(gltf) in (None, "+Z")


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
