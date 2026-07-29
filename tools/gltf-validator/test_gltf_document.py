#!/usr/bin/env python3
"""Tests for gltf_document.py — the one loader.

Runs standalone (`python tools/gltf-validator/test_gltf_document.py`) like the
validators in .github/scripts/, and also under pytest. Stdlib only.

Two things are being defended here.

First, that `as_gltf` builds *every* attribute the validator reads. The check
engine and the `list_*` report helpers were written against pygltflib and read
`gltf.materials` and `gltf.textures` directly, not through `getattr` with a
default -- so an attribute missing because the document didn't happen to contain
that key raises AttributeError instead of behaving like an empty model. The
`test_every_attribute_exists_on_an_empty_document` case is the guard.

Second, that dropping pygltflib did not change what those helpers see.
`test_matches_pygltflib` compares the two loaders directly and is skipped when
pygltflib is absent, which is every machine except the Docker image -- and the
Docker image is exactly where it needs to run.
"""

from __future__ import annotations

import json
import struct
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import gltf_document  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_GLTF = REPO_ROOT / "assets/3d/example_cubes_facing/sm_example_cubes_facing.gltf"
ROTATED_FIXTURE = Path(__file__).resolve().parent / "test-fixtures/unapplied_rotation_90z.gltf"
WOLF_GLB = (
    REPO_ROOT
    / "examples/3d/exploration_quadraped/assets/models/wolf/grey-wolf-gaits-and-jump.glb"
)


def build_glb(document: dict, binary: bytes = b"") -> bytes:
    """Assemble a minimal but spec-shaped GLB container."""
    json_chunk = json.dumps(document).encode("utf-8")
    json_chunk += b" " * (-len(json_chunk) % 4)  # pad with spaces, per the spec
    bin_chunk = binary + b"\0" * (-len(binary) % 4)

    body = struct.pack("<II", len(json_chunk), gltf_document.CHUNK_JSON) + json_chunk
    if binary:
        body += struct.pack("<II", len(bin_chunk), gltf_document.CHUNK_BIN) + bin_chunk
    header = struct.pack("<III", gltf_document.GLB_MAGIC, 2, 12 + len(body))
    return header + body


def write_temp(name: str, data: bytes) -> Path:
    directory = Path(tempfile.mkdtemp())
    path = directory / name
    path.write_bytes(data)
    return path


# --------------------------------------------------------------------------
# Container parsing
# --------------------------------------------------------------------------


def test_reads_a_gltf_json_file():
    path = write_temp("m.gltf", json.dumps({"asset": {"version": "2.0"}}).encode())
    assert gltf_document.load_document(path)["asset"]["version"] == "2.0"


def test_reads_the_json_chunk_of_a_glb():
    path = write_temp("m.glb", build_glb({"asset": {"version": "2.0"}, "nodes": [{}]}))
    document = gltf_document.load_document(path)
    assert document["nodes"] == [{}], document


def test_reads_the_bin_chunk_of_a_glb():
    path = write_temp("m.glb", build_glb({"asset": {"version": "2.0"}}, b"\x01\x02\x03\x04"))
    _document, binary = gltf_document.read_glb(path)
    assert binary == b"\x01\x02\x03\x04", binary


def test_a_gltf_has_no_bin_chunk():
    path = write_temp("m.gltf", json.dumps({"asset": {"version": "2.0"}}).encode())
    _document, binary = gltf_document.load_with_binary(path)
    assert binary is None


def test_rejects_a_file_that_is_not_a_glb():
    path = write_temp("m.glb", b"not a gltf at all, not even close")
    try:
        gltf_document.load_document(path)
    except ValueError as exc:
        assert "magic" in str(exc), exc
    else:
        raise AssertionError("a file with the wrong magic should not parse as a GLB")


def test_rejects_a_truncated_glb():
    path = write_temp("m.glb", b"glTF")
    try:
        gltf_document.load_document(path)
    except ValueError as exc:
        assert "too short" in str(exc), exc
    else:
        raise AssertionError("a 4-byte file should not parse as a GLB")


# --------------------------------------------------------------------------
# The attribute view
# --------------------------------------------------------------------------


def test_every_attribute_exists_on_an_empty_document():
    """The failure this prevents: AttributeError instead of "no materials".

    evaluate_model_against_spec does `len(gltf.materials)` and list_textures
    does `if not gltf.textures`. Both are direct attribute reads.
    """
    gltf = gltf_document.as_gltf({})
    for attribute in (
        "scene", "scenes", "nodes", "meshes", "skins", "animations", "materials",
        "images", "textures", "accessors", "bufferViews", "buffers", "asset",
        "extensionsUsed", "extensionsRequired",
    ):
        assert hasattr(gltf, attribute), f"as_gltf({{}}) is missing .{attribute}"

    # And the list-shaped ones must be falsy-but-iterable, not None, so that
    # `for material in gltf.materials` works on a document with no materials.
    for attribute in ("scenes", "nodes", "meshes", "materials", "images", "textures"):
        value = getattr(gltf, attribute)
        assert value == [], f".{attribute} should default to [], got {value!r}"


def test_node_transform_fields_survive_the_round_trip():
    gltf = gltf_document.as_gltf(
        {
            "nodes": [
                {
                    "name": "Cube",
                    "mesh": 0,
                    "children": [1],
                    "rotation": [0, 0.7071068, 0, 0.7071068],
                    "translation": [1, 2, 3],
                    "scale": [2, 2, 2],
                }
            ]
        }
    )
    node = gltf.nodes[0]
    assert node.name == "Cube"
    assert node.mesh == 0
    assert node.children == [1]
    assert node.rotation == [0, 0.7071068, 0, 0.7071068]
    assert node.translation == [1, 2, 3]
    assert node.scale == [2, 2, 2]
    assert node.matrix is None


