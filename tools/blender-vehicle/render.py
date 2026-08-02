"""Render turntable-ish views of whatever is in the scene.

The camera and lights live in a `_render_rig` collection so the whole rig can be
deleted in one call before the glTF export. A stray light or camera in the export
is the kind of thing that survives all the way into the engine.
"""

import bpy
import math
from mathutils import Vector

RIG = "_render_rig"


def clear_rig():
    collection = bpy.data.collections.get(RIG)
    if collection is None:
        return
    for obj in list(collection.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.collections.remove(collection)


def make_rig():
    clear_rig()
    collection = bpy.data.collections.new(RIG)
    bpy.context.scene.collection.children.link(collection)

    world = bpy.data.worlds.get("render_world") or bpy.data.worlds.new("render_world")
    world.use_nodes = True
    background = world.node_tree.nodes["Background"]
    background.inputs[0].default_value = (0.055, 0.058, 0.065, 1.0)
    background.inputs[1].default_value = 1.0
    bpy.context.scene.world = world

    def add_light(name, kind, energy, location, rotation, size=3.0, colour=(1, 1, 1)):
        data = bpy.data.lights.new(name, kind)
        data.energy = energy
        data.color = colour
        if kind == 'AREA':
            data.size = size
        if kind == 'SUN':
            data.angle = math.radians(6.0)
        obj = bpy.data.objects.new(name, data)
        obj.location = location
        obj.rotation_euler = rotation
        collection.objects.link(obj)
        return obj

    # Key from the front-left high, a cool fill from the right, a warm rim behind.
    add_light("key", 'SUN', 4.2, (-4, 5, 7), (math.radians(48), 0, math.radians(-150)))
    add_light("fill", 'AREA', 260.0, (5.5, -2.0, 3.0),
              (math.radians(72), 0, math.radians(72)), size=6.0,
              colour=(0.62, 0.72, 1.0))
    add_light("rim", 'AREA', 420.0, (-2.0, -6.0, 3.4),
              (math.radians(76), 0, math.radians(-198)), size=5.0,
              colour=(1.0, 0.72, 0.42))

    camera_data = bpy.data.cameras.new("view_cam")
    camera = bpy.data.objects.new("view_cam", camera_data)
    collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def aim(camera, position, target):
    camera.location = position
    direction = Vector(target) - Vector(position)
    camera.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()


def render(path, resolution=(1100, 800), samples=48, engine=None):
    """Beauty render.

    The engine is set explicitly every time. The bake switches the scene to Cycles
    at one sample and leaves it there, so a render that inherits the scene's engine
    silently becomes a one-sample Cycles render -- which looks exactly like a badly
    baked texture and sent me hunting through the atlas for a problem that was never
    in it.
    """
    scene = bpy.context.scene
    if engine is None:
        engine = 'BLENDER_EEVEE' if 'BLENDER_EEVEE' in {
            item.identifier for item in
            type(scene.render).bl_rna.properties['engine'].enum_items
        } else 'BLENDER_EEVEE_NEXT'
    scene.render.engine = engine
    scene.cycles.samples = max(samples, 128)
    scene.render.resolution_x, scene.render.resolution_y = resolution
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.film_transparent = False
    if hasattr(scene, "eevee"):
        for attribute in ("taa_render_samples", "samples"):
            if hasattr(scene.eevee, attribute):
                setattr(scene.eevee, attribute, samples)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def views(out_dir, prefix, centre=(0.0, -0.1, 1.0)):
    """Four reads of the model: hero three-quarter, plus flat ortho front/side/top."""
    camera = make_rig()
    written = []

    camera.data.type = 'PERSP'
    camera.data.lens = 55
    aim(camera, (-4.6, 4.4, 2.9), centre)
    written.append(render(f"{out_dir}/{prefix}_hero.png"))

    aim(camera, (5.0, -4.6, 2.6), (0.0, -0.5, 1.0))
    written.append(render(f"{out_dir}/{prefix}_rear34.png"))

    # Ortho scale is set per view off the axis actually being framed, so the model
    # fills each plate instead of floating in it.
    camera.data.type = 'ORTHO'
    camera.data.ortho_scale = 2.35
    aim(camera, (0.0, 12.0, 1.05), (0.0, 0.0, 1.05))
    written.append(render(f"{out_dir}/{prefix}_front.png", (760, 860)))

    camera.data.ortho_scale = 4.15
    aim(camera, (-12.0, 0.0, 1.05), (0.0, 0.0, 1.05))
    written.append(render(f"{out_dir}/{prefix}_side.png", (1200, 760)))

    camera.data.ortho_scale = 4.15
    aim(camera, (0.0, 0.0, 12.0), (0.0, 0.0, 0.0))
    written.append(render(f"{out_dir}/{prefix}_top.png", (760, 1120)))

    return written
