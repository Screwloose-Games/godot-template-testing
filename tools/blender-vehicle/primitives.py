"""Geometry helpers for the jeep_turret asset.

Everything here writes into a bmesh in the *object's local frame*. Nothing ever
touches obj.rotation_euler or obj.scale: the repo's validator treats this asset
as static (no skins, no animations), so gltf_transforms.py inspects every node
on the mesh chain and fails any rotation over 0.5 deg or scale off 1.0. Building
geometry pre-transformed is what keeps those nodes identity by construction
rather than by cleanup.

Blender frame: +Y is the model's front (exports to glTF -Z, Godot's forward),
+Z is up (exports to glTF +Y), metres throughout.
"""

import bpy
import bmesh
import math
from mathutils import Matrix, Vector

# ---------------------------------------------------------------------------
# Scene plumbing
# ---------------------------------------------------------------------------


def wipe_scene():
    """Remove every object and orphan datablock. The scene starts empty anyway;
    this makes a re-run idempotent."""
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for collection in (bpy.data.meshes, bpy.data.materials, bpy.data.images,
                       bpy.data.node_groups, bpy.data.armatures):
        for item in list(collection):
            if item.users == 0:
                collection.remove(item)


def new_empty(name, world_location=(0.0, 0.0, 0.0), parent=None, size=0.12):
    """A pivot node, placed by *world* location.

    matrix_parent_inverse is deliberately left at identity and the local location
    is derived by subtracting the parent's world position. Blender's default
    parenting stashes an inverse matrix that the glTF exporter then bakes into the
    node transform, which puts an offset on nodes that should be clean. Doing the
    arithmetic here keeps every node's transform exactly what it looks like.
    """
    empty = bpy.data.objects.new(name, None)
    empty.empty_display_type = 'PLAIN_AXES'
    empty.empty_display_size = size
    bpy.context.scene.collection.objects.link(empty)
    origin = Vector((0.0, 0.0, 0.0))
    if parent is not None:
        empty.parent = parent
        origin = world_origin(parent)
    empty.location = Vector(world_location) - origin
    return empty


def world_origin(obj):
    """Accumulated world position of a chain built only from translations."""
    position = Vector((0.0, 0.0, 0.0))
    node = obj
    while node is not None:
        position += node.location
        node = node.parent
    return position


def new_mesh_object(name, bm, parent=None, materials=None):
    """Commit a bmesh to a new object sitting exactly on its parent's origin.

    The object's own transform is identity -- location included -- so only Empties
    ever carry a translation. Geometry must therefore already be in the parent's
    frame; use finish() with a pivot for that.
    """
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    if parent is not None:
        obj.parent = parent
    for material in (materials or []):
        obj.data.materials.append(material)
    return obj


def mark_sharp(bm, angle_degrees):
    """Smooth-shade everything, then mark edges sharper than the threshold.

    Blender 4.1 removed mesh.use_auto_smooth and 5.x offers only a geometry-nodes
    "Smooth by Angle" asset in its place, which is an awkward dependency to carry
    into an export. Writing the sharp flags onto the edges does the same job in the
    mesh data itself, and the glTF exporter turns them into split normals without
    anything else having to be present.
    """
    limit = math.radians(angle_degrees)
    for face in bm.faces:
        face.smooth = True
    for edge in bm.edges:
        if len(edge.link_faces) != 2:
            continue
        try:
            edge.smooth = edge.calc_face_angle() <= limit
        except ValueError:
            edge.smooth = False


def finish(bm, mesh_obj_name, parent=None, materials=None,
           shade_smooth_angle=None, pivot=None):
    """Author geometry in world coordinates, then rebase it onto its pivot.

    Everything in this build is written in world space because that is the frame a
    vehicle is legible in -- "the hub is at y=1.20" beats "the hub is at zero and
    its parent is at 1.20". `pivot` is the parent Empty's world position, and the
    geometry is shifted by -pivot so the mesh node itself stays at the origin.
    """
    if pivot is not None:
        offset = -Vector(pivot)
        if offset.length > 1e-9:
            bmesh.ops.translate(bm, verts=list(bm.verts), vec=offset)
    if shade_smooth_angle is not None:
        mark_sharp(bm, shade_smooth_angle)
    return new_mesh_object(mesh_obj_name, bm, parent=parent, materials=materials)


