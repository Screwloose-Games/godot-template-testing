#!/usr/bin/env python3
"""Tests for gltf_measure.py — headless bounds and triangle counting.

Runs standalone (`python tools/gltf-validator/test_gltf_measure.py`) like the
validators in .github/scripts/, and also under pytest. Needs only numpy, so it
runs outside the validator's Docker image.

The load-bearing case is
`test_a_ninety_degree_node_rotation_is_applied_to_the_bounds`. The fixture
test-fixtures/unapplied_rotation_90z.gltf is the example cube with its geometry
pre-rotated in local space and a compensating 90 degree node rotation, so its
*local* AABB has X and Z swapped while its *world* AABB is identical to the
original's. Any bug that reads accessor min/max without composing the node
matrix produces the swapped numbers, and only that comparison catches it.

Synthetic documents are built as glTF JSON rather than as binary fixtures:
bounds and triangle counts live entirely in the JSON, and a fixture you can read
in the diff beats a .glb nobody can inspect.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gltf_document  # noqa: E402
import gltf_measure  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_GLTF = REPO_ROOT / "assets/art/3d/example_cubes_facing/sm_example_cubes_facing.gltf"
ROTATED_FIXTURE = Path(__file__).resolve().parent / "test-fixtures/unapplied_rotation_90z.gltf"
WOLF_GLB = (
    REPO_ROOT
    / "examples/3d/exploration_quadraped/assets/models/wolf/grey-wolf-gaits-and-jump.glb"
)


def document(primitives=None, nodes=None, accessors=None) -> dict:
    """A one-mesh, one-node scene unless the caller says otherwise."""
    return {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": nodes if nodes is not None else [{"mesh": 0}],
        "meshes": [{"primitives": primitives or [{"attributes": {"POSITION": 0}}]}],
        "accessors": accessors
        if accessors is not None
        else [{"count": 3, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]}],
    }


def unit_cube_accessor(minimum=(-1, -1, -1), maximum=(1, 1, 1), count=36):
    return {"count": count, "type": "VEC3", "min": list(minimum), "max": list(maximum)}


# --------------------------------------------------------------------------
# Triangle counting
# --------------------------------------------------------------------------


def test_an_absent_mode_means_triangles():
    """glTF's default primitive.mode is 4 (TRIANGLES); absence is not zero."""
    doc = document(accessors=[unit_cube_accessor(count=36)])
    assert gltf_measure.measure(doc).triangles == 12


def test_indices_win_over_position_count():
    doc = document(
        primitives=[{"attributes": {"POSITION": 0}, "indices": 1}],
        accessors=[unit_cube_accessor(count=24), {"count": 36, "type": "SCALAR"}],
    )
    assert gltf_measure.measure(doc).triangles == 12


def test_a_triangle_strip_closes_one_triangle_per_extra_vertex():
    doc = document(
        primitives=[{"attributes": {"POSITION": 0}, "mode": gltf_measure.MODE_TRIANGLE_STRIP}],
        accessors=[unit_cube_accessor(count=10)],
    )
    assert gltf_measure.measure(doc).triangles == 8


def test_a_triangle_fan_counts_like_a_strip():
    doc = document(
        primitives=[{"attributes": {"POSITION": 0}, "mode": gltf_measure.MODE_TRIANGLE_FAN}],
        accessors=[unit_cube_accessor(count=10)],
    )
    assert gltf_measure.measure(doc).triangles == 8


def test_lines_and_points_contribute_no_triangles():
    for mode in (0, 1, 2, 3):
        doc = document(
            primitives=[{"attributes": {"POSITION": 0}, "mode": mode}],
            accessors=[unit_cube_accessor(count=36)],
        )
        assert gltf_measure.measure(doc).triangles == 0, f"mode {mode}"


