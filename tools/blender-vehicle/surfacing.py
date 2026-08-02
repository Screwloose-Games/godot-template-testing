"""Procedural surface materials for the jeep, and the channel registry the bake
needs to read them back out.

Each zone gets the same graph shape driven by different numbers: a wear mask from
a noise texture decides where the surface has gone from its clean state to its
worn one, and that single mask drives base colour, roughness, metallic and bump
together. Rust reads as rust because it is simultaneously browner, rougher, less
metallic and pitted -- driving those four from one mask is what keeps them
agreeing with each other.

Textures are sampled in *object* space, not UV space. The UVs are atlas-packed, so
a UV-space texture would break at every island edge; object-space noise is
continuous across the whole part and the seams disappear.

MATERIAL_CHANNELS records which socket ends up feeding Base Color, Roughness and
Metallic on each material. The bake re-routes those sockets through an Emission
node to capture each channel exactly -- see bake_atlas.py.
"""

import bpy

MATERIAL_CHANNELS = {}

# base rgb, worn rgb, metal clean, metal worn, rough clean, rough worn,
# wear noise scale, wear ramp low/high, bump scale, bump strength, pitting
#
# Bump strength is the Bump node's *blend factor*, not a height in metres -- it
# mixes between the geometric normal and the perturbed one. Values in the low
# hundredths bake to an essentially flat normal map; these are set where the relief
# actually survives into the texture, strongest on corroded steel and softest on
# paint and chrome, which are smooth surfaces that happen to be discoloured.
ZONE_SURFACES = {
    "paint_body": ((0.235, 0.255, 0.200), (0.30, 0.145, 0.075),
                   0.0, 0.25, 0.62, 0.88, 5.5, 0.50, 0.68, 22.0, 0.16, 0.0),
    "paint_chip": ((0.330, 0.300, 0.245), (0.28, 0.150, 0.085),
                   0.0, 0.30, 0.74, 0.90, 8.0, 0.46, 0.64, 26.0, 0.20, 0.0),
    "steel_rust": ((0.245, 0.115, 0.060), (0.46, 0.245, 0.105),
                   0.45, 0.05, 0.86, 0.96, 11.0, 0.34, 0.70, 34.0, 0.70, 0.55),
    "steel_bare": ((0.400, 0.400, 0.415), (0.255, 0.150, 0.090),
                   1.0, 0.30, 0.44, 0.80, 9.0, 0.54, 0.74, 30.0, 0.32, 0.25),
    "gunmetal": ((0.085, 0.085, 0.095), (0.165, 0.145, 0.130),
                 1.0, 0.65, 0.36, 0.62, 17.0, 0.56, 0.76, 40.0, 0.22, 0.15),
    "rubber": ((0.040, 0.040, 0.045), (0.095, 0.088, 0.076),
               0.0, 0.0, 0.90, 0.97, 24.0, 0.50, 0.74, 70.0, 0.38, 0.0),
    "canvas": ((0.245, 0.225, 0.160), (0.150, 0.132, 0.098),
               0.0, 0.0, 0.92, 0.97, 30.0, 0.44, 0.70, 110.0, 0.48, 0.0),
    "leather": ((0.115, 0.080, 0.060), (0.055, 0.040, 0.032),
                0.0, 0.0, 0.70, 0.88, 34.0, 0.44, 0.68, 85.0, 0.52, 0.35),
    "chrome": ((0.700, 0.700, 0.730), (0.330, 0.255, 0.195),
               1.0, 0.45, 0.20, 0.68, 15.0, 0.60, 0.80, 44.0, 0.13, 0.20),
}

GLASS = "glass"
LIGHT = "light"


def _tidy(tree, node, x, y):
    node.location = (x, y)
    return node