# ---------------------------------------------------------------------------
# Primitives -- all take world-ish coordinates in the object's local frame
# ---------------------------------------------------------------------------


def add_box(bm, center, size, mat=0):
    """Axis-aligned box. center and size are (x, y, z); size is full extent."""
    ret = bmesh.ops.create_cube(bm, size=1.0)
    matrix = Matrix.Translation(center) @ Matrix.Diagonal(
        (size[0], size[1], size[2], 1.0))
    bmesh.ops.transform(bm, matrix=matrix, verts=ret['verts'])
    faces = _faces_of(ret['verts'])
    _assign(faces, mat)
    return faces


def add_wedge(bm, center, size, taper_top=1.0, taper_front=1.0, mat=0):
    """A box whose top face is scaled by taper_top and whose +Y end is scaled by
    taper_front. Cheap way to get a sloped hood or a tapered armour plate."""
    faces = add_box(bm, center, size, mat=mat)
    verts = set()
    for face in faces:
        verts.update(face.verts)
    cx, cy, cz = center
    half_z = size[2] * 0.5
    half_y = size[1] * 0.5
    for vert in verts:
        if taper_top != 1.0 and vert.co.z > cz:
            vert.co.x = cx + (vert.co.x - cx) * taper_top
        if taper_front != 1.0 and vert.co.y > cy:
            vert.co.x = cx + (vert.co.x - cx) * taper_front
            vert.co.z = cz + (vert.co.z - cz) * taper_front
    _ = half_z, half_y
    return faces


def _rotation_to(direction):
    """Rotation taking +Z onto `direction`. create_cone builds along +Z."""
    direction = Vector(direction)
    if direction.length < 1e-9:
        return Matrix.Identity(4)
    return Vector((0.0, 0.0, 1.0)).rotation_difference(
        direction.normalized()).to_matrix().to_4x4()


def add_cyl(bm, center, radius, depth, segments=12, axis='Z',
            radius_top=None, mat=0, cap=True):
    ret = bmesh.ops.create_cone(
        bm, cap_ends=cap, cap_tris=False, segments=segments,
        radius1=radius, radius2=radius if radius_top is None else radius_top,
        depth=depth)
    direction = {'X': (1, 0, 0), 'Y': (0, 1, 0), 'Z': (0, 0, 1)}[axis]
    matrix = Matrix.Translation(center) @ _rotation_to(direction)
    bmesh.ops.transform(bm, matrix=matrix, verts=ret['verts'])
    faces = _faces_of(ret['verts'])
    _assign(faces, mat)
    return faces


def add_box_dir(bm, center, size, direction, mat=0):
    """A box whose local +Z is aimed along `direction`.

    For things that sit radially on a circle -- tyre tread blocks, ring bolts --
    where an axis-aligned box would stick out at the corners and a cylinder would
    look wrong. The rotation goes into the vertices, never onto the object.
    """
    ret = bmesh.ops.create_cube(bm, size=1.0)
    matrix = (Matrix.Translation(center) @ _rotation_to(direction)
              @ Matrix.Diagonal((size[0], size[1], size[2], 1.0)))
    bmesh.ops.transform(bm, matrix=matrix, verts=ret['verts'])
    faces = _faces_of(ret['verts'])
    _assign(faces, mat)
    return faces


def add_tube(bm, start, end, radius, segments=6, mat=0, cap=True):
    """A capsule-less tube between two points -- the roll cage's building block."""
    start, end = Vector(start), Vector(end)
    delta = end - start
    length = delta.length
    if length < 1e-6:
        return []
    ret = bmesh.ops.create_cone(
        bm, cap_ends=cap, cap_tris=False, segments=segments,
        radius1=radius, radius2=radius, depth=length)
    matrix = Matrix.Translation((start + end) * 0.5) @ _rotation_to(delta)
    bmesh.ops.transform(bm, matrix=matrix, verts=ret['verts'])
    faces = _faces_of(ret['verts'])
    _assign(faces, mat)
    return faces


