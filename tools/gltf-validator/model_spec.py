"""Judge a glTF model against its `<model>.gltf.spec.yaml`.

This is the check engine, lifted out of validate_gltf.py so that judging a model
no longer requires the ability to render one. It used to sit in the middle of an
850-line script that imported trimesh, pyrender and PIL, which meant the only way
to find out whether a model passed was to push a branch and wait for a container
to boot an X server. Nothing here needs any of that: every check reads the node
graph, the accessor metadata or the file system.

`evaluate_model_against_spec` is unchanged from the version that lived in
validate_gltf.py, down to its signature, so the same verdicts come out for the
same inputs. What is new here is around it:

* `validate_spec_schema` checks the spec against schemas/model-spec.schema.json.
  The schema has always existed and nothing has ever validated against it, so a
  key with a typo in it -- `poly_budget` for `poly_count_budget` -- was silently
  ignored and the check the artist asked for simply never ran. Because the schema
  sets `additionalProperties: false`, that is now a hard error.
* `verdicts_failed` reduces the result dict to a pass/fail. CI previously gated
  on validate_gltf.py's `success` flag, which meant "loaded and rendered" rather
  than "passed the spec" -- so a model that FAILed shipped green.
* `check_external_resources` promotes the missing-.bin scan from a bail-out in
  the middle of the render path to a named check, because a .gltf committed
  without its .bin is the failure that actually reaches main.

Depends on numpy and pyyaml; jsonschema is optional and degrades to a reported
problem rather than a crash, matching validate-pipeline-doc.py.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import unquote

import numpy as np
import yaml

from gltf_axes import get_model_facing_direction, get_model_up_direction
from gltf_document import is_external_uri, resolve_uri
from gltf_transforms import find_unapplied_transforms, format_report

SPEC_EXTENSION = ".spec.yaml"
SCHEMA_RELATIVE_PATH = Path("schemas") / "model-spec.schema.json"


def _schema_candidates(module_path: Path, cwd: Path) -> list[Path]:
    """Where model-spec.schema.json might be, on either side of the Docker boundary.

    In a checkout this module sits two directories below the repo root. In the
    validator image it is copied to /app while the repo is mounted at the working
    directory, so walking up from __file__ finds nothing. Try both rather than
    assuming a layout: getting this wrong means the schema check silently
    reports "schema not found" instead of catching a typo'd spec key.

    The ancestor candidate is built only when that ancestor exists. /app has no
    third parent, and indexing .parents past the filesystem root raises
    IndexError rather than returning something that simply fails .exists() --
    which took the whole renderer down at import time, before it could fall back
    to the working directory that would have worked.

    Split out from _find_schema so the flattened-image layout is testable without
    a container: this is the one code path that differs between the two, and it
    had no test precisely because every test runs from a checkout.
    """
    candidates = []
    parents = module_path.resolve().parents
    if len(parents) > 2:
        candidates.append(parents[2] / SCHEMA_RELATIVE_PATH)
    candidates.append(cwd / SCHEMA_RELATIVE_PATH)
    return candidates


def _find_schema() -> Path:
    candidates = _schema_candidates(Path(__file__), Path.cwd())
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return candidates[0]


SCHEMA_PATH = _find_schema()

# Size checks pass within this fraction of the declared dimension.
SIZE_TOLERANCE = 0.10


# ---------------------------------------------------------------------------
# Reading the spec
# ---------------------------------------------------------------------------


def spec_path_for(model_path) -> str:
    """The spec that belongs to a model.

    Named for the *whole* model filename, so sm_rain_barrel.gltf pairs with
    sm_rain_barrel.gltf.spec.yaml and not sm_rain_barrel.spec.yaml. The
    validator looks for exactly this name and silently skips anything else,
    which is why the near-miss is worth a check of its own.
    """
    return str(model_path) + SPEC_EXTENSION


def model_path_for(spec_path) -> str:
    """The model a spec belongs to. Inverse of spec_path_for."""
    text = str(spec_path)
    return text[: -len(SPEC_EXTENSION)] if text.endswith(SPEC_EXTENSION) else text


def read_spec_file(spec_file) -> dict:
    """
    Read the yaml spec file and return a dictionary with the contents.
    """
    if not os.path.exists(spec_file):
        return {}
    with open(spec_file, "r", encoding="utf-8") as handle:
        spec = yaml.safe_load(handle)
    return spec or {}


def _import_jsonschema():
    """Indirection so the absent-jsonschema path is reachable from a test."""
    try:
        import jsonschema
    except ImportError:
        return None
    return jsonschema


def validate_spec_schema(spec: dict, spec_path=None) -> list[str]:
    """Check a spec against schemas/model-spec.schema.json.

    Returns a list of human-readable problems; empty means the spec is sound.
    A missing jsonschema is reported as a problem rather than raised, so that
    running the validator without it degrades to "this was not checked" instead
    of crashing -- the same trade validate-pipeline-doc.py makes.
    """
    label = os.path.basename(str(spec_path)) if spec_path else "spec"

    if not isinstance(spec, dict):
        return [f"{label}: expected a mapping of spec keys, got {type(spec).__name__}"]
    if not spec:
        return []

    # Resolved per call, not once at import: the working directory decides which
    # candidate wins inside the container.
    schema_path = _find_schema()
    if not schema_path.exists():
        return [f"{label}: schema not found at {schema_path}"]

    jsonschema = _import_jsonschema()
    if jsonschema is None:
        return [
            f"{label}: jsonschema is not installed, so the spec's structure was NOT "
            "checked. Unknown or misspelled keys will be ignored silently. "
            "Install it with: pip install jsonschema"
        ]

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    problems = []
    for error in sorted(validator.iter_errors(spec), key=lambda e: list(e.path)):
        where = ".".join(str(part) for part in error.path)
        # additionalProperties is the whole reason this check exists, so give
        # it a message that names the fix rather than quoting the schema.
        if error.validator == "additionalProperties":
            problems.append(
                f"{label}: {error.message}. Every spec key is optional, but an "
                "unrecognised one is always a mistake -- it is silently ignored, so "
                "the check you meant to enable never runs. See "
                "schemas/model-spec.schema.json for the valid keys."
            )
        else:
            problems.append(f"{label}: {where or '(root)'}: {error.message}")
    return problems


# ---------------------------------------------------------------------------
# Listing what a model contains
# ---------------------------------------------------------------------------


def list_animations(gltf) -> list[str]:
    """
    Lists all animations in the scene.
    """
    animations = []
    if not gltf.animations:
        return animations
    for animation in gltf.animations:
        animations.append(animation.name)
    return animations


def list_textures(gltf) -> list[str]:
    """
    Lists all textures in the scene.
    """
    textures = []
    if not gltf.textures:
        return textures
    for texture in gltf.textures:
        texture_strs = []
        if hasattr(texture, 'source') and texture.source is not None:
            image_str = list_images(gltf)[texture.source]
            texture_strs.append(f"Image: {image_str}")
        if hasattr(texture, 'name') and texture.name:
            texture_strs.append(f"Name: {texture.name}")
        textures.append("| ".join(texture_strs))
    return textures


def list_images(gltf) -> list[str]:
    """
    Lists all images in the scene.
    """
    images = []
    if not gltf.images:
        return images
    for image in gltf.images:
        if hasattr(image, 'uri') and image.uri:
            decoded_uri = unquote(image.uri)
            images.append(decoded_uri)
        elif hasattr(image, 'name') and image.name:
            images.append(image.name)
        elif hasattr(image, 'bufferView') and image.bufferView:
            images.append(f"BufferView id: {image.bufferView}")
        else:
            images.append("Unknown image")
    return images


def list_bones(gltf) -> list[str]:
    """
    Lists all bones in the scene.
    """
    bones = []
    if not gltf.skins:
        return bones
    for skin in gltf.skins:
        for joint_node_id in skin.joints:
            bones.append(gltf.nodes[joint_node_id].name)
    return bones


def list_materials(gltf) -> list[str]:
    """
    Lists all materials in the scene.
    """
    materials = []
    if not gltf.materials:
        return materials
    for material in gltf.materials:
        materials.append(material.name)
    return materials


def get_gltf_scale(gltf) -> float:
    """
    Returns the scale of the glTF model.
    """
    if not gltf.scenes:
        return 1.0
    scene = gltf.scenes[gltf.scene]
    if not scene.nodes:
        return 1.0
    node = gltf.nodes[scene.nodes[0]]
    if not node.scale:
        return 1.0
    return node.scale[0]  # Assuming uniform scaling


# ---------------------------------------------------------------------------
# Files a model depends on
# ---------------------------------------------------------------------------


def check_external_resources(gltf, model_path) -> list[str]:
    """Every sibling file the model references must actually be on disk.

    This is the failure that reaches main: a .gltf committed without its .bin,
    or a texture that was renamed after export. Previously it aborted the whole
    render with an error string; here it is a named check that runs everywhere.

    A .glb keeps its geometry in an internal chunk, so a buffer with no uri is
    correct there and missing only for a .gltf.
    """
    base_dir = os.path.dirname(str(model_path)) or "."
    missing = []

    for image in gltf.images or []:
        uri = getattr(image, "uri", None)
        if uri and is_external_uri(uri):
            resolved = resolve_uri(base_dir, uri)
            if resolved is not None and not resolved.exists():
                missing.append(f"texture: {unquote(uri)}")

    for buffer in gltf.buffers or []:
        uri = getattr(buffer, "uri", None)
        if uri and is_external_uri(uri):
            resolved = resolve_uri(base_dir, uri)
            if resolved is not None and not resolved.exists():
                missing.append(f"buffer: {unquote(uri)}")

    return missing


# ---------------------------------------------------------------------------
# The verdicts
# ---------------------------------------------------------------------------


def evaluate_model_against_spec(
    gltf,
    spec: dict,
    scene_bounds_size,
    poly_count: int,
) -> dict:
    """
    Evaluates the model against the provided spec dictionary.
    Returns a dictionary with results for each spec item.
    """
    results = {}

    # Size checks. Unmeasurable bounds are reported rather than passed: an
    # accessor with no min/max violates the glTF spec, and reporting OK for a
    # dimension nobody measured is how a check quietly stops being a check.
    if scene_bounds_size is None:
        for key in ("width", "height", "depth"):
            if key in spec:
                results[key] = (
                    "UNKNOWN - the model's bounds could not be measured; see the "
                    "external_resources / geometry problems reported above"
                )
    else:
        width, height, depth = scene_bounds_size[0], scene_bounds_size[1], scene_bounds_size[2]
        results["width"] = abs(width - spec.get("width", width)) / spec.get("width", width) <= SIZE_TOLERANCE
        results["height"] = abs(height - spec.get("height", height)) / spec.get("height", height) <= SIZE_TOLERANCE
        results["depth"] = abs(depth - spec.get("depth", depth)) / spec.get("depth", depth) <= SIZE_TOLERANCE

    # Unapplied transforms. Reported as its own result rather than folded into
    # the axis checks: a leftover rotation and a botched axis conversion are the
    # same observable (a rotation on a node), so this check adds a diagnosis
    # alongside the axis verdicts instead of overriding them. See gltf_transforms.
    #
    # A spec that deliberately describes a rotated node -- see the axis checks
    # below, which compare against the spec rather than hard-coding +Y/+Z -- can
    # opt out instead of being blocked by a transform it asked for.
    transforms = find_unapplied_transforms(gltf)
    if spec.get("allow_unapplied_transforms", False):
        pass
    elif transforms.ok:
        results["unapplied_transforms"] = True
    else:
        summary = "; ".join(f"{f.kind} on {f.label}" for f in transforms.failures)
        results["unapplied_transforms"] = (
            f"FAIL - {summary}. Apply it in the modelling program "
            "(Blender: Ctrl+A > Rotation / Scale) and export again, or set "
            "allow_unapplied_transforms in the spec if the node transform is intended."
        )

    # Up direction. Measured from the node graph rather than assumed -- the
    # previous version of this check compared the spec string against the
    # literal "+Y" and never looked at the model at all, so it passed for every
    # asset ever committed.
    up_dir = spec.get("up_direction", None)
    if up_dir:
        up_dir = up_dir.strip().upper()
        model_up = get_model_up_direction(gltf)
        if model_up is None:
            results["up_direction"] = "UNKNOWN (could not determine from the node graph)"
        else:
            results["up_direction"] = (model_up == up_dir)

    # Facing direction is declared, not checked, and is reported as INFO so the
    # PR comment never claims to have verified it.
    #
    # Nothing in a glTF marks which side of a mesh is the face, so facing cannot
    # be read off the geometry. What get_model_facing_direction returns is where
    # the node chain sends the glTF +Z basis vector, which is "+Z" for every
    # clean export whichever way the model was built -- two exports of the same
    # asset facing opposite ways both report "+Z". This project's convention is
    # that geometry faces -Z (Godot's forward, from Blender +Y), so comparing
    # the spec's "-Z" against that measurement would fail every correctly
    # authored model. That trap is exactly what the pipeline's open question
    # worried about; the answer is that the comparison was never meaningful.
    #
    # The node frame is still reported: a deviation from "+Z" means a leftover
    # rotation, which unapplied_transforms above fails on for real.
    facing_dir = spec.get("facing_direction", None)
    if facing_dir:
        facing_dir = facing_dir.strip().upper()
        model_facing = get_model_facing_direction(gltf)
        results["facing_direction"] = (
            f"INFO - spec declares {facing_dir}. Not machine-checkable; confirm it from the "
            f"rendered views below. (Node frame reads {model_facing or 'undetermined'}; "
            "a clean export reads +Z here regardless of which way the model faces.)"
        )

    # Poly count
    poly_budget = spec.get("poly_count_budget", None)
    if poly_budget is not None:
        results["poly_count_budget"] = poly_count <= poly_budget

    # Root node name
    root_node_name = spec.get("root_node_name", None)
    if root_node_name:
        found = False
        for node in gltf.nodes or []:
            if getattr(node, "name", None) == root_node_name:
                found = True
                break
        results["root_node_name"] = found

    # Collision expected
    if "collision_expected" in spec:
        found = False
        for node in gltf.nodes or []:
            name = (getattr(node, "name", "") or "").lower()

            has_collision = name.endswith("-colonly") or name.endswith("-col")\
                  or name.endswith("-convcol") or name.endswith("-convcolonly")

            if has_collision:
                found = True
                break
        results["collision_expected"] = found == bool(spec["collision_expected"])

    # Navigation expected
    if "navigation_expected" in spec:
        found = False
        for node in gltf.nodes or []:
            if (getattr(node, "name", "") or "").lower().endswith("-navmesh"):
                found = True
                break
        results["navigation_expected"] = found == bool(spec["navigation_expected"])

    # Minimum material count
    min_material_count = spec.get("min_material_count", None)
    if min_material_count is not None:
        mat_count = len(gltf.materials) if gltf.materials else 0
        results["min_material_count"] = mat_count >= min_material_count

    # Textures expected
    if "textures_expected" in spec:
        image_uris = set(list_images(gltf))
        textures_ok = True
        for tex in spec["textures_expected"]:
            expected = tex.get("expected", True)
            name = tex.get("name", "")
            found = any(name in uri for uri in image_uris)
            if expected and not found:
                textures_ok = False
        results["textures_expected"] = textures_ok

    # Animations expected
    if "animations_expected" in spec:
        anim_names = set(list_animations(gltf))
        anims_ok = True
        for anim in spec["animations_expected"]:
            name = anim.get("name", "")
            if name and name not in anim_names:
                anims_ok = False
        results["animations_expected"] = anims_ok

    for key, value in results.items():
        if value == False:
            results[key] = "FAIL"
        elif value == True:
            results[key] = "OK"
        elif isinstance(value, str):
            results[key] = value
        else:
            results[key] = "FAIL"

    return results


def is_informational(value) -> bool:
    """INFO verdicts are declarations the validator cannot verify.

    They get their own marker rather than a red cross that reads as a failure
    nobody can act on -- the same rule create_github_comment applies when it
    renders the PR comment.
    """
    return isinstance(value, str) and value.startswith("INFO")


def verdicts_failed(results: dict) -> list[str]:
    """The spec keys that did not pass.

    "OK" and "INFO - ..." pass; everything else -- "FAIL", "UNKNOWN" -- fails.
    This is the reducer CI was missing: it gated on whether the validator had
    managed to render a picture, not on whether the model met its spec.
    """
    return [
        key
        for key, value in results.items()
        if value != "OK" and not is_informational(value)
    ]


def transform_report(gltf) -> str:
    """The human-readable diagnosis behind an unapplied_transforms failure."""
    report = find_unapplied_transforms(gltf)
    return format_report(report) if report.findings else ""


# Kept so callers can compute bounds without importing numpy themselves.
__all__ = [
    "SPEC_EXTENSION",
    "SCHEMA_PATH",
    "spec_path_for",
    "model_path_for",
    "read_spec_file",
    "validate_spec_schema",
    "evaluate_model_against_spec",
    "verdicts_failed",
    "is_informational",
    "check_external_resources",
    "transform_report",
    "list_animations",
    "list_textures",
    "list_images",
    "list_bones",
    "list_materials",
    "get_gltf_scale",
    "np",
]