def test_a_mesh_used_by_three_nodes_counts_three_times():
    """The change from trimesh: instances, not unique meshes.

    Twenty 500-triangle crates ship ten thousand triangles, and that is the
    number a poly budget is about.
    """
    doc = document(
        nodes=[
            {"children": [1, 2, 3]},
            {"mesh": 0, "translation": [0, 0, 0]},
            {"mesh": 0, "translation": [5, 0, 0]},
            {"mesh": 0, "translation": [10, 0, 0]},
        ],
        accessors=[unit_cube_accessor(count=36)],
    )
    measurement = gltf_measure.measure(doc)
    assert measurement.triangles == 36, measurement.triangles
    assert measurement.unique_triangles == 12, measurement.unique_triangles
    assert measurement.instances == 3
    assert measurement.unique_meshes == 1


def test_a_mesh_outside_the_scene_is_not_counted():
    """trimesh only ever built geometry for the scene graph it was handed."""
    doc = document(nodes=[{"mesh": 0}], accessors=[unit_cube_accessor(count=36)])
    doc["meshes"].append({"primitives": [{"attributes": {"POSITION": 0}}]})
    doc["nodes"].append({"mesh": 1})  # present in nodes, absent from scenes[0].nodes
    assert gltf_measure.measure(doc).triangles == 12


# --------------------------------------------------------------------------
# Bounds
# --------------------------------------------------------------------------


def test_bounds_of_an_untransformed_cube():
    doc = document(accessors=[unit_cube_accessor()])
    measurement = gltf_measure.measure(doc)
    assert np.allclose(measurement.size, [2, 2, 2]), measurement.size


def test_a_node_translation_moves_the_bounds_but_not_the_size():
    doc = document(
        nodes=[{"mesh": 0, "translation": [10, 0, 0]}], accessors=[unit_cube_accessor()]
    )
    measurement = gltf_measure.measure(doc)
    assert np.allclose(measurement.size, [2, 2, 2]), measurement.size
    assert np.allclose(measurement.minimum, [9, -1, -1]), measurement.minimum


def test_a_node_scale_scales_the_bounds():
    doc = document(nodes=[{"mesh": 0, "scale": [2, 3, 4]}], accessors=[unit_cube_accessor()])
    assert np.allclose(gltf_measure.measure(doc).size, [4, 6, 8])


def test_a_parent_transform_composes_with_its_child():
    doc = document(
        nodes=[
            {"children": [1], "scale": [2, 2, 2]},
            {"mesh": 0, "translation": [1, 0, 0]},
        ],
        accessors=[unit_cube_accessor()],
    )
    measurement = gltf_measure.measure(doc)
    # child translated +1 then parent-scaled x2 -> centre at x=2, half-extent 2
    assert np.allclose(measurement.minimum, [0, -2, -2]), measurement.minimum
    assert np.allclose(measurement.size, [4, 4, 4]), measurement.size


def test_a_node_matrix_is_read_column_major():
    """glTF stores node matrices column-major; numpy is row-major."""
    matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 7, 0, 0, 1]  # translate +7 in x
    doc = document(nodes=[{"mesh": 0, "matrix": matrix}], accessors=[unit_cube_accessor()])
    measurement = gltf_measure.measure(doc)
    assert np.allclose(measurement.minimum, [6, -1, -1]), (
        "a column-major translation was read as row-major: "
        f"got {measurement.minimum}, expected [6, -1, -1]"
    )


def test_a_cyclic_child_graph_does_not_hang():
    doc = document(nodes=[{"mesh": 0, "children": [1]}, {"children": [0]}])
    gltf_measure.measure(doc)  # must return rather than recurse forever


# --------------------------------------------------------------------------
# The approximation, stated honestly
# --------------------------------------------------------------------------


def test_a_cardinal_rotation_is_exact():
    """A 90 degree turn about an axis maps an AABB onto itself, permuted."""
    half = math.sqrt(0.5)
    doc = document(
        nodes=[{"mesh": 0, "rotation": [0, half, 0, half]}],  # +90 deg about Y
        accessors=[unit_cube_accessor(minimum=(-1, -2, -3), maximum=(1, 2, 3))],
    )
    measurement = gltf_measure.measure(doc)
    assert np.allclose(measurement.size, [6, 4, 2], atol=1e-6), measurement.size


