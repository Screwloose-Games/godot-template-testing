"""Unwrap every visible mesh into one shared 0-1 atlas layout.

All the renderable objects go into a single multi-object edit session so
smart_project and pack_islands treat them as one surface. That is what makes a
single atlas possible: islands from the body, the wheels and the gun all compete
for the same UV space and get texel density in proportion to their real area.

Collision proxies are excluded -- they are never shaded, and giving them atlas
space would steal texels from geometry that is.
"""

import bpy
import math


def uv_targets():
    return [obj for obj in bpy.data.objects
            if obj.type == 'MESH' and "-convcol" not in obj.name]


def _view3d_override():
    """Operator context. smart_project and pack_islands are 3D-viewport operators;
    called from a script with no area they fail with a poll error."""
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                for region in area.regions:
                    if region.type == 'WINDOW':
                        return {"window": window, "area": area, "region": region}
    return None


def unwrap(angle_limit=66.0, island_margin=0.0035, pack_margin=0.0025):
    targets = uv_targets()
    if not targets:
        raise RuntimeError("nothing to unwrap")

    for obj in targets:
        if not obj.data.uv_layers:
            obj.data.uv_layers.new(name="UVMap")

    if bpy.context.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.select_all(action='DESELECT')
    for obj in targets:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = targets[0]

    override = _view3d_override()
    if override is None:
        raise RuntimeError("no VIEW_3D area available for the UV operators")

    with bpy.context.temp_override(**override):
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        # area_weight 1.0 keeps islands scaled by their real-world area, so a
        # 2 m body panel gets more texels than a rivet instead of the same.
        bpy.ops.uv.smart_project(
            angle_limit=math.radians(angle_limit),
            island_margin=island_margin,
            area_weight=1.0,
            correct_aspect=True,
            scale_to_bounds=False)
        bpy.ops.uv.select_all(action='SELECT')
        bpy.ops.uv.pack_islands(
            rotate=True, scale=True, merge_overlap=False,
            margin=pack_margin, shape_method='CONCAVE')
        bpy.ops.object.mode_set(mode='OBJECT')

    return targets


def uv_report():
    """Coverage and out-of-range check. Anything outside 0-1 would bake into the
    wrong tile, and low coverage means texels are being thrown away."""
    lo = [9e9, 9e9]
    hi = [-9e9, -9e9]
    loops = 0
    for obj in uv_targets():
        layer = obj.data.uv_layers.active
        if layer is None:
            continue
        for datum in layer.data:
            u, v = datum.uv
            lo[0] = min(lo[0], u)
            lo[1] = min(lo[1], v)
            hi[0] = max(hi[0], u)
            hi[1] = max(hi[1], v)
            loops += 1
    return {
        "loops": loops,
        "u_range": [round(lo[0], 4), round(hi[0], 4)],
        "v_range": [round(lo[1], 4), round(hi[1], 4)],
        "outside_0_1": bool(lo[0] < -1e-4 or lo[1] < -1e-4
                            or hi[0] > 1 + 1e-4 or hi[1] > 1 + 1e-4),
    }
