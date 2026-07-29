"""Read a .gltf or .glb into plain JSON, with no third-party dependencies.

This is the *one* loader. Everything that inspects a model -- the local CLI, the
Docker validator, check_facing.py -- goes through here, so a verdict computed on a
laptop and a verdict computed in CI are computed from byte-identical inputs. That
is a structural guarantee rather than a convention: there is no second code path
to drift from.

Two shapes come out of this module:

* `load_document(path)` -> the raw glTF JSON as a dict. Index-addressed and
  faithful to the file. This is what measurement code wants, because it needs
  `accessors`, `meshes` and `bufferViews` by index.
* `as_gltf(document)` -> the same data with attribute access, matching the shape
  `pygltflib.GLTF2` presents. This is what the check engine wants, because
  gltf_axes, gltf_transforms and the spec checks were all written against
  pygltflib and read `gltf.nodes[i].rotation` rather than `d["nodes"][i]["rotation"]`.

`as_gltf` builds *every* key it knows about, defaulting to `[]` or `None`. That is
deliberate and load-bearing: several consumers read attributes directly rather
than through `getattr(..., default)` -- `evaluate_model_against_spec` does
`len(gltf.materials)` and `list_textures` does `gltf.textures` -- so a key omitted
because the document happened not to contain it would raise AttributeError rather
than behave like an empty model.

Stdlib only, deliberately: this module is imported by a git pre-commit hook and a
Claude Code hook, where a numpy import is a cost paid on every commit.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import unquote, urlparse

GLB_MAGIC = 0x46546C67  # "glTF"
CHUNK_JSON = 0x4E4F534A  # "JSON"
CHUNK_BIN = 0x004E4942  # "BIN\0"

MODEL_EXTENSIONS = (".gltf", ".glb")


def read_glb(path) -> tuple[dict, bytes | None]:
    """Split a binary glTF container into its JSON chunk and its BIN chunk.

    The BIN chunk is returned so callers can resolve buffers with no `uri` --
    a .glb keeps its geometry inline rather than in a sibling .bin file, so
    "the buffer is missing" means something different for the two containers.
    """
    data = Path(path).read_bytes()
    if len(data) < 12:
        raise ValueError("file is too short to be a GLB")
    magic, version, _length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        raise ValueError("not a GLB (bad magic)")
    if version != 2:
        raise ValueError(f"unsupported GLB version {version}")

    document: dict | None = None
    binary: bytes | None = None
    offset = 12
    while offset + 8 <= len(data):
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk = data[offset : offset + chunk_length]
        if chunk_type == CHUNK_JSON and document is None:
            document = json.loads(chunk.decode("utf-8"))
        elif chunk_type == CHUNK_BIN and binary is None:
            binary = chunk
        offset += chunk_length
        # Chunks are 4-byte aligned; the padding is inside chunk_length for JSON
        # (spaces) and BIN (zeros), so no extra skip is needed here.

    if document is None:
        raise ValueError("no JSON chunk found in GLB")
    return document, binary


def read_glb_json(path) -> dict:
    """Just the JSON chunk of a GLB. Kept for callers that need nothing else."""
    return read_glb(path)[0]


def load_document(path) -> dict:
    """Read a .gltf or .glb into the raw glTF JSON dict."""
    path = Path(path)
    if path.suffix.lower() == ".glb":
        return read_glb_json(path)
    return json.loads(path.read_text(encoding="utf-8"))


def load_with_binary(path) -> tuple[dict, bytes | None]:
    """As load_document, but also returns a .glb's embedded BIN chunk."""
    path = Path(path)
    if path.suffix.lower() == ".glb":
        return read_glb(path)
    return json.loads(path.read_text(encoding="utf-8")), None


def is_external_uri(uri) -> bool:
    """True when a uri points at a sibling file rather than inline bytes.

    glTF allows `data:` URIs for embedded content and full URLs for remote
    content. Only the relative-path case is something we can check on disk.
    """
    if not uri:
        return False
    scheme = urlparse(uri).scheme.lower()
    return scheme in ("", "file")


def resolve_uri(base_dir, uri) -> Path | None:
    """Resolve a glTF uri against the model's directory, or None if not a file.

    glTF uris are percent-encoded, so a texture called "rain barrel.png" appears
    as "rain%20barrel.png" and will not be found on disk without unquoting.
    """
    if not is_external_uri(uri):
        return None
    return Path(base_dir) / unquote(uri)