def test_an_off_axis_rotation_overestimates_but_is_bounded():
    """The documented cost of not decoding vertices: a superset, never a subset.

    Worst case is sqrt(3) per axis. Anything larger is a bug, and anything
    smaller than the true bounds would be a validator that passes bad models.
    """
    half = math.sqrt(0.5)
    doc = document(
        nodes=[{"mesh": 0, "rotation": [0, math.sin(math.pi / 8), 0, math.cos(math.pi / 8)]}],
        accessors=[unit_cube_accessor()],  # 2x2x2
    )
    size = gltf_measure.measure(doc).size
    assert np.all(size >= 2 - 1e-9), f"bounds must never undershoot: {size}"
    assert np.all(size <= 2 * math.sqrt(3) + 1e-9), f"bounds overshot the limit: {size}"
    assert size[0] > 2.0, "a 45 degree turn about Y should widen X"
    assert math.isclose(size[1], 2.0, abs_tol=1e-9), "Y is the rotation axis and must not change"
    assert half > 0  # keeps the import honest


# --------------------------------------------------------------------------
# Malformed input
# --------------------------------------------------------------------------


def test_a_position_accessor_without_bounds_is_reported_not_ignored():
    """glTF 2.0 makes min/max a MUST. Silence here would pass a bad model."""
    doc = document(accessors=[{"count": 36, "type": "VEC3"}])
    measurement = gltf_measure.measure(doc)
    assert measurement.size is None
    assert measurement.problems, "a missing min/max must be reported"
    assert "min/max" in measurement.problems[0], measurement.problems


def test_an_empty_document_reports_no_geometry():
    measurement = gltf_measure.measure({"asset": {"version": "2.0"}})
    assert measurement.size is None
    assert measurement.triangles == 0
    assert measurement.problems


# --------------------------------------------------------------------------
# The real models in this repo
# --------------------------------------------------------------------------


def test_measures_the_example_cube():
    measurement = gltf_measure.measure(gltf_document.load_document(EXAMPLE_GLTF))
    assert not measurement.problems, measurement.problems
    assert np.allclose(measurement.size, [2.0, 2.044832, 2.909087], atol=1e-5), measurement.size
    assert np.allclose(
        measurement.minimum, [-1.0, -0.018917, -1.909087], atol=1e-5
    ), measurement.minimum
    assert measurement.triangles == 24, measurement.triangles


def test_a_ninety_degree_node_rotation_is_applied_to_the_bounds():
    """The fixture and the example cube must measure the same in world space.

    unapplied_rotation_90z.gltf is the example cube with its geometry
    pre-rotated in local space and a +90 degree node rotation putting it back.
    Its local AABB is [2.909087, 2.044832, 2.0] -- X and Z swapped. If the node
    matrix is ignored, those swapped numbers are what comes out, and this is the
    only test that notices.
    """
    example = gltf_measure.measure(gltf_document.load_document(EXAMPLE_GLTF))
    rotated = gltf_measure.measure(gltf_document.load_document(ROTATED_FIXTURE))
    assert np.allclose(rotated.size, example.size, atol=1e-5), (
        f"the rotated fixture measured {rotated.size} but should match the "
        f"unrotated original's {example.size}; X and Z swapped means the node "
        "matrix was not composed into the bounds"
    )
    assert rotated.triangles == example.triangles


def test_measures_the_wolf_glb():
    """Third-party art, so assert shape rather than exact numbers."""
    if not WOLF_GLB.exists():
        return
    measurement = gltf_measure.measure(gltf_document.load_document(WOLF_GLB))
    assert not measurement.problems, measurement.problems
    assert measurement.triangles > 0
    assert np.all(np.isfinite(measurement.size)), measurement.size
    assert np.all(measurement.size > 0), measurement.size
    # 38 box meshes, one node each: instanced and unique agree here, but both
    # numbers must be reported for the poly-budget line to make sense.
    assert measurement.instances >= measurement.unique_meshes


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
