"""Measure a glTF's size and triangle count without loading its geometry.

The validator used to get both numbers from trimesh, which meant they were only
available inside a Docker image carrying trimesh, pyrender and an X server. That
is why a model's spec could not be checked from a laptop or a git hook. Both
numbers are recoverable from the glTF JSON alone, so this module recovers them
with numpy and nothing else.

**Bounds.** glTF 2.0 requires `min` and `max` on every POSITION accessor
(section 3.7.2.1: the accessor "MUST have `min` and `max` defined"), and the
Khronos validator treats their absence as an error, so every conforming file
carries a ready-made local AABB per primitive. This walks the scene graph,
composes each node's world matrix, transforms the eight corners of each
primitive's AABB, and unions the results.

That is an AABB of transformed AABBs, so where a world matrix contains a rotation
that is not a signed axis permutation, the result is a *superset* of the exact
bounds trimesh would compute -- up to sqrt(3) per axis for a 45 degree rotation.
Two things make that acceptable rather than merely tolerable:

* `unapplied_transforms` in model_spec already **fails** any model whose node
  chain carries a rotation or a non-unit scale, unless its spec explicitly opts
  out. On every model that passes the other blocking checks the world matrices
  are pure translations, and the two computations are identical -- not
  approximately equal, identical.
* For a 90, 180 or 270 degree rotation about a cardinal axis the AABB maps onto
  itself exactly, so even the opted-out case is usually exact. The test suite
  pins this: test-fixtures/unapplied_rotation_90z.gltf is the example cube with
  its geometry pre-rotated and a compensating node rotation, and its world bounds
  come out identical to the unrotated original.

So the overestimate can only appear on a model that is already failing, or one
that deliberately asked for a rotated node -- and the size checks carry a +/-10%
tolerance on top of that.

Two limits worth knowing and not worth fixing here: a skinned mesh's POSITION
bounds describe the bind pose (trimesh has the same limitation, so the two still
agree), and morph targets shift the real bounds (neither path accounts for them).

**Triangles.** Counted per *instance*, not per unique mesh. trimesh's
`Scene.geometry` is keyed by mesh, so a crate referenced by twenty nodes counted
once; but a kitbash of twenty 500-triangle crates ships ten thousand triangles,
and that is the number a budget is about. Both figures are reported so the
change is legible.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

# glTF 2.0 primitive.mode. 4 is the default when the key is absent.
MODE_POINTS = 0
MODE_TRIANGLES = 4
MODE_TRIANGLE_STRIP = 5
MODE_TRIANGLE_FAN = 6
DEFAULT_MODE = MODE_TRIANGLES


@dataclass
class Measurement:
    """What could be measured, and what got in the way."""

    triangles: int = 0
    unique_triangles: int = 0
    instances: int = 0
    unique_meshes: int = 0
    size: np.ndarray | None = None
    minimum: np.ndarray | None = None
    maximum: np.ndarray | None = None
    problems: list[str] = field(default_factory=list)

    @property
    def measured(self) -> bool:
        return self.size is not None


def _trs_matrix(node: dict) -> np.ndarray:
    """A node's local transform. glTF nodes carry `matrix` XOR a TRS triple."""
    matrix = node.get("matrix")
    if matrix is not None and len(matrix) == 16:
        # glTF matrices are column-major; numpy is row-major.
        return np.array(matrix, dtype=np.float64).reshape(4, 4).T

    result = np.eye(4)

    scale = node.get("scale")
    if scale is not None and len(scale) == 3:
        result = np.diag([float(scale[0]), float(scale[1]), float(scale[2]), 1.0])

    rotation = node.get("rotation")
    if rotation is not None and len(rotation) == 4:
        x, y, z, w = (float(component) for component in rotation)
        norm = (x * x + y * y + z * z + w * w) ** 0.5
        if norm:
            x, y, z, w = x / norm, y / norm, z / norm, w / norm
            rotation_matrix = np.array(
                [
                    [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0.0],
                    [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0.0],
                    [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0.0],
                    [0.0, 0.0, 0.0, 1.0],
                ]
            )
            result = rotation_matrix @ result

    translation = node.get("translation")
    if translation is not None and len(translation) == 3:
        translation_matrix = np.eye(4)
        translation_matrix[:3, 3] = [float(value) for value in translation]
        result = translation_matrix @ result

    return result


