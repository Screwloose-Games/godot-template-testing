#!/usr/bin/env python3
"""Tests for gltf_godot_import.py — the checks about life after the importer.

Runs standalone (`python tools/gltf-validator/test_gltf_godot_import.py`) like the
other validators, and also under pytest. Needs only numpy.

The load-bearing case is `test_a_steering_wheel_is_caught`. That exact name --
`steering_wheel`, an ordinary description of an ordinary object -- silently
imported as a VehicleWheel3D while building assets/art/3d/vehicles/jeep_turret, and
was only found by reading the imported scene tree in the editor. The file was
valid glTF throughout, so every other check in this repo passed it. If the
underscore matching in `node_suffix` ever regresses, that test is what notices.

Synthetic documents are built as glTF JSON rather than as binary fixtures: node
names and accessor min/max live entirely in the JSON, and a fixture you can read
in the diff beats a .glb nobody can inspect.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gltf_godot_import as godot  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]


def document(nodes):
    """A scene whose every node carries the same 1x1x1 box mesh.

    Each node gets its own accessor so bounds can be posed per node, which is what
    the collision checks need.
    """
    accessors = []
    meshes = []
    for node in nodes:
        low = node.pop("_min", [-0.5, -0.5, -0.5])
        high = node.pop("_max", [0.5, 0.5, 0.5])
        accessors.append({"count": 36, "type": "VEC3", "min": low, "max": high})
        meshes.append({"primitives": [{"attributes": {"POSITION": len(accessors) - 1}}]})
        node["mesh"] = len(meshes) - 1
    return {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "accessors": accessors,
    }


# --- node type suffixes -------------------------------------------------------


def test_a_steering_wheel_is_caught():
    """The regression this whole module exists for."""
    found = godot.find_surprising_suffixes(document([{"name": "steering_wheel"}]))
    assert len(found) == 1, found
    name, suffix, becomes = found[0]
    assert name == "steering_wheel", found
    assert suffix == "wheel", found
    assert "VehicleWheel3D" in becomes, found


def test_all_three_separators_match():
    """Godot's _teststr accepts '-name', '_name' and '$name' alike."""
    for name in ("chassis-vehicle", "chassis_vehicle", "chassis$vehicle"):
        found = godot.find_surprising_suffixes(document([{"name": name}]))
        assert len(found) == 1, (name, found)
        assert found[0][1] == "vehicle", (name, found)


def test_collision_and_navmesh_suffixes_are_intended():
    nodes = [{"name": n} for n in
             ("body-convcolonly", "hull-col", "floor-navmesh", "prop-convcol")]
    assert godot.find_surprising_suffixes(document(nodes)) == []


def test_a_spec_can_opt_a_suffix_in():
    doc = document([{"name": "chassis-vehicle"}])
    assert godot.find_surprising_suffixes(doc) != []
    assert godot.find_surprising_suffixes(doc, allowed=["vehicle"]) == []


def test_ordinary_names_are_left_alone():
    nodes = [{"name": n} for n in
             ("wheel_fl", "wheel_fl_spin", "turret_yaw", "roll_cage", "body")]
    assert godot.find_surprising_suffixes(document(nodes)) == []


def test_a_name_that_merely_contains_a_suffix_is_not_flagged():
    """'wheelhouse' ends in neither '-wheel' nor '_wheel'."""
    assert godot.find_surprising_suffixes(document([{"name": "wheelhouse"}])) == []


# --- oversized collision ------------------------------------------------------


def test_a_proxy_taller_than_the_art_is_caught():
    """The turret case: a proxy 7cm above the shield became the model's height."""
    doc = document([
        {"name": "shield", "_min": [-0.5, 0.0, -0.5], "_max": [0.5, 2.14, 0.5]},
        {"name": "turret-convcolonly", "_min": [-0.5, 0.0, -0.5], "_max": [0.5, 2.21, 0.5]},
    ])
    findings = godot.oversized_collision(doc)
    assert len(findings) == 1, findings
    axis, side, amount = findings[0]
    assert (axis, side) == ("Y", "above"), findings
    assert abs(amount - 0.07) < 1e-6, findings


def test_a_proxy_inside_the_art_passes():
    doc = document([
        {"name": "body", "_min": [-1.0, 0.0, -1.0], "_max": [1.0, 2.0, 1.0]},
        {"name": "body-convcolonly", "_min": [-0.9, 0.05, -0.9], "_max": [0.9, 1.9, 0.9]},
    ])
    assert godot.oversized_collision(doc) == []


def test_millimetres_of_faceting_are_tolerated():
    """A hull hugging a curved surface pokes a few mm past the faceted mesh.

    The jeep's wheel proxies sit 3mm below its tyres, and that is correct -- what a
    vehicle rests on is its collision. Only centimetres mean a wrong-sized proxy.
    """
    doc = document([
        {"name": "tyre", "_min": [-0.5, 0.003, -0.5], "_max": [0.5, 0.84, 0.5]},
        {"name": "wheel-convcolonly", "_min": [-0.5, 0.0, -0.5], "_max": [0.5, 0.84, 0.5]},
    ])
    assert godot.oversized_collision(doc) == []


def test_a_model_with_no_collision_is_not_judged():
    assert godot.oversized_collision(document([{"name": "body"}])) == []


def test_a_model_with_only_collision_is_not_judged():
    """Nothing to compare against, so there is nothing to say."""
    assert godot.oversized_collision(document([{"name": "body-convcolonly"}])) == []


# --- ground contact -----------------------------------------------------------


def test_ground_offset_reads_the_lowest_point_in_gltf_up():
    doc = document([{"name": "body", "_min": [-1.0, 0.25, -1.0], "_max": [1.0, 2.0, 1.0]}])
    assert abs(godot.ground_offset(doc) - 0.25) < 1e-9


def test_ground_offset_includes_collision():
    """What an object rests on is its collision, not its art."""
    doc = document([
        {"name": "body", "_min": [-1.0, 0.05, -1.0], "_max": [1.0, 2.0, 1.0]},
        {"name": "body-convcolonly", "_min": [-1.0, 0.0, -1.0], "_max": [1.0, 2.0, 1.0]},
    ])
    assert abs(godot.ground_offset(doc)) < 1e-9


def test_ground_offset_composes_node_transforms():
    """A node translation moves the model; reading accessor min/max alone misses it."""
    doc = document([{"name": "body", "_min": [-1.0, 0.0, -1.0], "_max": [1.0, 2.0, 1.0]}])
    doc["nodes"][0]["translation"] = [0.0, 0.5, 0.0]
    assert abs(godot.ground_offset(doc) - 0.5) < 1e-9


def test_ground_offset_is_none_without_geometry():
    assert godot.ground_offset({"asset": {"version": "2.0"}}) is None


# --- the real asset -----------------------------------------------------------


def test_the_shipped_jeep_passes_every_check():
    """An end-to-end pin against a real, committed model."""
    import gltf_document

    path = REPO_ROOT / "assets/art/3d/vehicles/jeep_turret/sm_jeep_turret.gltf"
    if not path.exists():  # the asset may not be present in every checkout
        return
    doc = gltf_document.load_document(str(path))
    assert godot.find_surprising_suffixes(doc) == []
    assert godot.oversized_collision(doc) == []
    offset = godot.ground_offset(doc)
    assert abs(offset) <= godot.GROUND_TOLERANCE, offset


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
