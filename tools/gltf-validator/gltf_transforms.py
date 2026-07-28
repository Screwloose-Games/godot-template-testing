"""Detect transforms that were never applied in the modelling program.

A node in a correct static-prop export carries no rotation and no scale: the
mesh data is authored in its final frame and the node it hangs on is identity.
When an artist rotates or scales an object in Blender and exports without
`Object > Apply`, that transform rides along on the glTF node instead, and the
mesh data underneath is still in the old frame.

**Why this matters enough to fail a build.** Everything downstream measures the
node graph, not the triangles -- `gltf_axes` walks exactly this chain to report
facing and up. An unapplied rotation is therefore indistinguishable from a
botched axis conversion: the asset reports whatever the leftover rotation says,
which is neither where the geometry points nor what the artist intended. The
`example_cubes_facing` asset reported facing `+X` for precisely this reason,
while its geometry pointed down `-Z`. Until the transform is applied, no facing
or up number from this toolchain means anything.

That indistinguishability cuts both ways, so this module does not override
`gltf_axes` -- it reports alongside it. A rotation of 90 degrees about X is far
more likely a missed Y-up conversion than an unapplied object rotation, and the
remedy says so; sending an artist to Ctrl+A for a problem that lives in the
export dialog wastes their afternoon.

Scale is failed for the same reason plus its own: non-uniform scale skews
normals and collision shapes, and negative scale mirrors the mesh.

Translation is reported but does *not* fail. A node offset is how glTF
legitimately places parts within a multi-object asset, and Blender's object
origin is a deliberate authoring choice (a door pivots on its hinge, not its
centre). It is worth surfacing and not worth blocking.

**What is exempt, and why.** Skin joints and animation targets are skipped
throughout -- a bone with a rotation is a bone doing its job. That is not enough
on its own: the wolf in examples/ has no skin at all, just 59 mesh nodes posed
by node transforms five and six levels deep, and checking those produced a
finding per body part while the actual root was spotless. So in any asset
carrying skins or animations, only the scene roots are judged; below the root,
a transform is assumed to be the rig. Static assets are checked all the way
down, which is where a single-object export -- the case this was written for --
lives anyway.

Kept to numpy and the standard library so it imports without the validator's
Docker stack, same as `gltf_axes`. Anything exposing `.nodes`, `.scenes` and
`.scene` works.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

# Float noise from an exporter's quaternion round-trip lands well under 0.01
# degrees; a transform an artist actually left on is degrees at minimum and
# usually a multiple of 15. Half a degree sits in the empty space between.
ROTATION_TOLERANCE_DEGREES = 0.5
SCALE_TOLERANCE = 1e-3
TRANSLATION_TOLERANCE = 1e-4

# Naming a rotation axis is a convenience for the artist, not a measurement.
# Anything further off-cardinal than this gets reported as raw components.
AXIS_NAMING_TOLERANCE = 0.99

CARDINALS = {
    "+X": np.array([1.0, 0.0, 0.0]),
    "-X": np.array([-1.0, 0.0, 0.0]),
    "+Y": np.array([0.0, 1.0, 0.0]),
    "-Y": np.array([0.0, -1.0, 0.0]),
    "+Z": np.array([0.0, 0.0, 1.0]),
    "-Z": np.array([0.0, 0.0, -1.0]),
}

APPLY_ROTATION_REMEDY = (
    "In Blender: select the object, then Object > Apply > Rotation "
    "(Ctrl+A, then 'Rotation') and export again. Applying bakes the rotation "
    "into the mesh data and leaves the node at identity."
)
APPLY_SCALE_REMEDY = (
    "In Blender: select the object, then Object > Apply > Scale "
    "(Ctrl+A, then 'Scale') and export again. Check the object is not mirrored "
    "by a negative scale first -- applying that flips the normals."
)
APPLY_LOCATION_REMEDY = (
    "If the origin belongs at the world origin, use Object > Apply > Location "
    "in Blender. If the offset is a deliberate pivot (a hinge, a mount point), "
    "leave it -- this is a note, not a failure."
)
YUP_CONVERSION_REMEDY = (
    "Check the glTF export dialog's '+Y Up' option first -- a 90 deg X rotation "
    "is what an export without it leaves behind, and re-exporting with it ticked "
    "is the fix. If '+Y Up' was already on, the object itself carries the "
    "rotation: Object > Apply > Rotation (Ctrl+A, then 'Rotation') and export again."
)


def looks_like_missed_yup_conversion(angle: float, axis: np.ndarray) -> bool:
    """Whether a rotation matches the signature of an export left in Z-up.

    Nothing in the node graph distinguishes "the artist left a rotation on the
    object" from "the exporter never converted Z-up to Y-up" -- both are just a
    rotation on a node. A rotation of 90 degrees about X is overwhelmingly the
    second, so the message says so rather than sending the artist to Ctrl+A for
    a problem that lives in the export dialog.
    """
    if abs(angle - 90.0) > 1.0:
        return False
    length = float(np.linalg.norm(axis))
    if length == 0:
        return False
    return abs(float(np.dot(axis / length, CARDINALS["+X"]))) >= AXIS_NAMING_TOLERANCE


@dataclass
class Finding:
    """One unapplied transform on one node."""

    node_index: int
    node_name: str | None
    kind: str  # "rotation" | "scale" | "translation"
    severity: str  # "fail" | "warn"
    detail: str
    remedy: str

    @property
    def label(self) -> str:
        name = f' "{self.node_name}"' if self.node_name else ""
        return f"node {self.node_index}{name}"

    def __str__(self) -> str:
        return f"{self.severity.upper():4}  {self.label}: {self.detail}"


@dataclass
class TransformReport:
    findings: list[Finding] = field(default_factory=list)

    @property
    def failures(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "fail"]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "warn"]

    def __bool__(self) -> bool:
        """True when something was found at all, of either severity."""
        return bool(self.findings)

    @property
    def ok(self) -> bool:
        """True when nothing blocking was found. Warnings do not block."""
        return not self.failures


def _quaternion_angle_axis(rotation) -> tuple[float, np.ndarray]:
    """Angle in degrees and unit axis for a glTF (x, y, z, w) quaternion."""
    x, y, z, w = (float(c) for c in rotation)
    norm = (x * x + y * y + z * z + w * w) ** 0.5
    if norm == 0:
        return 0.0, np.array([0.0, 0.0, 0.0])
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    vector = np.array([x, y, z])
    length = float(np.linalg.norm(vector))
    # atan2 stays accurate near 0 and 180 degrees where acos(w) loses precision.
    angle = float(np.degrees(2 * np.arctan2(length, abs(w))))
    if length == 0:
        return 0.0, np.array([0.0, 0.0, 0.0])
    axis = vector / length
    # A negative w is the same rotation written the other way round; flip so the
    # reported angle is the short way and the axis points consistently.
    if w < 0:
        axis = -axis
    return angle, axis


def _matrix_angle_axis(matrix: np.ndarray) -> tuple[float, np.ndarray]:
    """Angle in degrees and unit axis for a 3x3 rotation matrix."""
    trace = float(np.trace(matrix))
    cos = max(-1.0, min(1.0, (trace - 1.0) / 2.0))
    angle = float(np.degrees(np.arccos(cos)))
    axis = np.array(
        [
            matrix[2, 1] - matrix[1, 2],
            matrix[0, 2] - matrix[2, 0],
            matrix[1, 0] - matrix[0, 1],
        ]
    )
    length = float(np.linalg.norm(axis))
    if length < 1e-9:
        # 0 or 180 degrees. At 180 the axis is the eigenvector for +1; the
        # largest diagonal entry picks the numerically safest column to build it
        # from. At 0 there is no axis to name.
        if angle < 90:
            return 0.0, np.array([0.0, 0.0, 0.0])
        candidate = matrix + np.eye(3)
        column = candidate[:, int(np.argmax(np.diag(candidate)))]
        norm = float(np.linalg.norm(column))
        return angle, column / norm if norm > 1e-9 else np.array([0.0, 0.0, 0.0])
    return angle, axis / length


def name_axis(axis: np.ndarray) -> str:
    """Name a cardinal axis, or fall back to components when it is off-axis."""
    length = float(np.linalg.norm(axis))
    if length == 0 or not np.isfinite(length):
        return "an undetermined axis"
    unit = axis / length
    for name, cardinal in CARDINALS.items():
        if float(np.dot(unit, cardinal)) >= AXIS_NAMING_TOLERANCE:
            return name
    return f"({unit[0]:+.3f}, {unit[1]:+.3f}, {unit[2]:+.3f})"


def gltf_axis_to_blender(axis: np.ndarray) -> np.ndarray:
    """Re-express a glTF-space direction in Blender's Z-up frame.

    The exporter maps Blender (x, y, z) to glTF (x, z, -y); this is the inverse.
    Rotation axes carry through conjugation unchanged, so a rotation about glTF
    +Y is the same rotation about Blender +Z -- which is the axis the artist
    actually typed into the N-panel.
    """
    x, y, z = (float(c) for c in axis)
    return np.array([x, -z, y])


def decompose(node) -> tuple[np.ndarray, np.ndarray, np.ndarray, tuple[float, np.ndarray]]:
    """Split a node into translation, rotation matrix, scale and angle/axis.

    glTF nodes carry either a matrix or TRS components, never both.
    """
    matrix = getattr(node, "matrix", None)
    if matrix is not None and len(matrix) == 16:
        values = [float(v) for v in matrix]
        columns = [np.array(values[0:3]), np.array(values[4:7]), np.array(values[8:11])]
        translation = np.array(values[12:15])
        scale = np.array([float(np.linalg.norm(c)) for c in columns])
        basis = [c / s if s > 1e-12 else np.array([0.0, 0.0, 0.0]) for c, s in zip(columns, scale)]
        rotation = np.column_stack(basis)
        if not np.all(np.isfinite(rotation)):
            rotation = np.eye(3)
        # A left-handed basis means a mirroring scale. Pull the flip out of the
        # rotation and back into the scale so the angle is a real rotation.
        if float(np.linalg.det(rotation)) < 0:
            rotation = rotation.copy()
            rotation[:, 0] = -rotation[:, 0]
            scale = scale.copy()
            scale[0] = -scale[0]
        return translation, rotation, scale, _matrix_angle_axis(rotation)

    translation = np.array([float(c) for c in (getattr(node, "translation", None) or [0, 0, 0])])
    scale = np.array([float(c) for c in (getattr(node, "scale", None) or [1, 1, 1])])
    quaternion = getattr(node, "rotation", None)
    if quaternion is not None and len(quaternion) == 4:
        angle, axis = _quaternion_angle_axis(quaternion)
    else:
        angle, axis = 0.0, np.array([0.0, 0.0, 0.0])
    return translation, np.eye(3), scale, (angle, axis)


def _exempt_nodes(gltf) -> set[int]:
    """Nodes whose transforms are legitimate: skin joints and animation targets."""
    exempt: set[int] = set()
    for skin in getattr(gltf, "skins", None) or []:
        for joint in getattr(skin, "joints", None) or []:
            exempt.add(int(joint))
        skeleton = getattr(skin, "skeleton", None)
        if skeleton is not None:
            exempt.add(int(skeleton))
    for animation in getattr(gltf, "animations", None) or []:
        for channel in getattr(animation, "channels", None) or []:
            target = getattr(channel, "target", None)
            node = getattr(target, "node", None) if target is not None else None
            if node is not None:
                exempt.add(int(node))
    return exempt


def is_static_asset(gltf) -> bool:
    """Whether nothing in this asset drives node transforms as a matter of course.

    A rigged or animated asset uses node transforms as its rig: the wolf in
    examples/ is 59 separate mesh nodes posed by rotations five and six levels
    deep, and baking those into the mesh data would destroy the model. Only in a
    static asset is a transform partway down the tree necessarily a mistake.
    """
    return not (getattr(gltf, "skins", None) or getattr(gltf, "animations", None))


def _nodes_to_inspect(gltf) -> dict[int, int]:
    """Nodes from a scene root down to a mesh-bearing node, mapped to their depth.

    These are the nodes whose transforms compose into what the asset actually
    looks like -- the same chain `gltf_axes` measures. Nodes off to the side of
    a mesh cannot affect it and are left alone. Depth comes back with them
    because how much of the chain is worth judging depends on the asset: see
    `is_static_asset`. A node reachable by more than one path keeps its
    shallowest depth.
    """
    nodes = getattr(gltf, "nodes", None) or []
    if not nodes:
        return {}

    scenes = getattr(gltf, "scenes", None) or []
    index = getattr(gltf, "scene", None)
    if index is None or not isinstance(index, int) or index >= len(scenes):
        index = 0
    roots = list(getattr(scenes[index], "nodes", None) or []) if scenes else []
    if not roots:
        roots = list(range(len(nodes)))

    relevant: dict[int, int] = {}

    def walk(node_index: int, path: list[int], seen: frozenset[int]) -> bool:
        """Depth-first; keep every path that reaches a mesh. Returns whether one did."""
        if node_index in seen or node_index >= len(nodes) or node_index < 0:
            return False
        node = nodes[node_index]
        path = path + [node_index]
        seen = seen | {node_index}
        reached = getattr(node, "mesh", None) is not None
        for child in getattr(node, "children", None) or []:
            reached = walk(int(child), path, seen) or reached
        if reached:
            for depth, index in enumerate(path):
                if index not in relevant or depth < relevant[index]:
                    relevant[index] = depth
        return reached

    for root in roots:
        walk(int(root), [], frozenset())
    return relevant


def find_unapplied_transforms(gltf) -> TransformReport:
    """Report rotations, scales and offsets left unapplied on a glTF's nodes."""
    report = TransformReport()
    nodes = getattr(gltf, "nodes", None) or []
    exempt = _exempt_nodes(gltf)
    static = is_static_asset(gltf)

    for index, depth in sorted(_nodes_to_inspect(gltf).items()):
        if index in exempt:
            continue
        # In a rigged or animated asset only the scene roots are judged. Below
        # the root, node transforms are the rig doing its job -- posing parts,
        # holding a rest pose -- and flagging them buries the one finding that
        # matters under one per bone. A transform on the root is still worth
        # catching there: no rig needs the whole asset rotated.
        if depth > 0 and not static:
            continue
        node = nodes[index]
        name = getattr(node, "name", None)
        translation, _, scale, (angle, axis) = decompose(node)

        if angle > ROTATION_TOLERANCE_DEGREES:
            gltf_axis = name_axis(axis)
            blender_axis = name_axis(gltf_axis_to_blender(axis))
            detail = (
                f"leftover rotation - {angle:.1f} deg about glTF {gltf_axis} "
                f"(the same as {angle:.1f} deg about {blender_axis} in Blender). "
                "The mesh data is authored in a different frame from the node it "
                "hangs on, so facing and up are measured from this rotation "
                "rather than from the geometry."
            )
            remedy = APPLY_ROTATION_REMEDY
            if looks_like_missed_yup_conversion(angle, axis):
                detail += (
                    " NOTE: 90 deg about X is also exactly what an export that skipped "
                    "glTF's Y-up conversion produces, and that is the more likely cause."
                )
                remedy = YUP_CONVERSION_REMEDY
            report.findings.append(
                Finding(
                    node_index=index,
                    node_name=name,
                    kind="rotation",
                    severity="fail",
                    detail=detail,
                    remedy=remedy,
                )
            )

        if np.any(np.abs(scale - 1.0) > SCALE_TOLERANCE):
            components = ", ".join(f"{c:.4g}" for c in scale)
            if np.any(scale < 0):
                kind_note = "negative scale mirrors the mesh and flips its normals"
            elif float(np.max(np.abs(scale - scale[0]))) > SCALE_TOLERANCE:
                kind_note = "non-uniform scale skews normals and collision shapes"
            else:
                kind_note = "the asset is not at the size its geometry claims"
            report.findings.append(
                Finding(
                    node_index=index,
                    node_name=name,
                    kind="scale",
                    severity="fail",
                    detail=f"unapplied scale - ({components}); {kind_note}.",
                    remedy=APPLY_SCALE_REMEDY,
                )
            )

        if np.any(np.abs(translation) > TRANSLATION_TOLERANCE):
            components = ", ".join(f"{c:.4g}" for c in translation)
            report.findings.append(
                Finding(
                    node_index=index,
                    node_name=name,
                    kind="translation",
                    severity="warn",
                    detail=(
                        f"node offset from the origin - ({components}). Legitimate for a "
                        "deliberate pivot or a part within a larger asset; a mistake if "
                        "the object was simply never moved back to the origin."
                    ),
                    remedy=APPLY_LOCATION_REMEDY,
                )
            )

    return report


def format_report(report: TransformReport, indent: str = "  ") -> str:
    """Human-readable findings with the fix attached to each one."""
    if not report.findings:
        return f"{indent}No unapplied transforms. Every node on the mesh chain is identity."
    lines = []
    for finding in report.findings:
        lines.append(f"{indent}{finding}")
        lines.append(f"{indent}      Fix: {finding.remedy}")
    return "\n".join(lines)
