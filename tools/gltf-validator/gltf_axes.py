"""Measure which way a glTF model faces and which way is up.

The glTF 2.0 specification fixes the convention: +Y is up, and *the front of a
glTF asset faces +Z*. A correctly exported model therefore needs no root
rotation at all -- its authored forward already points down +Z.

That is what this module measures. It walks from a scene root down to the first
node carrying a mesh, composes the rotations along the way, and reports which
world axis the glTF forward (+Z) and up (+Y) vectors end up pointing at.

**What this does and does not catch.** You cannot recover "which way does this
character look" from triangles -- nothing in a glTF marks a face. What you *can*
detect is the failure this project actually hits: an export that did not apply
the axis conversion, or applied the wrong one, which leaves a tell-tale rotation
(usually +/-90 degrees about X) on the node chain. A model whose geometry was
authored backwards in Blender will still pass here; that stays a review job.

Kept free of trimesh, pyrender and pygltflib so it can be imported and tested
without the validator's heavy dependency stack. Anything exposing `.nodes`,
`.scenes` and `.scene` works -- `pygltflib.GLTF2` does, and so does a stub.
"""

from __future__ import annotations

import numpy as np

# glTF 2.0, section 3.5 "Coordinate System and Units".
GLTF_FORWARD = np.array([0.0, 0.0, 1.0])
GLTF_UP = np.array([0.0, 1.0, 0.0])

AXES = {
    "+X": np.array([1.0, 0.0, 0.0]),
    "-X": np.array([-1.0, 0.0, 0.0]),
    "+Y": np.array([0.0, 1.0, 0.0]),
    "-Y": np.array([0.0, -1.0, 0.0]),
    "+Z": np.array([0.0, 0.0, 1.0]),
    "-Z": np.array([0.0, 0.0, -1.0]),
}

# How close to a cardinal axis a result must land to be named. cos(~8 degrees).
AXIS_TOLERANCE = 0.99


def quaternion_to_matrix(rotation) -> np.ndarray:
    """glTF stores rotations as the quaternion (x, y, z, w)."""
    x, y, z, w = (float(component) for component in rotation)
    norm = (x * x + y * y + z * z + w * w) ** 0.5
    if norm == 0:
        return np.eye(3)
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    return np.array(
        [
            [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
            [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
            [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
        ]
    )


def matrix_to_rotation(matrix) -> np.ndarray:
    """Pull the rotation out of a glTF node matrix, discarding scale.

    glTF node matrices are column-major, 16 floats.
    """
    values = [float(value) for value in matrix]
    columns = [
        np.array(values[0:3]),
        np.array(values[4:7]),
        np.array(values[8:11]),
    ]
    normalised = []
    for column in columns:
        length = np.linalg.norm(column)
        # A zero-scale axis carries no orientation; fall back to identity rather
        # than dividing by zero and producing NaNs that silently poison the dot
        # products downstream.
        normalised.append(column / length if length else np.array([0.0, 0.0, 0.0]))
    rotation = np.column_stack(normalised)
    if not np.all(np.isfinite(rotation)):
        return np.eye(3)
    return rotation


def node_rotation(node) -> np.ndarray:
    """The rotation a single node contributes. glTF nodes carry matrix XOR TRS."""
    matrix = getattr(node, "matrix", None)
    if matrix is not None and len(matrix) == 16:
        return matrix_to_rotation(matrix)
    rotation = getattr(node, "rotation", None)
    if rotation is not None and len(rotation) == 4:
        return quaternion_to_matrix(rotation)
    return np.eye(3)


def _scene_roots(gltf) -> list[int]:
    scenes = getattr(gltf, "scenes", None) or []
    if not scenes:
        return []
    index = getattr(gltf, "scene", None)
    if index is None or index >= len(scenes):
        index = 0
    return list(getattr(scenes[index], "nodes", None) or [])


def _chain_to_first_mesh(gltf, root_index: int) -> list[int] | None:
    """Depth-first path from a root down to the first node holding a mesh."""
    nodes = getattr(gltf, "nodes", None) or []

    def walk(index: int, path: list[int], seen: set[int]) -> list[int] | None:
        if index in seen or index >= len(nodes):
            return None
        seen.add(index)
        node = nodes[index]
        path = path + [index]
        if getattr(node, "mesh", None) is not None:
            return path
        for child in getattr(node, "children", None) or []:
            found = walk(child, path, seen)
            if found:
                return found
        return None

    return walk(root_index, [], set())


def orientation_matrix(gltf) -> np.ndarray | None:
    """Composed rotation from a scene root to the first mesh it contains.

    Returns None when the asset has no scene, no nodes, no mesh, or when its
    roots disagree with each other -- all cases the caller should report rather
    than guess at.
    """
    nodes = getattr(gltf, "nodes", None) or []
    if not nodes:
        return None

    results: list[np.ndarray] = []
    for root in _scene_roots(gltf):
        chain = _chain_to_first_mesh(gltf, root)
        if chain is None:
            continue
        composed = np.eye(3)
        for index in chain:
            composed = composed @ node_rotation(nodes[index])
        results.append(composed)

    if not results:
        return None
    first = results[0]
    for other in results[1:]:
        if not np.allclose(first, other, atol=1e-3):
            # Two root objects oriented differently: there is no single answer.
            return None
    return first


def snap_to_axis(vector: np.ndarray) -> str | None:
    """Name the cardinal axis a vector points at, or None if it is off-axis."""
    length = np.linalg.norm(vector)
    if not np.isfinite(length) or length == 0:
        return None
    unit = vector / length
    best_name, best_dot = None, -2.0
    for name, axis in AXES.items():
        dot = float(np.dot(unit, axis))
        if dot > best_dot:
            best_name, best_dot = name, dot
    return best_name if best_dot >= AXIS_TOLERANCE else None


def get_model_facing_direction(gltf) -> str | None:
    """Which world axis this asset's front points at, or None if undeterminable."""
    rotation = orientation_matrix(gltf)
    if rotation is None:
        return None
    return snap_to_axis(rotation @ GLTF_FORWARD)


def get_model_up_direction(gltf) -> str | None:
    """Which world axis is up for this asset, or None if undeterminable."""
    rotation = orientation_matrix(gltf)
    if rotation is None:
        return None
    return snap_to_axis(rotation @ GLTF_UP)
