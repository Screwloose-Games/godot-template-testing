"""Pre-export checks for a procedurally built asset.

Every check here exists because building the jeep tripped over the thing it looks
for. They run inside Blender, before the export, so a problem costs one rebuild
rather than an export, an import, a validator run and a round trip through the
Godot editor.

Three of these catch failures the repo's own validator cannot see:

* `godot_name_suffixes` is invisible to validate-model-files.py, because the glTF
  is perfectly valid -- Godot's importer is what reinterprets the name. `steering_wheel`
  silently became a VehicleWheel3D, a physics node that only works parented to a
  VehicleBody3D, and it was only found by reading the imported scene tree.
* `collision_within_visual` catches a proxy that sticks out past the art. The
  validator measures the whole file, so an oversized proxy *is* the model's
  height, and the width/height/depth checks then fail against a number no one can
  see in a render.
* `ground_contact` catches the model floating or sunk, which nothing validates at
  all but everything downstream assumes.

The rest duplicate checks the validator already runs, deliberately: finding them
here means fixing them in the build script with the scene still open.
"""

import re

import bpy
from mathutils import Vector

# Godot's ResourceImporterScene reinterprets node names ending in any of these.
# Its _teststr() accepts BOTH "-suffix" and "_suffix" (and "$suffix"), which is
# why an innocuous-looking `steering_wheel` matches the VehicleWheel3D rule. The
# same mechanism is what makes -convcolonly work, so it cannot be switched off.
GODOT_NODE_SUFFIXES = {
    "col": "StaticBody3D + trimesh collision",
    "colonly": "StaticBody3D, visual mesh discarded",
    "convcol": "StaticBody3D + convex collision",
    "convcolonly": "StaticBody3D convex, visual mesh discarded",
    "navmesh": "NavigationRegion3D",
    "vehicle": "VehicleBody3D",
    "wheel": "VehicleWheel3D",
    "rigid": "RigidBody3D",
    "occ": "OccluderInstance3D",
    "occonly": "OccluderInstance3D, visual mesh discarded",
    "noimp": "skipped entirely on import",
    "cycle": "animation loop flag",
    "loop": "animation loop flag",
}

ROTATION_EPS = 1e-6
SCALE_EPS = 1e-6
SIZE_TOLERANCE = 0.10


class Finding:
    def __init__(self, check, severity, message):
        self.check = check
        self.severity = severity      # "fail" | "warn"
        self.message = message

    def __repr__(self):
        return f"{self.severity.upper():4}  {self.check}: {self.message}"


def _meshes():
    return [o for o in bpy.data.objects if o.type == 'MESH']


def _is_proxy(obj):
    name = obj.name.lower()
    return any(name.endswith("-" + s) or name.endswith("_" + s)
               for s in ("col", "colonly", "convcol", "convcolonly"))


def _world_bounds(objects):
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in objects:
        evaluated = obj.evaluated_get(depsgraph)
        for corner in evaluated.bound_box:
            point = evaluated.matrix_world @ Vector(corner)
            for axis in range(3):
                lo[axis] = min(lo[axis], point[axis])
                hi[axis] = max(hi[axis], point[axis])
    return lo, hi


def identity_transforms(findings):
    """Every object transform must be identity in rotation and scale.

    This is the check that shapes the whole authoring approach. A static asset --
    no skins, no animations -- is inspected by gltf_transforms.py all the way down
    the mesh chain, not just at the scene roots, and any rotation over 0.5 degrees
    or scale off 1.0 is a hard FAIL. Building geometry pre-transformed in bmesh
    keeps this true by construction; this check proves it stayed true.
    """
    for obj in bpy.data.objects:
        if obj.type not in {'MESH', 'EMPTY'}:
            continue
        rotation = max(abs(a) for a in obj.rotation_euler)
        scale = max(abs(s - 1.0) for s in obj.scale)
        if rotation > ROTATION_EPS:
            findings.append(Finding(
                "identity_transforms", "fail",
                f"{obj.name} carries a rotation {list(obj.rotation_euler)}. "
                "Author the rotation into the mesh data instead; pivots must be "
                "translation-only."))
        if scale > SCALE_EPS:
            findings.append(Finding(
                "identity_transforms", "fail",
                f"{obj.name} carries a scale {list(obj.scale)}."))


def no_child_meshes(findings):
    """pipeline.yaml rule no_child_meshes -- a mesh under a mesh breaks Godot's
    collision-shape generation. Parent through Empties instead."""
    for obj in _meshes():
        if obj.parent is not None and obj.parent.type == 'MESH':
            findings.append(Finding(
                "no_child_meshes", "fail",
                f"{obj.name} is parented to mesh {obj.parent.name}."))


def godot_name_suffixes(findings, intended=("convcolonly",)):
    """Flag node names Godot will reinterpret that were not meant to be suffixes."""
    for obj in bpy.data.objects:
        if obj.type not in {'MESH', 'EMPTY'}:
            continue
        tail = re.split(r"[-_$]", obj.name.lower())[-1]
        if tail in GODOT_NODE_SUFFIXES and tail not in intended:
            findings.append(Finding(
                "godot_name_suffixes", "fail",
                f"{obj.name} ends in '{tail}', which Godot imports as "
                f"{GODOT_NODE_SUFFIXES[tail]}. Rename the object."))