def test_a_mesh_index_of_zero_is_not_confused_with_absent():
    """`node.mesh = 0` is a real mesh reference, and 0 is falsy.

    gltf_axes._chain_to_first_mesh tests `is not None` for exactly this reason;
    the loader must not collapse 0 to None on the way in.
    """
    gltf = gltf_document.as_gltf({"nodes": [{"mesh": 0}, {}]})
    assert gltf.nodes[0].mesh == 0
    assert gltf.nodes[1].mesh is None


def test_primitive_attributes_are_accessible_by_name():
    gltf = gltf_document.as_gltf(
        {"meshes": [{"primitives": [{"attributes": {"POSITION": 3, "NORMAL": 4}, "indices": 5}]}]}
    )
    primitive = gltf.meshes[0].primitives[0]
    assert primitive.attributes.POSITION == 3
    assert primitive.attributes.NORMAL == 4
    assert primitive.indices == 5
    assert primitive.mode is None  # absent means TRIANGLES; the caller applies the default


def test_animation_channel_targets_are_reachable():
    """gltf_transforms._exempt_nodes walks animations[].channels[].target.node."""
    gltf = gltf_document.as_gltf(
        {
            "animations": [
                {"name": "walk", "channels": [{"target": {"node": 7, "path": "rotation"}}]}
            ]
        }
    )
    assert gltf.animations[0].name == "walk"
    assert gltf.animations[0].channels[0].target.node == 7


def test_scene_defaults_to_zero():
    """get_gltf_scale indexes gltf.scenes[gltf.scene] and would raise on None."""
    assert gltf_document.as_gltf({"scenes": [{"nodes": [0]}]}).scene == 0


# --------------------------------------------------------------------------
# URI resolution
# --------------------------------------------------------------------------


def test_a_percent_encoded_uri_resolves_to_the_real_filename():
    """A texture called "rain barrel.png" is stored as "rain%20barrel.png"."""
    resolved = gltf_document.resolve_uri("/models", "rain%20barrel.png")
    assert resolved.name == "rain barrel.png", resolved


def test_a_data_uri_is_not_a_file():
    assert gltf_document.resolve_uri("/models", "data:application/octet-stream;base64,AAAA") is None
    assert gltf_document.is_external_uri("data:application/gltf-buffer;base64,AA") is False


def test_a_remote_uri_is_not_a_file():
    assert gltf_document.is_external_uri("https://example.com/t.png") is False


def test_a_relative_uri_is_a_file():
    assert gltf_document.is_external_uri("textures/t_wood.png") is True


# --------------------------------------------------------------------------
# The real models in this repo
# --------------------------------------------------------------------------


def test_loads_the_example_cube():
    document, gltf = gltf_document.load(EXAMPLE_GLTF)
    assert document["asset"]["version"] == "2.0"
    assert len(gltf.nodes) >= 1
    assert gltf.buffers[0].uri == "sm_example_cubes_facing.bin"
    assert gltf.accessors, "the example model should declare accessors"


def test_the_example_cube_declares_position_bounds():
    """glTF 2.0 requires min/max on POSITION accessors, and the repo honours it.

    The headless bounds computation depends on this being true, so it is
    asserted against the real asset rather than taken on faith.
    """
    document = gltf_document.load_document(EXAMPLE_GLTF)
    positions = [
        document["accessors"][primitive["attributes"]["POSITION"]]
        for mesh in document["meshes"]
        for primitive in mesh["primitives"]
    ]
    assert positions, "the example model should have at least one primitive"
    for accessor in positions:
        assert accessor.get("min") and accessor.get("max"), accessor


def test_loads_the_rotated_fixture():
    _document, gltf = gltf_document.load(ROTATED_FIXTURE)
    assert gltf.nodes[0].rotation is not None, "the fixture's whole point is a node rotation"


def test_loads_the_wolf_glb():
    if not WOLF_GLB.exists():
        return  # third-party art; may be replaced or removed
    document, gltf = gltf_document.load(WOLF_GLB)
    assert gltf.meshes, "the wolf should have meshes"
    assert gltf.animations, "the wolf should have animations"
    # A .glb keeps geometry inline: its buffer has no uri, which is why
    # "missing buffer" means something different for the two containers.
    assert gltf.buffers[0].uri is None, "a .glb buffer should have no uri"
    assert document["buffers"][0]["byteLength"] > 0


def test_matches_pygltflib():
    """The two loaders must agree. Skipped unless pygltflib is installed.

    This is the divergence guard for dropping pygltflib from validate_gltf.py.
    It only runs inside the Docker image, which is the only place pygltflib
    exists -- and the only place the two loaders could ever have disagreed.
    """
    try:
        from pygltflib import GLTF2
    except ImportError:
        return

    import model_spec

    for path in (EXAMPLE_GLTF, ROTATED_FIXTURE, WOLF_GLB):
        if not path.exists():
            continue
        reference = GLTF2().load(str(path))
        ours = gltf_document.as_gltf(gltf_document.load_document(path))
        for helper in (
            model_spec.list_images,
            model_spec.list_animations,
            model_spec.list_materials,
            model_spec.list_textures,
            model_spec.list_bones,
        ):
            assert helper(reference) == helper(ours), (
                f"{helper.__name__} disagrees between pygltflib and gltf_document "
                f"for {path.name}"
            )


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