def _node(node: dict) -> SimpleNamespace:
    return SimpleNamespace(
        name=node.get("name"),
        mesh=node.get("mesh"),
        skin=node.get("skin"),
        camera=node.get("camera"),
        children=node.get("children"),
        rotation=node.get("rotation"),
        translation=node.get("translation"),
        scale=node.get("scale"),
        matrix=node.get("matrix"),
    )


def _animation(animation: dict) -> SimpleNamespace:
    return SimpleNamespace(
        name=animation.get("name"),
        channels=[
            SimpleNamespace(
                target=SimpleNamespace(
                    node=channel.get("target", {}).get("node"),
                    path=channel.get("target", {}).get("path"),
                ),
                sampler=channel.get("sampler"),
            )
            for channel in animation.get("channels", [])
        ],
    )


def as_gltf(document: dict) -> SimpleNamespace:
    """Give the raw JSON the attribute shape pygltflib.GLTF2 presents.

    Every field the validator reads is built here, even when absent from the
    document -- see the module docstring for why omission is not an option.
    """
    return SimpleNamespace(
        # `scene` defaults to 0 rather than None: get_gltf_scale indexes
        # gltf.scenes[gltf.scene] directly and would raise on None. gltf_axes
        # tolerates either.
        scene=document.get("scene", 0),
        scenes=[
            SimpleNamespace(name=scene.get("name"), nodes=scene.get("nodes"))
            for scene in document.get("scenes", [])
        ],
        nodes=[_node(node) for node in document.get("nodes", [])],
        meshes=[
            SimpleNamespace(
                name=mesh.get("name"),
                primitives=[
                    SimpleNamespace(
                        attributes=SimpleNamespace(**primitive.get("attributes", {})),
                        indices=primitive.get("indices"),
                        material=primitive.get("material"),
                        mode=primitive.get("mode"),
                        targets=primitive.get("targets"),
                    )
                    for primitive in mesh.get("primitives", [])
                ],
            )
            for mesh in document.get("meshes", [])
        ],
        # Joints and animated nodes are allowed to carry transforms; the
        # transform check needs these to know which nodes to leave alone.
        skins=[
            SimpleNamespace(
                name=skin.get("name"),
                joints=skin.get("joints"),
                skeleton=skin.get("skeleton"),
            )
            for skin in document.get("skins", [])
        ],
        animations=[_animation(animation) for animation in document.get("animations", [])],
        materials=[
            SimpleNamespace(name=material.get("name"))
            for material in document.get("materials", [])
        ],
        images=[
            SimpleNamespace(
                name=image.get("name"),
                uri=image.get("uri"),
                bufferView=image.get("bufferView"),
                mimeType=image.get("mimeType"),
            )
            for image in document.get("images", [])
        ],
        textures=[
            SimpleNamespace(name=texture.get("name"), source=texture.get("source"))
            for texture in document.get("textures", [])
        ],
        accessors=[
            SimpleNamespace(
                name=accessor.get("name"),
                bufferView=accessor.get("bufferView"),
                componentType=accessor.get("componentType"),
                count=accessor.get("count"),
                type=accessor.get("type"),
                min=accessor.get("min"),
                max=accessor.get("max"),
                byteOffset=accessor.get("byteOffset", 0),
                normalized=accessor.get("normalized", False),
                sparse=accessor.get("sparse"),
            )
            for accessor in document.get("accessors", [])
        ],
        bufferViews=[
            SimpleNamespace(
                buffer=view.get("buffer"),
                byteOffset=view.get("byteOffset", 0),
                byteLength=view.get("byteLength"),
                byteStride=view.get("byteStride"),
            )
            for view in document.get("bufferViews", [])
        ],
        buffers=[
            SimpleNamespace(uri=buffer.get("uri"), byteLength=buffer.get("byteLength"))
            for buffer in document.get("buffers", [])
        ],
        asset=SimpleNamespace(**document.get("asset", {})),
        extensionsUsed=document.get("extensionsUsed", []),
        extensionsRequired=document.get("extensionsRequired", []),
    )


def load(path) -> tuple[dict, SimpleNamespace]:
    """Both shapes at once: the raw document and its attribute view."""
    document = load_document(path)
    return document, as_gltf(document)