def collision_within_visual(findings, slack=0.01):
    """Collision proxies must not push the model's bounding box past the art.

    The slack is a centimetre because a proxy hugging a *curved* surface routinely
    pokes a few millimetres past the faceted mesh approximating it -- the wheel
    hulls here sit 3 mm below the tyres, which is right: collision is what the
    vehicle rests on. The failure this exists to catch was a turret proxy standing
    70 mm above the gun shield, which silently became the model's measured height
    and would have failed the spec's height check against a number invisible in
    every render. Millimetres are faceting; centimetres are a mistake.
    """
    visual = [o for o in _meshes() if not _is_proxy(o)]
    proxies = [o for o in _meshes() if _is_proxy(o)]
    if not visual or not proxies:
        return
    vlo, vhi = _world_bounds(visual)
    plo, phi = _world_bounds(proxies)
    for axis, name in enumerate("XYZ"):
        if plo[axis] < vlo[axis] - slack:
            findings.append(Finding(
                "collision_within_visual", "fail",
                f"collision extends {vlo[axis] - plo[axis]:.3f} m below the art on "
                f"{name}. The validator measures the whole file, so this becomes "
                "the model's declared size."))
        if phi[axis] > vhi[axis] + slack:
            findings.append(Finding(
                "collision_within_visual", "fail",
                f"collision extends {phi[axis] - vhi[axis]:.3f} m past the art on "
                f"{name}. The validator measures the whole file, so this becomes "
                "the model's declared size."))


def ground_contact(findings, tolerance=0.005):
    """The model should rest on Z=0 with its pivot at the world origin."""
    lo, _ = _world_bounds(_meshes())
    if abs(lo[2]) > tolerance:
        findings.append(Finding(
            "ground_contact", "fail",
            f"lowest point is Z={lo[2]:+.4f}, not 0. The vehicle will float or "
            "sink when dropped into a level."))


def dimensions(findings, target_w_h_d):
    """Bounds against the spec's declared size, in glTF axes.

    Blender (x, y, z) exports to glTF (x, z, -y), so width/height/depth read off
    Blender X / Z / Y. Getting that mapping wrong is an easy way to declare a spec
    that fails for reasons that look like modelling errors.
    """
    lo, hi = _world_bounds(_meshes())
    size = [hi[i] - lo[i] for i in range(3)]
    measured = (size[0], size[2], size[1])
    for value, target, name in zip(measured, target_w_h_d, ("width", "height", "depth")):
        if target and abs(value - target) / target > SIZE_TOLERANCE:
            findings.append(Finding(
                "dimensions", "fail",
                f"{name} {value:.3f} m is outside 10% of the declared {target} m. "
                "Adjust the geometry, not the spec."))
    return measured


def triangle_budget(findings, budget, per_object_budgets=None):
    """Triangles are counted per *instance* by gltf_measure, so four wheels cost
    four times. Collision proxies count too."""
    counts = {}
    for obj in _meshes():
        counts[obj.name] = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    total = sum(counts.values())
    if budget and total > budget:
        findings.append(Finding(
            "triangle_budget", "fail",
            f"{total} triangles over the {budget} budget."))
    for name, limit in (per_object_budgets or {}).items():
        if counts.get(name, 0) > limit:
            findings.append(Finding(
                "triangle_budget", "warn",
                f"{name} is {counts[name]} against its {limit} line."))
    return total, counts


def uvs_in_unit_square(findings):
    for obj in _meshes():
        if _is_proxy(obj):
            continue
        layer = obj.data.uv_layers.active
        if layer is None:
            findings.append(Finding("uvs", "fail", f"{obj.name} has no UV layer."))
            continue
        for datum in layer.data:
            u, v = datum.uv
            if not (-1e-4 <= u <= 1 + 1e-4 and -1e-4 <= v <= 1 + 1e-4):
                findings.append(Finding(
                    "uvs", "fail",
                    f"{obj.name} has UVs outside 0-1; they would bake to the "
                    "wrong atlas tile."))
                break


def run(target_w_h_d=None, budget=None, per_object_budgets=None,
        intended_suffixes=("convcolonly",), check_uvs=True):
    """Every check. Returns (findings, report dict)."""
    findings = []
    identity_transforms(findings)
    no_child_meshes(findings)
    godot_name_suffixes(findings, intended_suffixes)
    collision_within_visual(findings)
    ground_contact(findings)
    measured = dimensions(findings, target_w_h_d) if target_w_h_d else None
    total, counts = triangle_budget(findings, budget, per_object_budgets)
    if check_uvs:
        uvs_in_unit_square(findings)

    report = {
        "measured_w_h_d": [round(v, 4) for v in measured] if measured else None,
        "triangles": total,
        "per_object": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        "failures": [str(f) for f in findings if f.severity == "fail"],
        "warnings": [str(f) for f in findings if f.severity == "warn"],
    }
    report["passed"] = not report["failures"]
    return findings, report