def add_plate(bm, corners, thickness, mat=0, planar_tolerance=1e-4):
    """Extrude a flat quad (4 xyz corners, wound consistently) into a plate.

    Used for the welded scrap armour, where the panels are not axis-aligned and a
    box would need a rotation.

    The corners must be coplanar and this asserts it. extrude_face_region pushes
    along the face's averaged normal, so a skewed quad extrudes in a direction that
    matches none of its edges and throws geometry off-model -- which shows up much
    later as a bounding box that is inexplicably too big, not as an error here.
    """
    points = [Vector(c) for c in corners]
    if len(points) == 4:
        normal = (points[1] - points[0]).cross(points[2] - points[0])
        if normal.length > 1e-9:
            offset = abs((points[3] - points[0]).dot(normal.normalized()))
            if offset > planar_tolerance:
                raise ValueError(
                    f"add_plate corners are not coplanar: the fourth is {offset:.4f} "
                    "off the plane of the first three. Give the opposing edges a "
                    "shared axis value, or build the shape from two plates.")
    verts = [bm.verts.new(p) for p in points]
    face = bm.faces.new(verts)
    bm.normal_update()
    ret = bmesh.ops.extrude_face_region(bm, geom=[face])
    new_verts = [g for g in ret['geom'] if isinstance(g, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=new_verts, vec=face.normal * thickness)
    faces = _faces_of(verts + new_verts)
    _assign(faces, mat)
    return faces


def _faces_of(verts):
    faces = set()
    for vert in verts:
        for face in vert.link_faces:
            faces.add(face)
    return list(faces)


def _assign(faces, mat):
    for face in faces:
        face.material_index = mat


def mirror_x(bm, faces=None):
    """Duplicate geometry across X=0. Called once per object after building the
    left-hand side, which halves the authoring and guarantees symmetry."""
    geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
    ret = bmesh.ops.duplicate(bm, geom=geom)
    new_verts = [g for g in ret['geom'] if isinstance(g, bmesh.types.BMVert)]
    bmesh.ops.scale(bm, vec=(-1.0, 1.0, 1.0), verts=new_verts)
    bmesh.ops.reverse_faces(
        bm, faces=[g for g in ret['geom'] if isinstance(g, bmesh.types.BMFace)])
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=1e-5)
    _ = faces


def bevel(bm, width=0.012, segments=2, angle_limit=30.0, only_sharp=True):
    """Bevel every edge sharper than angle_limit. This is where a blockout starts
    reading as built metal rather than as boxes."""
    bm.normal_update()
    edges = []
    limit = math.radians(angle_limit)
    for edge in bm.edges:
        if len(edge.link_faces) != 2:
            continue
        try:
            if (not only_sharp) or edge.calc_face_angle() > limit:
                edges.append(edge)
        except ValueError:
            continue
    if edges:
        bmesh.ops.bevel(bm, geom=edges, offset=width, segments=segments,
                        profile=0.5, affect='EDGES', clamp_overlap=True)
    return len(edges)


def cleanup(bm, merge_distance=1e-5):
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=merge_distance)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))


def tri_count(obj):
    mesh = obj.data
    return sum(len(polygon.vertices) - 2 for polygon in mesh.polygons)


def scene_tris():
    return sum(tri_count(o) for o in bpy.data.objects if o.type == 'MESH')


def bounds():
    """World-space bounding box over every mesh object, in Blender axes."""
    lo = [float('inf')] * 3
    hi = [float('-inf')] * 3
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in bpy.data.objects:
        if obj.type != 'MESH':
            continue
        evaluated = obj.evaluated_get(depsgraph)
        for corner in evaluated.bound_box:
            world = evaluated.matrix_world @ Vector(corner)
            for axis in range(3):
                lo[axis] = min(lo[axis], world[axis])
                hi[axis] = max(hi[axis], world[axis])
    return lo, hi, [hi[i] - lo[i] for i in range(3)]
