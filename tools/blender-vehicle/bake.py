"""Bake the procedural surfaces down to a glTF-ready atlas.

Base colour, roughness and metallic are captured with the emission trick rather
than with Cycles' DIFFUSE/ROUGHNESS passes: the channel's own socket is temporarily
routed into an Emission shader, so what lands in the image is exactly the value the
shader computed, noise-free at one sample. Cycles has no metallic pass at all, so
that channel needs the trick regardless -- doing all three the same way means one
code path instead of three, and no pass-semantics surprises.

Ambient occlusion is a real Cycles bake (it needs ray casting) and gets multiplied
into base colour afterwards, which is what puts dirt in the panel gaps and under
the fenders. The normal map is a tangent-space bake of the shader normal, so the
procedural bump survives into the engine as texture rather than as triangles.

Bake targets are float images so the arithmetic happens in linear light. The saved
files are 8-bit: base colour is sRGB-encoded on the way out, the data maps are
written linear, matching what glTF expects of each.
"""

import bpy
import numpy as np

CHANNELS = ("basecolor", "roughness", "metallic")


def renderable():
    return [obj for obj in bpy.data.objects
            if obj.type == 'MESH' and "-convcol" not in obj.name]


def _new_float_image(name, size):
    existing = bpy.data.images.get(name)
    if existing is not None:
        bpy.data.images.remove(existing)
    image = bpy.data.images.new(name, size, size, alpha=False, float_buffer=True)
    image.colorspace_settings.name = 'Non-Color'
    return image


def _bake_node(material):
    """The Image Texture node the bake writes into. One per material, kept around
    and reused so repeated bakes do not litter the tree."""
    tree = material.node_tree
    node = tree.nodes.get("BAKE_TARGET")
    if node is None:
        node = tree.nodes.new("ShaderNodeTexImage")
        node.name = "BAKE_TARGET"
        node.label = "BAKE_TARGET"
        node.location = (-1200, -700)
    return node


def _target_all(image):
    for material in bpy.data.materials:
        if not material.use_nodes:
            continue
        node = _bake_node(material)
        node.image = image
        node.select = True
        material.node_tree.nodes.active = node


def _route_emission(channels, which):
    """Swap every material's surface for an Emission fed by `which` channel."""
    for material in bpy.data.materials:
        if not material.use_nodes:
            continue
        info = channels.get(material.name)
        if info is None:
            continue
        tree = material.node_tree
        emission = tree.nodes.get("BAKE_EMIT")
        if emission is None:
            emission = tree.nodes.new("ShaderNodeEmission")
            emission.name = "BAKE_EMIT"
            emission.location = (600, -400)
        source = info[which]
        for link in list(emission.inputs["Color"].links):
            tree.links.remove(link)
        if isinstance(source, bpy.types.NodeSocket):
            tree.links.new(source, emission.inputs["Color"])
        else:
            value = source if isinstance(source, (tuple, list)) else (source,) * 3
            emission.inputs["Color"].default_value = (value[0], value[1], value[2], 1.0)
        tree.links.new(emission.outputs["Emission"],
                       info["output"].inputs["Surface"])


def _restore_shaders(channels):
    for material in bpy.data.materials:
        info = channels.get(material.name)
        if info is None or not material.use_nodes:
            continue
        material.node_tree.links.new(info["bsdf"].outputs["BSDF"],
                                     info["output"].inputs["Surface"])


def _select_for_bake():
    objects = renderable()
    if bpy.context.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    return objects


def _configure(samples, denoise=False):
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = samples
    scene.cycles.use_denoising = denoise
    scene.render.bake.margin = 16
    scene.render.bake.use_clear = True
    scene.render.bake.use_selected_to_active = False


def _blur_axis1(plane, radius):
    """Box blur along axis 1, via a running sum. Cheap and good enough -- this is
    smoothing occlusion, not filtering a signal."""
    width = 2 * radius + 1
    padded = np.pad(plane, ((0, 0), (radius, radius)), mode='edge')
    running = np.cumsum(padded, axis=1, dtype=np.float64)
    running = np.concatenate(
        [np.zeros((plane.shape[0], 1), dtype=np.float64), running], axis=1)
    return ((running[:, width:] - running[:, :-width]) / width).astype(np.float32)