def build_zone_material(name, params):
    (base, worn, metal_clean, metal_worn, rough_clean, rough_worn,
     wear_scale, ramp_low, ramp_high, bump_scale, bump_strength, pitting) = params

    material = bpy.data.materials.new("zone_" + name)
    material.use_nodes = True
    tree = material.node_tree
    nodes, links = tree.nodes, tree.links
    nodes.clear()

    output = _tidy(tree, nodes.new("ShaderNodeOutputMaterial"), 900, 0)
    bsdf = _tidy(tree, nodes.new("ShaderNodeBsdfPrincipled"), 600, 0)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    coord = _tidy(tree, nodes.new("ShaderNodeTexCoord"), -900, 0)

    # --- wear mask -------------------------------------------------------
    wear_noise = _tidy(tree, nodes.new("ShaderNodeTexNoise"), -700, 200)
    wear_noise.inputs["Scale"].default_value = wear_scale
    wear_noise.inputs["Detail"].default_value = 8.0
    wear_noise.inputs["Roughness"].default_value = 0.62
    links.new(coord.outputs["Object"], wear_noise.inputs["Vector"])

    wear_ramp = _tidy(tree, nodes.new("ShaderNodeValToRGB"), -480, 200)
    wear_ramp.color_ramp.elements[0].position = ramp_low
    wear_ramp.color_ramp.elements[1].position = ramp_high
    links.new(wear_noise.outputs["Fac"], wear_ramp.inputs["Fac"])

    # A second, much finer noise breaks the first one's smooth blobs into
    # something that reads as corrosion rather than as a cloud texture.
    grain = _tidy(tree, nodes.new("ShaderNodeTexNoise"), -700, -60)
    grain.inputs["Scale"].default_value = wear_scale * 6.0
    grain.inputs["Detail"].default_value = 6.0
    links.new(coord.outputs["Object"], grain.inputs["Vector"])

    wear = _tidy(tree, nodes.new("ShaderNodeMix"), -260, 200)
    wear.data_type = 'FLOAT'
    wear.blend_type = 'OVERLAY'
    wear.inputs["Factor"].default_value = 0.35
    links.new(wear_ramp.outputs["Color"], wear.inputs[2])
    links.new(grain.outputs["Fac"], wear.inputs[3])

    # --- channels driven by that one mask --------------------------------
    colour = _tidy(tree, nodes.new("ShaderNodeMix"), 200, 260)
    colour.data_type = 'RGBA'
    colour.inputs[6].default_value = (*base, 1.0)
    colour.inputs[7].default_value = (*worn, 1.0)
    links.new(wear.outputs[0], colour.inputs["Factor"])
    links.new(colour.outputs[2], bsdf.inputs["Base Color"])

    roughness = _tidy(tree, nodes.new("ShaderNodeMix"), 200, 60)
    roughness.data_type = 'FLOAT'
    roughness.inputs[2].default_value = rough_clean
    roughness.inputs[3].default_value = rough_worn
    links.new(wear.outputs[0], roughness.inputs["Factor"])
    links.new(roughness.outputs[0], bsdf.inputs["Roughness"])

    metallic = _tidy(tree, nodes.new("ShaderNodeMix"), 200, -120)
    metallic.data_type = 'FLOAT'
    metallic.inputs[2].default_value = metal_clean
    metallic.inputs[3].default_value = metal_worn
    links.new(wear.outputs[0], metallic.inputs["Factor"])
    links.new(metallic.outputs[0], bsdf.inputs["Metallic"])

    # --- surface relief ---------------------------------------------------
    detail_noise = _tidy(tree, nodes.new("ShaderNodeTexNoise"), -700, -340)
    detail_noise.inputs["Scale"].default_value = bump_scale
    detail_noise.inputs["Detail"].default_value = 8.0
    detail_noise.inputs["Roughness"].default_value = 0.55
    links.new(coord.outputs["Object"], detail_noise.inputs["Vector"])

    height = detail_noise.outputs["Fac"]
    if pitting > 0.0:
        pits = _tidy(tree, nodes.new("ShaderNodeTexVoronoi"), -700, -560)
        pits.inputs["Scale"].default_value = bump_scale * 0.55
        pits.feature = 'F1'
        links.new(coord.outputs["Object"], pits.inputs["Vector"])
        combine = _tidy(tree, nodes.new("ShaderNodeMix"), -460, -450)
        combine.data_type = 'FLOAT'
        combine.blend_type = 'MULTIPLY'
        combine.inputs["Factor"].default_value = pitting
        links.new(detail_noise.outputs["Fac"], combine.inputs[2])
        links.new(pits.outputs["Distance"], combine.inputs[3])
        height = combine.outputs[0]

    bump = _tidy(tree, nodes.new("ShaderNodeBump"), 200, -360)
    bump.inputs["Strength"].default_value = bump_strength
    bump.inputs["Distance"].default_value = 0.06
    links.new(height, bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    material.diffuse_color = (*base, 1.0)
    MATERIAL_CHANNELS[material.name] = {
        "basecolor": colour.outputs[2],
        "roughness": roughness.outputs[0],
        "metallic": metallic.outputs[0],
        "bsdf": bsdf,
        "output": output,
    }
    return material


def build_flat_material(name, colour, metallic, roughness, glass=False,
                        emissive=False):
    """Glass and light lenses. Neither wants a wear mask -- a cracked, rusted
    headlight lens is a different asset decision, not a texture one."""
    material = bpy.data.materials.new("zone_" + name)
    material.use_nodes = True
    tree = material.node_tree
    bsdf = tree.nodes["Principled BSDF"]
    output = tree.nodes["Material Output"]
    bsdf.inputs["Base Color"].default_value = (*colour, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if glass:
        bsdf.inputs["Alpha"].default_value = 0.28
        if hasattr(material, "surface_render_method"):
            material.surface_render_method = 'BLENDED'
        material.blend_method = getattr(material, "blend_method", 'BLEND')
    if emissive:
        bsdf.inputs["Emission Color"].default_value = (*colour, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 2.5
    material.diffuse_color = (*colour, 1.0)
    MATERIAL_CHANNELS[material.name] = {
        "basecolor": (*colour, 1.0),
        "roughness": roughness,
        "metallic": metallic,
        "bsdf": bsdf,
        "output": output,
    }
    return material


def build_all(zone_order):
    """Materials in the exact order build_jeep.ZONES declares, because every mesh
    indexes its slots by position."""
    MATERIAL_CHANNELS.clear()
    materials = []
    for name, colour, metallic, roughness in zone_order:
        if name in ZONE_SURFACES:
            materials.append(build_zone_material(name, ZONE_SURFACES[name]))
        elif name == GLASS:
            materials.append(build_flat_material(name, colour, metallic, roughness,
                                                 glass=True))
        elif name == LIGHT:
            materials.append(build_flat_material(name, colour, metallic, roughness,
                                                 emissive=True))
        else:
            materials.append(build_flat_material(name, colour, metallic, roughness))
    return materials