def _scene_roots(document: dict) -> list[int]:
    scenes = document.get("scenes") or []
    if not scenes:
        return []
    index = document.get("scene", 0)
    if not isinstance(index, int) or index >= len(scenes):
        index = 0
    return list(scenes[index].get("nodes") or [])


def node_world_matrices(document: dict) -> dict[int, np.ndarray]:
    """World matrix for every node reachable from the active scene.

    Nodes unreachable from the scene are omitted, matching trimesh, which only
    ever built geometry for the scene graph it was given.
    """
    nodes = document.get("nodes") or []
    matrices: dict[int, np.ndarray] = {}

    def walk(index: int, parent: np.ndarray, seen: frozenset) -> None:
        # A cyclic `children` graph is invalid glTF, but a validator that hangs
        # on a malformed file is worse than one that ignores the cycle.
        if index in seen or index < 0 or index >= len(nodes):
            return
        node = nodes[index]
        world = parent @ _trs_matrix(node)
        matrices[index] = world
        for child in node.get("children") or []:
            walk(child, world, seen | {index})

    for root in _scene_roots(document):
        walk(root, np.eye(4), frozenset())
    return matrices


def primitive_triangle_count(document: dict, primitive: dict) -> int:
    """Triangles in one primitive, from the accessor counts alone."""
    accessors = document.get("accessors") or []
    mode = primitive.get("mode", DEFAULT_MODE)

    if "indices" in primitive and primitive["indices"] is not None:
        index = primitive["indices"]
    else:
        index = (primitive.get("attributes") or {}).get("POSITION")
    if index is None or index >= len(accessors):
        return 0

    count = accessors[index].get("count") or 0

    if mode == MODE_TRIANGLES:
        return count // 3
    if mode in (MODE_TRIANGLE_STRIP, MODE_TRIANGLE_FAN):
        # Every vertex after the first two closes another triangle.
        return max(0, count - 2)
    # POINTS, LINES, LINE_LOOP and LINE_STRIP contribute no surface area.
    return 0


def mesh_triangle_count(document: dict, mesh_index: int) -> int:
    meshes = document.get("meshes") or []
    if mesh_index is None or mesh_index >= len(meshes):
        return 0
    return sum(
        primitive_triangle_count(document, primitive)
        for primitive in meshes[mesh_index].get("primitives") or []
    )


def count_triangles(document: dict) -> tuple[int, int, int, int]:
    """(instanced total, unique total, instance count, unique mesh count)."""
    nodes = document.get("nodes") or []
    per_mesh: dict[int, int] = {}
    instanced = 0
    instances = 0

    for index in sorted(node_world_matrices(document)):
        mesh_index = nodes[index].get("mesh")
        if mesh_index is None:
            continue
        if mesh_index not in per_mesh:
            per_mesh[mesh_index] = mesh_triangle_count(document, mesh_index)
        instanced += per_mesh[mesh_index]
        instances += 1

    return instanced, sum(per_mesh.values()), instances, len(per_mesh)


def _corners(minimum, maximum) -> np.ndarray:
    """The eight corners of an axis-aligned box, as rows."""
    low = np.array(minimum[:3], dtype=np.float64)
    high = np.array(maximum[:3], dtype=np.float64)
    return np.array(
        [
            [low[0] if bit & 1 else high[0], low[1] if bit & 2 else high[1], low[2] if bit & 4 else high[2]]
            for bit in range(8)
        ]
    )