def _soften(values, size, radius=3):
    """Blur an occlusion channel in both axes.

    Even a denoised AO bake keeps some grain, and grain multiplied into albedo is
    salt-and-pepper across every flat panel. Texels the bake never reached come back
    as exactly 0 -- fully occluded -- so they are lifted to 1 first, otherwise the
    blur drags black in from the empty atlas space and rims every island.
    """
    plane = values.reshape(size, size).copy()
    plane[plane <= 0.0] = 1.0
    plane = _blur_axis1(plane, radius)
    plane = _blur_axis1(plane.T, radius).T
    return plane.reshape(-1, 1)


def _read(image):
    buffer = np.empty(len(image.pixels), dtype=np.float32)
    image.pixels.foreach_get(buffer)
    return buffer.reshape(-1, 4)


def _linear_to_srgb(values):
    values = np.clip(values, 0.0, 1.0)
    return np.where(values <= 0.0031308,
                    values * 12.92,
                    1.055 * np.power(values, 1.0 / 2.4) - 0.055)


def _write_png(path, rgb, size, srgb):
    """Commit an RGB float array to an 8-bit PNG.

    A byte image is used rather than a float one so the file is 8-bit, and the sRGB
    transfer is applied here rather than left to Blender: writing already-encoded
    values into an image tagged sRGB means the bytes on disk and the tag agree, with
    no second conversion happening at save time.
    """
    name = path.rsplit("/", 1)[-1]
    existing = bpy.data.images.get(name)
    if existing is not None:
        bpy.data.images.remove(existing)
    image = bpy.data.images.new(name, size, size, alpha=False, float_buffer=False)
    image.colorspace_settings.name = 'sRGB' if srgb else 'Non-Color'
    data = _linear_to_srgb(rgb) if srgb else np.clip(rgb, 0.0, 1.0)
    flat = np.ones((size * size, 4), dtype=np.float32)
    flat[:, :3] = data
    image.pixels.foreach_set(flat.reshape(-1))
    image.filepath_raw = path
    image.file_format = 'PNG'
    image.save()
    return image


def bake_atlas(channels, out_dir, stem, size=2048, ao_samples=64,
               ao_strength=0.85):
    objects = _select_for_bake()
    _configure(1)

    baked = {}
    for which in CHANNELS:
        image = _new_float_image(f"_bake_{which}", size)
        _target_all(image)
        _route_emission(channels, which)
        bpy.ops.object.bake(type='EMIT')
        baked[which] = _read(image)

    _restore_shaders(channels)

    # Ambient occlusion needs real rays, so this one is a genuine Cycles pass.
    ao_image = _new_float_image("_bake_ao", size)
    _target_all(ao_image)
    _configure(ao_samples, denoise=True)
    bpy.ops.object.bake(type='AO')
    baked["ao"] = _read(ao_image)

    normal_image = _new_float_image("_bake_normal", size)
    _target_all(normal_image)
    _configure(1)
    bake = bpy.context.scene.render.bake
    bake.normal_space = 'TANGENT'
    bake.normal_r, bake.normal_g, bake.normal_b = 'POS_X', 'POS_Y', 'POS_Z'
    bpy.ops.object.bake(type='NORMAL')
    baked["normal"] = _read(normal_image)

    # --- compose ---------------------------------------------------------
    ao = _soften(baked["ao"][:, 0], size)
    occlusion = 1.0 - ao_strength * (1.0 - np.clip(ao, 0.0, 1.0))
    base = baked["basecolor"][:, :3] * occlusion

    metallic_roughness = np.zeros((size * size, 3), dtype=np.float32)
    metallic_roughness[:, 1] = baked["roughness"][:, 0]   # G = roughness
    metallic_roughness[:, 2] = baked["metallic"][:, 0]    # B = metallic

    normal = baked["normal"][:, :3]
    # Texels the bake never touched are (0,0,0), which decodes to a normal pointing
    # away from the surface. Flat (0.5, 0.5, 1.0) is the safe filler.
    untouched = np.all(normal <= 1e-6, axis=1)
    normal[untouched] = (0.5, 0.5, 1.0)

    written = {
        "basecolor": _write_png(f"{out_dir}/t_{stem}_basecolor.png", base, size, True),
        "metallic_roughness": _write_png(
            f"{out_dir}/t_{stem}_metallic_roughness.png", metallic_roughness, size, False),
        "normal": _write_png(f"{out_dir}/t_{stem}_normal.png", normal, size, False),
    }

    for key in ("_bake_basecolor", "_bake_roughness", "_bake_metallic",
                "_bake_ao", "_bake_normal"):
        image = bpy.data.images.get(key)
        if image is not None:
            bpy.data.images.remove(image)

    _ = objects
    return written
