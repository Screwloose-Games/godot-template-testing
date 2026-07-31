"""Collapse the authoring materials onto the baked atlas and export the glTF.

The 11 zone materials existed to drive the bake. Once the atlas holds their result,
the mesh only needs three: one opaque material reading the atlas, one blended one
for glass, and one emissive one for the light lenses. Everything else -- rust,
paint, rubber, leather -- is now pixels, so it collapses into slot 0 and the face
indices are remapped to match.

Three rather than one because alpha and emission are material-level facts in glTF,
not texture-level ones: a windscreen cannot be a region of an opaque material.
"""

import bpy
import os

ATLAS = "mat_jeep_turret"
GLASS = "mat_jeep_turret_glass"
LIGHTS = "mat_jeep_turret_lights"


def _image(path, non_color):
    name = os.path.basename(path)
    image = bpy.data.images.get(name)
    if image is None:
        image = bpy.data.images.load(path, check_existing=True)
    image.name = name
    image.colorspace_settings.name = 'Non-Color' if non_color else 'sRGB'
    return image


def build_export_materials(asset_dir, stem):
    for name in (ATLAS, GLASS, LIGHTS):
        existing = bpy.data.materials.get(name)
        if existing is not None:
            bpy.data.materials.remove(existing)

    base_image = _image(f"{asset_dir}/t_{stem}_basecolor.png", False)
    mr_image = _image(f"{asset_dir}/t_{stem}_metallic_roughness.png", True)
    normal_image = _image(f"{asset_dir}/t_{stem}_normal.png", True)

    material = bpy.data.materials.new(ATLAS)
    material.use_nodes = True
    tree = material.node_tree
    nodes, links = tree.nodes, tree.links
    bsdf = nodes["Principled BSDF"]

    base_node = nodes.new("ShaderNodeTexImage")
    base_node.image = base_image
    base_node.location = (-700, 300)
    links.new(base_node.outputs["Color"], bsdf.inputs["Base Color"])

    # One image driving both Metallic and Roughness through Separate Color is the
    # exact node shape the glTF exporter looks for; it collapses to a single
    # pbrMetallicRoughness texture with G=roughness, B=metallic. Wiring them from
    # two separate images would export two textures and double the memory.
    mr_node = nodes.new("ShaderNodeTexImage")
    mr_node.image = mr_image
    mr_node.location = (-700, 0)
    separate = nodes.new("ShaderNodeSeparateColor")
    separate.location = (-420, 0)
    links.new(mr_node.outputs["Color"], separate.inputs["Color"])
    links.new(separate.outputs["Green"], bsdf.inputs["Roughness"])
    links.new(separate.outputs["Blue"], bsdf.inputs["Metallic"])

    normal_node = nodes.new("ShaderNodeTexImage")
    normal_node.image = normal_image
    normal_node.location = (-700, -320)
    normal_map = nodes.new("ShaderNodeNormalMap")
    normal_map.location = (-420, -320)
    links.new(normal_node.outputs["Color"], normal_map.inputs["Color"])
    links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])

    glass = bpy.data.materials.new(GLASS)
    glass.use_nodes = True
    glass_bsdf = glass.node_tree.nodes["Principled BSDF"]
    glass_bsdf.inputs["Base Color"].default_value = (0.42, 0.50, 0.48, 1.0)
    glass_bsdf.inputs["Roughness"].default_value = 0.08
    glass_bsdf.inputs["Metallic"].default_value = 0.0
    glass_bsdf.inputs["Alpha"].default_value = 0.30
    if hasattr(glass, "surface_render_method"):
        glass.surface_render_method = 'BLENDED'

    lights = bpy.data.materials.new(LIGHTS)
    lights.use_nodes = True
    light_bsdf = lights.node_tree.nodes["Principled BSDF"]
    light_bsdf.inputs["Base Color"].default_value = (1.0, 0.91, 0.74, 1.0)
    light_bsdf.inputs["Roughness"].default_value = 0.22
    light_bsdf.inputs["Emission Color"].default_value = (1.0, 0.91, 0.74, 1.0)
    light_bsdf.inputs["Emission Strength"].default_value = 1.0

    return material, glass, lights


def remap_materials(zone_names, glass_zone, light_zone, materials):
    """Rewrite every mesh's slots to [atlas, glass, lights] and move face indices
    onto the new layout."""
    lookup = {}
    for index, name in enumerate(zone_names):
        if name == glass_zone:
            lookup[index] = 1
        elif name == light_zone:
            lookup[index] = 2
        else:
            lookup[index] = 0

    for obj in bpy.data.objects:
        if obj.type != 'MESH':
            continue
        if "-convcol" in obj.name:
            # Collision proxies carry no material at all; Godot discards their
            # visual mesh anyway once the -convcolonly suffix is read.
            obj.data.materials.clear()
            continue
        remapped = [lookup.get(polygon.material_index, 0)
                    for polygon in obj.data.polygons]
        obj.data.materials.clear()
        for material in materials:
            obj.data.materials.append(material)
        for polygon, index in zip(obj.data.polygons, remapped):
            polygon.material_index = index


def export(filepath):
    # Proxies were hidden from rendering so they could not occlude the AO bake.
    # They must be visible again to reach the glTF -- they are the collision.
    for obj in bpy.data.objects:
        obj.hide_render = False
        obj.hide_viewport = False

    if bpy.context.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.select_all(action='DESELECT')

    options = dict(
        filepath=filepath,
        export_format='GLTF_SEPARATE',
        export_yup=True,
        export_apply=True,
        use_selection=False,
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_materials='EXPORT',
        export_image_format='AUTO',
        export_normals=True,
        export_tangents=False,
        export_texcoords=True,
        export_animations=False,
        export_skins=False,
        export_morph=False,
    )

    # Blender 5.x renamed and added operator properties; passing an unknown one is
    # a hard error, so the call is filtered against the operator's actual schema.
    valid = set(bpy.ops.export_scene.gltf.get_rna_type().properties.keys())
    filtered = {k: v for k, v in options.items() if k in valid}
    dropped = sorted(set(options) - valid)
    bpy.ops.export_scene.gltf(**filtered)
    return {"dropped_options": dropped, "used": sorted(filtered)}