def measure(document: dict) -> Measurement:
    """Everything the spec checks need, in one pass over the scene graph."""
    result = Measurement()
    nodes = document.get("nodes") or []
    meshes = document.get("meshes") or []
    accessors = document.get("accessors") or []

    instanced, unique, instances, unique_meshes = count_triangles(document)
    result.triangles = instanced
    result.unique_triangles = unique
    result.instances = instances
    result.unique_meshes = unique_meshes

    points: list[np.ndarray] = []
    for index, world in sorted(node_world_matrices(document).items()):
        mesh_index = nodes[index].get("mesh")
        if mesh_index is None or mesh_index >= len(meshes):
            continue
        for order, primitive in enumerate(meshes[mesh_index].get("primitives") or []):
            position = (primitive.get("attributes") or {}).get("POSITION")
            if position is None or position >= len(accessors):
                result.problems.append(
                    f"mesh {mesh_index} primitive {order} has no POSITION accessor"
                )
                continue
            accessor = accessors[position]
            minimum, maximum = accessor.get("min"), accessor.get("max")
            if not minimum or not maximum or len(minimum) < 3 or len(maximum) < 3:
                # glTF 2.0 makes this a MUST, so a file that omits it is
                # malformed. Say so rather than quietly reporting no size.
                result.problems.append(
                    f"accessor {position} (POSITION of mesh {mesh_index} primitive {order}) "
                    "declares no min/max; glTF 2.0 requires them on POSITION accessors, "
                    "so the model's dimensions cannot be measured. Re-export from the "
                    "modelling program -- every standard exporter writes them."
                )
                continue
            corners = _corners(minimum, maximum)
            homogeneous = np.hstack([corners, np.ones((8, 1))])
            points.append((world @ homogeneous.T).T[:, :3])

    if not points:
        if not result.problems:
            result.problems.append("no mesh geometry reachable from the scene")
        return result

    stacked = np.vstack(points)
    if not np.all(np.isfinite(stacked)):
        result.problems.append("node transforms produced non-finite bounds")
        return result

    result.minimum = stacked.min(axis=0)
    result.maximum = stacked.max(axis=0)
    result.size = result.maximum - result.minimum
    return result


def scene_bounds_size(document: dict) -> np.ndarray | None:
    """The [x, y, z] extents of the model, or None if they cannot be measured."""
    return measure(document).size


def node_bounds(document: dict) -> dict[int, tuple[np.ndarray, np.ndarray]]:
    """World-space AABB per mesh-bearing node, as {node index: (min, max)}.

    `measure` unions all of these into one box, which answers "how big is the
    model". Some questions need the boxes kept apart -- notably whether the
    collision proxies stick out past the art they stand in for, which `measure`
    cannot see because it has already merged the two together.

    Nodes whose bounds cannot be computed are omitted rather than reported;
    `measure` already records those problems and is always run alongside this.
    """
    nodes = document.get("nodes") or []
    meshes = document.get("meshes") or []
    accessors = document.get("accessors") or []
    result: dict[int, tuple[np.ndarray, np.ndarray]] = {}

    for index, world in sorted(node_world_matrices(document).items()):
        mesh_index = nodes[index].get("mesh")
        if mesh_index is None or mesh_index >= len(meshes):
            continue
        points: list[np.ndarray] = []
        for primitive in meshes[mesh_index].get("primitives") or []:
            position = (primitive.get("attributes") or {}).get("POSITION")
            if position is None or position >= len(accessors):
                continue
            accessor = accessors[position]
            minimum, maximum = accessor.get("min"), accessor.get("max")
            if not minimum or not maximum or len(minimum) < 3 or len(maximum) < 3:
                continue
            corners = _corners(minimum, maximum)
            homogeneous = np.hstack([corners, np.ones((8, 1))])
            points.append((world @ homogeneous.T).T[:, :3])
        if not points:
            continue
        stacked = np.vstack(points)
        if not np.all(np.isfinite(stacked)):
            continue
        result[index] = (stacked.min(axis=0), stacked.max(axis=0))

    return result
