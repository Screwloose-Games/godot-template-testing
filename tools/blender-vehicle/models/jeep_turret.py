"""Build the post-apocalyptic jeep with a rear gun turret.

Run at DETAIL = 'block' for the silhouette checkpoint and DETAIL = 'final' for the
shipping mesh. Same code both times -- the flag only drives segment counts, bevels
and the greeble passes, so the blockout that gets signed off is the shape that
gets delivered rather than a separate throwaway.

Frame: +Y is the model's front, +Z is up, metres. The glTF export converts that to
-Z forward / +Y up, which is Godot's Vector3.FORWARD and the glTF up convention.

Every mesh is authored in world coordinates and rebased onto its pivot by
finish(..., pivot=). Pivot Empties carry translation only -- never rotation or
scale -- because gltf_transforms.py fails this asset on any node rotation over
0.5 degrees.
"""

import bpy
import bmesh
import math
from mathutils import Vector

from primitives import (add_box, add_box_dir, add_cyl, add_plate, add_tube,
                        add_wedge, bevel, cleanup, finish, new_empty, wipe_scene)

# Detail level. Set through build(detail=...) rather than edited here; the
# segment counts below are recomputed from it.
DETAIL = "final"
FINAL = True

# ---------------------------------------------------------------------------
# Dimensions
# ---------------------------------------------------------------------------

# Everything build.py needs to drive this model end to end. Keeping it beside the
# geometry means the spec file, the audit thresholds and the mesh cannot drift
# apart -- the numbers the validator checks are the numbers the model is built to.
SPEC = {
    "stem": "jeep_turret",
    "asset_dir": "assets/3d/vehicles/jeep_turret",
    "model_file": "sm_jeep_turret.gltf",
    "blend_file": "jeep_turret.blend",
    "target_w_h_d": (1.9, 2.1, 3.8),      # glTF axes; see audit.dimensions
    "poly_budget": 16000,
    "atlas_size": 2048,
    "ao_samples": 128,
    "ao_strength": 0.70,
}

LEN_FRONT = 1.92          # bull bar front face
LEN_REAR = -1.88          # spare wheel / bracket rear face
HALF_W = 0.95             # fender flares, the widest point
TOP_Z = 2.08              # antenna tip

WHEEL_R, WHEEL_W = 0.42, 0.30
HUB_Z = 0.42
AXLE_F, AXLE_R = 1.20, -1.15
TRACK_F, TRACK_R = 0.76, 0.78

FRAME_Z0, FRAME_Z1 = 0.34, 0.46
FLOOR_Z = 0.56            # cabin and bed floor, top surface
TUB_HALF = 0.72           # body side outer face
TUB_TOP = 1.06            # side top rail
COWL_Y = 0.58             # windshield base
WS_TOP_Y, WS_TOP_Z = 0.26, 1.50
CAGE_Z = 1.60
HOOD_Y0, HOOD_Y1 = 0.60, 1.60
HOOD_Z = 0.98
GRILLE_Y = 1.66
BED_Y = -0.40             # cab/bed divider
TAILGATE_Y = -1.58

TURRET_Y = -0.95
# The ring rides on a raised pedestal and the trunnion sits above the roll cage,
# so the gun clears the windshield head (WS_TOP_Z) and the cage rail (CAGE_Z) and
# can actually fire forward over the cab. A trunnion below those two puts the
# barrel through the crew.
RING_Z = 1.24
PITCH_Y, PITCH_Z = -0.80, 1.76
SHIELD_TOP = PITCH_Z + 0.38   # top of the shield's vision hood

STEER_HUB = Vector((-0.36, 0.40, 1.14))
STEER_TILT = math.radians(22.0)

# Segment counts. The wheels and the barrel are the only round things the player
# ever gets close to, so they get the segments and everything else stays coarse.
SEG_WHEEL = SEG_TUBE = SEG_PIPE = SEG_RING = 0


def _apply_detail(level):
    """Recompute the detail-dependent segment counts.

    'block' is the silhouette pass rendered for sign-off; 'final' is the shipping
    mesh. Same code builds both, so what gets approved is what gets delivered
    rather than a separate throwaway that then has to be matched by hand.
    """
    global DETAIL, FINAL, SEG_WHEEL, SEG_TUBE, SEG_PIPE, SEG_RING
    DETAIL = level
    FINAL = level == "final"
    SEG_WHEEL = 24 if FINAL else 14
    SEG_TUBE = 6 if FINAL else 5
    SEG_PIPE = 9 if FINAL else 6
    # Rings and the spare are seen edge-on or at distance and do not need the
    # running wheels' segment count; they were the two parts that overran their
    # budget lines on the first full-detail build.
    SEG_RING = 16 if FINAL else 10


_apply_detail("final")

# Bevel width and segment count per part. One segment is enough to catch a
# highlight on an edge and costs a third of what two do; two are spent only on the
# body, whose long panel edges are what the player actually stands next to.
BEVEL_BODY = (0.010, 1)
BEVEL_SMALL = (0.007, 1)

# Material zones. Collapsed to three glTF materials after the atlas bake:
# everything opaque becomes one atlas material, glass and lights stay separate.
ZONES = [
    ("paint_body", (0.235, 0.255, 0.200), 0.0, 0.62),
    ("paint_chip", (0.330, 0.300, 0.245), 0.0, 0.74),
    ("steel_rust", (0.300, 0.150, 0.085), 0.55, 0.86),
    ("steel_bare", (0.400, 0.400, 0.415), 1.0, 0.44),
    ("gunmetal", (0.085, 0.085, 0.095), 1.0, 0.36),
    ("rubber", (0.040, 0.040, 0.045), 0.0, 0.90),
    ("canvas", (0.245, 0.225, 0.160), 0.0, 0.92),
    ("leather", (0.115, 0.080, 0.060), 0.0, 0.70),
    ("chrome", (0.700, 0.700, 0.730), 1.0, 0.20),
    ("glass", (0.480, 0.560, 0.540), 0.0, 0.08),
    ("light", (1.000, 0.910, 0.740), 0.0, 0.22),
]
M_PAINT, M_CHIP, M_RUST, M_STEEL, M_GUN, M_RUBBER, M_CANVAS, M_LEATHER, \
    M_CHROME, M_GLASS, M_LIGHT = range(11)

GLASS_ZONES = {M_GLASS}
LIGHT_ZONES = {M_LIGHT}


def build_materials():
    materials = []
    for name, colour, metallic, roughness in ZONES:
        material = bpy.data.materials.new("zone_" + name)
        material.use_nodes = True
        bsdf = material.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = (*colour, 1.0)
        bsdf.inputs["Metallic"].default_value = metallic
        bsdf.inputs["Roughness"].default_value = roughness
        if name == "glass":
            bsdf.inputs["Alpha"].default_value = 0.28
            material.surface_render_method = 'BLENDED'
        if name == "light":
            bsdf.inputs["Emission Color"].default_value = (*colour, 1.0)
            bsdf.inputs["Emission Strength"].default_value = 2.0
        material.diffuse_color = (*colour, 1.0)
        materials.append(material)
    return materials


# ---------------------------------------------------------------------------
# Body: frame, tub, hood, front end, fenders, cowl
# ---------------------------------------------------------------------------


def build_body(mats, parent):
    bm = bmesh.new()

    # Ladder frame, visible under the sills through the wheel arches.
    for sx in (-1, 1):
        add_box(bm, (sx * 0.56, -0.10, (FRAME_Z0 + FRAME_Z1) / 2),
                (0.10, 3.05, FRAME_Z1 - FRAME_Z0), mat=M_RUST)
    for cross_y in (1.30, 0.55, -0.45, -1.35):
        add_box(bm, (0, cross_y, (FRAME_Z0 + FRAME_Z1) / 2 - 0.01),
                (1.12, 0.09, 0.08), mat=M_RUST)

    # Floor pan, one continuous plate from the pedals to the tailgate.
    add_box(bm, (0, -0.50, FLOOR_Z - 0.03), (1.42, 2.16, 0.06), mat=M_CHIP)

    for sx in (-1, 1):
        # Side panel from the cowl back to the tailgate.
        add_box(bm, (sx * (TUB_HALF - 0.03), -0.50, (FLOOR_Z + TUB_TOP) / 2),
                (0.06, 2.16, TUB_TOP - FLOOR_Z), mat=M_PAINT)
        # Top rail capping the side panel.
        add_box(bm, (sx * (TUB_HALF - 0.03), -0.50, TUB_TOP + 0.02),
                (0.11, 2.16, 0.05), mat=M_CHIP)
        # Fender flare, swept as an arc of radial segments around the wheel rather
        # than as a slab across the top of it. A box here reads as a crate bolted
        # to the side; the arc is what makes it a fender.
        #
        # The outer lip is the widest point on the vehicle, so it is placed off
        # HALF_W rather than off the track: the spec declares 1.9 m and the
        # validator checks it to 10%.
        for axle_y, track in ((AXLE_F, TRACK_F), (AXLE_R, TRACK_R)):
            flare_span = HALF_W - track
            radius = WHEEL_R + 0.075
            steps = 8 if FINAL else 5
            sweep = math.radians(158.0)
            start = math.radians(11.0)
            arc_len = (sweep / (steps - 1)) * radius * 1.35
            for index in range(steps):
                angle = start + sweep * index / (steps - 1)
                direction = (0.0, math.cos(angle), math.sin(angle))
                cy = axle_y + direction[1] * radius
                cz = HUB_Z + direction[2] * radius
                add_box_dir(bm, (sx * (track + flare_span * 0.30), cy, cz),
                            (flare_span * 1.15, arc_len, 0.05), direction,
                            mat=M_RUST)
                add_box_dir(bm, (sx * (HALF_W - 0.028), cy, cz),
                            (0.055, arc_len, 0.19), direction, mat=M_RUST)

    # Tailgate and rear panel.
    add_box(bm, (0, TAILGATE_Y + 0.03, (FLOOR_Z + TUB_TOP) / 2 + 0.02),
            (1.44, 0.06, TUB_TOP - FLOOR_Z + 0.04), mat=M_PAINT)
    add_box(bm, (0, TAILGATE_Y - 0.06, FLOOR_Z - 0.06), (1.30, 0.14, 0.16),
            mat=M_STEEL)

    # Cowl and scuttle in front of the driver.
    add_box(bm, (0, COWL_Y + 0.02, TUB_TOP - 0.04), (1.44, 0.14, 0.14),
            mat=M_PAINT)

    # Hood, sloping down towards the grille.
    add_wedge(bm, (0, (HOOD_Y0 + HOOD_Y1) / 2, HOOD_Z - 0.04),
              (1.34, HOOD_Y1 - HOOD_Y0, 0.08), taper_front=0.97, mat=M_PAINT)
    for sx in (-1, 1):
        add_box(bm, (sx * 0.68, (HOOD_Y0 + HOOD_Y1) / 2, (FLOOR_Z + HOOD_Z) / 2),
                (0.06, HOOD_Y1 - HOOD_Y0, HOOD_Z - FLOOR_Z), mat=M_PAINT)

    # Grille: slatted, because a flat plate reads as a placeholder from any angle.
    add_box(bm, (0, GRILLE_Y, (FLOOR_Z + HOOD_Z) / 2 + 0.02),
            (1.30, 0.07, HOOD_Z - FLOOR_Z - 0.06), mat=M_RUST)
    slats = 7 if FINAL else 4
    for index in range(slats):
        x = -0.52 + index * (1.04 / (slats - 1))
        add_box(bm, (x, GRILLE_Y + 0.05, (FLOOR_Z + HOOD_Z) / 2 + 0.02),
                (0.05, 0.05, HOOD_Z - FLOOR_Z - 0.14), mat=M_GUN)

    # Headlight buckets and lenses.
    for sx in (-1, 1):
        add_cyl(bm, (sx * 0.44, GRILLE_Y + 0.02, HOOD_Z - 0.16), 0.115, 0.10,
                SEG_PIPE, axis='Y', mat=M_STEEL)
        add_cyl(bm, (sx * 0.44, GRILLE_Y + 0.075, HOOD_Z - 0.16), 0.095, 0.02,
                SEG_PIPE, axis='Y', mat=M_LIGHT)

    # Bull bar: uprights, a horizontal ram beam and a mesh of scrap over the grille.
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.52, GRILLE_Y + 0.10, FLOOR_Z - 0.10),
                 (sx * 0.52, GRILLE_Y + 0.10, HOOD_Z + 0.06), 0.045, SEG_TUBE,
                 mat=M_RUST)
        add_tube(bm, (sx * 0.52, GRILLE_Y + 0.10, HOOD_Z + 0.06),
                 (sx * 0.52, LEN_FRONT - 0.05, HOOD_Z - 0.10), 0.045, SEG_TUBE,
                 mat=M_RUST)
    add_tube(bm, (-0.52, LEN_FRONT - 0.05, HOOD_Z - 0.10),
             (0.52, LEN_FRONT - 0.05, HOOD_Z - 0.10), 0.05, SEG_TUBE, mat=M_RUST)
    add_tube(bm, (-0.52, LEN_FRONT - 0.05, FLOOR_Z + 0.04),
             (0.52, LEN_FRONT - 0.05, FLOOR_Z + 0.04), 0.05, SEG_TUBE, mat=M_RUST)
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.52, LEN_FRONT - 0.05, HOOD_Z - 0.10),
                 (sx * 0.52, LEN_FRONT - 0.05, FLOOR_Z + 0.04), 0.045, SEG_TUBE,
                 mat=M_RUST)

    # Windshield frame, raked back from the cowl. Built as tubes so the rake never
    # lands on an object transform.
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.68, COWL_Y + 0.02, TUB_TOP + 0.02),
                 (sx * 0.63, WS_TOP_Y, WS_TOP_Z), 0.038, SEG_TUBE, mat=M_CHIP)
    add_tube(bm, (-0.63, WS_TOP_Y, WS_TOP_Z), (0.63, WS_TOP_Y, WS_TOP_Z),
             0.038, SEG_TUBE, mat=M_CHIP)
    # The glass itself, inset inside the frame.
    add_plate(bm, [(-0.62, COWL_Y + 0.02, TUB_TOP + 0.03),
                   (0.62, COWL_Y + 0.02, TUB_TOP + 0.03),
                   (0.62, WS_TOP_Y + 0.01, WS_TOP_Z - 0.02),
                   (-0.62, WS_TOP_Y + 0.01, WS_TOP_Z - 0.02)],
              0.012, mat=M_GLASS)

    cleanup(bm)
    if FINAL:
        bevel(bm, *BEVEL_BODY, 35.0)
        cleanup(bm)
    return finish(bm, "body", parent=parent, materials=mats, pivot=(0, 0, 0),
                  shade_smooth_angle=32.0)


# ---------------------------------------------------------------------------
# Interior
# ---------------------------------------------------------------------------


def build_interior(mats, parent):
    bm = bmesh.new()

    for sx in (-1, 1):
        seat_x = sx * 0.34
        add_box(bm, (seat_x, 0.06, FLOOR_Z + 0.13), (0.46, 0.44, 0.20),
                mat=M_LEATHER)
        add_wedge(bm, (seat_x, -0.14, FLOOR_Z + 0.44), (0.46, 0.14, 0.56),
                  taper_top=0.92, mat=M_LEATHER)
        add_box(bm, (seat_x, -0.16, FLOOR_Z + 0.78), (0.36, 0.16, 0.14),
                mat=M_CANVAS)
        add_box(bm, (seat_x, 0.06, FLOOR_Z + 0.02), (0.40, 0.38, 0.06),
                mat=M_STEEL)

    # Dashboard and gauge cluster.
    add_box(bm, (0, COWL_Y - 0.14, TUB_TOP - 0.16), (1.34, 0.22, 0.26),
            mat=M_CHIP)
    add_cyl(bm, (-0.36, COWL_Y - 0.26, TUB_TOP - 0.12), 0.075, 0.05, SEG_PIPE,
            axis='Y', mat=M_GUN)
    add_cyl(bm, (-0.36, COWL_Y - 0.29, TUB_TOP - 0.12), 0.062, 0.01, SEG_PIPE,
            axis='Y', mat=M_GLASS)
    if FINAL:
        for offset in (-0.16, 0.06):
            add_cyl(bm, (offset, COWL_Y - 0.26, TUB_TOP - 0.14), 0.048, 0.05,
                    SEG_PIPE, axis='Y', mat=M_GUN)
            add_cyl(bm, (offset, COWL_Y - 0.29, TUB_TOP - 0.14), 0.038, 0.01,
                    SEG_PIPE, axis='Y', mat=M_GLASS)
        for index in range(4):
            add_box(bm, (0.34 + index * 0.09, COWL_Y - 0.25, TUB_TOP - 0.18),
                    (0.05, 0.03, 0.05), mat=M_CHROME)

    # Steering column, tilted. Built as a tube so the rake lives in the geometry.
    column_bottom = STEER_HUB + Vector((0.0, 0.30, -0.34))
    add_tube(bm, tuple(column_bottom), tuple(STEER_HUB - Vector((0, 0.02, 0))),
             0.032, SEG_TUBE, mat=M_GUN)

    # Pedals and gear stick.
    for offset, width in ((-0.50, 0.07), (-0.36, 0.07), (-0.22, 0.09)):
        add_box(bm, (offset, COWL_Y - 0.34, FLOOR_Z + 0.09), (width, 0.11, 0.02),
                mat=M_GUN)
    add_tube(bm, (-0.02, 0.26, FLOOR_Z), (0.02, 0.30, FLOOR_Z + 0.30), 0.018,
             SEG_TUBE, mat=M_GUN)
    add_cyl(bm, (0.02, 0.30, FLOOR_Z + 0.32), 0.035, 0.05, SEG_PIPE, mat=M_LEATHER)

    # Gunner's standing platform and the grab handles either side of it.
    add_box(bm, (0, TURRET_Y - 0.28, FLOOR_Z + 0.05), (0.86, 0.62, 0.06),
            mat=M_STEEL)
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.60, TURRET_Y + 0.10, TUB_TOP + 0.04),
                 (sx * 0.60, TURRET_Y - 0.40, TUB_TOP + 0.04), 0.028, SEG_TUBE,
                 mat=M_CHIP)
        for handle_y in (TURRET_Y + 0.08, TURRET_Y - 0.38):
            add_tube(bm, (sx * 0.60, handle_y, TUB_TOP + 0.04),
                     (sx * 0.66, handle_y, TUB_TOP - 0.06), 0.026, SEG_TUBE,
                     mat=M_CHIP)

    # Ammunition crates lashed to the bed floor.
    add_box(bm, (0.42, -1.32, FLOOR_Z + 0.11), (0.42, 0.30, 0.22), mat=M_CANVAS)
    add_box(bm, (-0.44, -1.30, FLOOR_Z + 0.09), (0.36, 0.26, 0.18), mat=M_RUST)

    cleanup(bm)
    if FINAL:
        bevel(bm, *BEVEL_SMALL, 40.0)
        cleanup(bm)
    return finish(bm, "interior", parent=parent, materials=mats, pivot=(0, 0, 0),
                  shade_smooth_angle=32.0)


# ---------------------------------------------------------------------------
# Roll cage
# ---------------------------------------------------------------------------


def build_cage(mats, parent):
    bm = bmesh.new()
    radius = 0.042

    for sx in (-1, 1):
        # A-pillar continuation above the windshield frame, then the roof rail.
        add_tube(bm, (sx * 0.63, WS_TOP_Y, WS_TOP_Z),
                 (sx * 0.63, WS_TOP_Y - 0.10, CAGE_Z), radius, SEG_TUBE, mat=M_CHIP)
        add_tube(bm, (sx * 0.63, WS_TOP_Y - 0.10, CAGE_Z),
                 (sx * 0.63, BED_Y - 0.02, CAGE_Z), radius, SEG_TUBE, mat=M_CHIP)
        # B-pillar down to the tub rail behind the seats.
        add_tube(bm, (sx * 0.63, BED_Y - 0.02, CAGE_Z),
                 (sx * 0.66, BED_Y - 0.02, TUB_TOP + 0.02), radius, SEG_TUBE,
                 mat=M_CHIP)
        # Diagonal brace down to the sill -- the bit that makes a cage read as a
        # cage rather than a luggage rack.
        add_tube(bm, (sx * 0.63, BED_Y - 0.02, CAGE_Z),
                 (sx * 0.66, COWL_Y + 0.02, TUB_TOP + 0.04), radius * 0.8,
                 SEG_TUBE, mat=M_RUST)

    # Front and rear cross members over the cab.
    add_tube(bm, (-0.63, WS_TOP_Y - 0.10, CAGE_Z), (0.63, WS_TOP_Y - 0.10, CAGE_Z),
             radius, SEG_TUBE, mat=M_CHIP)
    add_tube(bm, (-0.63, BED_Y - 0.02, CAGE_Z), (0.63, BED_Y - 0.02, CAGE_Z),
             radius, SEG_TUBE, mat=M_CHIP)

    # Rear hoop behind the gunner, well clear of the turret's swing.
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.66, TAILGATE_Y + 0.10, TUB_TOP + 0.02),
                 (sx * 0.62, TAILGATE_Y + 0.10, CAGE_Z - 0.16), radius, SEG_TUBE,
                 mat=M_RUST)
    add_tube(bm, (-0.62, TAILGATE_Y + 0.10, CAGE_Z - 0.16),
             (0.62, TAILGATE_Y + 0.10, CAGE_Z - 0.16), radius, SEG_TUBE, mat=M_RUST)

    if FINAL:
        # Lashed-on scrap plate over the cab roof, offset so it reads as salvage.
        add_box(bm, (0.10, -0.06, CAGE_Z + 0.05), (0.86, 0.52, 0.03), mat=M_RUST)
        for sx in (-1, 1):
            add_box(bm, (sx * 0.63, 0.10, CAGE_Z), (0.10, 0.09, 0.09), mat=M_STEEL)

    cleanup(bm)
    if FINAL:
        bevel(bm, 0.006, 1, 45.0)
        cleanup(bm)
    return finish(bm, "roll_cage", parent=parent, materials=mats, pivot=(0, 0, 0),
                  shade_smooth_angle=45.0)


# ---------------------------------------------------------------------------
# Greebles: the salvage that makes it post-apocalyptic rather than surplus
# ---------------------------------------------------------------------------


def build_greebles(mats, parent):
    bm = bmesh.new()

    # Spare wheel on the tailgate -- also the rearmost point of the vehicle.
    add_cyl(bm, (0, -1.72, 0.95), 0.40, 0.28, SEG_RING, axis='Y', mat=M_RUBBER)
    add_cyl(bm, (0, -1.72, 0.95), 0.24, 0.30, max(6, SEG_RING // 2), axis='Y',
            mat=M_GUN)
    add_box(bm, (0, -1.66, 0.95), (0.14, 0.20, 0.14), mat=M_STEEL)
    add_box(bm, (0, -1.84, 0.95), (0.10, 0.10, 0.10), mat=M_RUST)

    # Jerry cans on the left flank.
    for index, cy in enumerate((-0.62, -0.98)):
        add_box(bm, (-(TUB_HALF + 0.10), cy, TUB_TOP - 0.20),
                (0.16, 0.32, 0.44), mat=M_RUST if index else M_CHIP)
        add_box(bm, (-(TUB_HALF + 0.10), cy, TUB_TOP + 0.04),
                (0.08, 0.10, 0.06), mat=M_GUN)

    # Exhaust running down the right sill and out behind the rear wheel.
    add_tube(bm, (TUB_HALF - 0.06, 0.90, FRAME_Z0 + 0.02),
             (TUB_HALF - 0.02, -0.30, FRAME_Z0 - 0.02), 0.045, SEG_PIPE,
             mat=M_STEEL)
    add_tube(bm, (TUB_HALF - 0.02, -0.30, FRAME_Z0 - 0.02),
             (TUB_HALF + 0.04, -1.46, FRAME_Z0 + 0.10), 0.045, SEG_PIPE,
             mat=M_STEEL)
    add_cyl(bm, (TUB_HALF + 0.05, -1.56, FRAME_Z0 + 0.12), 0.065, 0.16, SEG_PIPE,
            axis='Y', mat=M_GUN)

    # Whip antenna -- the tallest point on the vehicle.
    add_tube(bm, (0.62, -1.48, TUB_TOP - 0.02), (0.64, -1.52, TOP_Z), 0.012,
             max(4, SEG_TUBE - 2), mat=M_GUN)
    add_box(bm, (0.62, -1.48, TUB_TOP + 0.02), (0.07, 0.07, 0.09), mat=M_STEEL)

    # Wing mirrors on stalks off the windshield frame.
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.66, COWL_Y + 0.02, TUB_TOP + 0.18),
                 (sx * 0.84, COWL_Y + 0.06, TUB_TOP + 0.26), 0.018, SEG_TUBE,
                 mat=M_GUN)
        add_box(bm, (sx * 0.86, COWL_Y + 0.06, TUB_TOP + 0.28),
                (0.05, 0.10, 0.15), mat=M_GUN)

    # Welded scrap armour over the door line and the hood flanks.
    for sx in (-1, 1):
        add_plate(bm, [(sx * (TUB_HALF + 0.01), 0.30, FLOOR_Z + 0.08),
                       (sx * (TUB_HALF + 0.01), -0.34, FLOOR_Z + 0.06),
                       (sx * (TUB_HALF + 0.01), -0.34, TUB_TOP - 0.02),
                       (sx * (TUB_HALF + 0.01), 0.30, TUB_TOP - 0.04)],
                  sx * 0.022, mat=M_RUST)
    add_box(bm, (0, HOOD_Y1 - 0.34, HOOD_Z + 0.02), (0.74, 0.36, 0.03),
            mat=M_RUST)

    if FINAL:
        # Rivets along the armour plates, and small salvage on the bed. Four a side
        # at four segments each: at this size they are a shading cue, and the rest
        # of the rivet line is painted in by the normal map.
        for sx in (-1, 1):
            for index in range(4):
                add_cyl(bm, (sx * (TUB_HALF + 0.035), 0.20 - index * 0.16,
                             FLOOR_Z + 0.10), 0.014, 0.02, 4, axis='X',
                        mat=M_STEEL)
        add_box(bm, (-0.30, -1.44, FLOOR_Z + 0.14), (0.22, 0.16, 0.28),
                mat=M_STEEL)
        add_cyl(bm, (0.30, 0.94, HOOD_Z + 0.06), 0.09, 0.12, SEG_PIPE, axis='Y',
                mat=M_GUN)
        # Winch on the bull bar.
        add_cyl(bm, (0, LEN_FRONT - 0.22, FLOOR_Z + 0.16), 0.09, 0.34, SEG_PIPE,
                axis='X', mat=M_GUN)
        for sx in (-1, 1):
            add_box(bm, (sx * 0.19, LEN_FRONT - 0.22, FLOOR_Z + 0.16),
                    (0.04, 0.20, 0.20), mat=M_STEEL)

    # Tail lights.
    for sx in (-1, 1):
        add_box(bm, (sx * 0.56, TAILGATE_Y - 0.02, TUB_TOP - 0.16),
                (0.12, 0.06, 0.10), mat=M_LIGHT)

    cleanup(bm)
    # No bevel on the greebles. They are salvage -- jerry cans, rivets, a muffler --
    # at a size where a 7 mm bevel is under a pixel at gameplay range, and there are
    # enough separate pieces here that bevelling them all cost more than the body.
    return finish(bm, "greebles", parent=parent, materials=mats, pivot=(0, 0, 0),
                  shade_smooth_angle=35.0)


# ---------------------------------------------------------------------------
# Wheels
# ---------------------------------------------------------------------------


def build_wheel(mats, parent, name, hub):
    bm = bmesh.new()
    x, y, z = hub

    # The carcass carries almost the whole radius and the tread is a shallow band
    # sitting on top of it. Deep isolated lugs read as a cog rather than a tyre --
    # a real off-road tread is a shallow pattern on a round casing, and the depth
    # belongs in the normal map.
    core_w = WHEEL_W * 0.66
    shoulder_w = (WHEEL_W - core_w) * 0.5
    add_cyl(bm, (x, y, z), WHEEL_R * 0.955, core_w, SEG_WHEEL, axis='X',
            mat=M_RUBBER)
    # Tapered shoulders, so the tyre reads as a round casing in profile instead of
    # a flat-sided disc. create_cone puts radius1 on the -X end once it is aimed
    # down X, so the two sides take their radii in opposite order.
    for sx in (-1, 1):
        centre_x = x + sx * (core_w + shoulder_w) * 0.5
        outer, inner = WHEEL_R * 0.80, WHEEL_R * 0.955
        add_cyl(bm, (centre_x, y, z),
                outer if sx < 0 else inner, shoulder_w, SEG_WHEEL, axis='X',
                radius_top=inner if sx < 0 else outer, mat=M_RUBBER)
    add_cyl(bm, (x, y, z), WHEEL_R * 0.62, WHEEL_W + 0.012, SEG_WHEEL, axis='X',
            mat=M_STEEL)
    add_cyl(bm, (x, y, z), WHEEL_R * 0.26, WHEEL_W + 0.03, max(6, SEG_WHEEL // 2),
            axis='X', mat=M_GUN)

    # Lug pattern on the rim face.
    for index in range(5):
        angle = index * (2 * math.pi / 5)
        add_cyl(bm, (x + (0.02 if x < 0 else -0.02) + WHEEL_W * 0.5 * (1 if x > 0 else -1),
                     y + math.cos(angle) * WHEEL_R * 0.40,
                     z + math.sin(angle) * WHEEL_R * 0.40),
                0.028, 0.03, 6, axis='X', mat=M_CHROME)

    # Tread: a near-continuous band of shallow staggered blocks following the
    # casing, sized so the run of them closes into a circle. `ring` is solved so
    # the block *corners* land on WHEEL_R rather than the block faces -- otherwise
    # the tyre sits proud of its own radius and the contact patch misses Z=0.
    blocks = SEG_WHEEL if FINAL else SEG_WHEEL // 2
    thickness = WHEEL_R * 0.055
    tangential = (2 * math.pi * WHEEL_R / blocks) * 0.86
    ring = math.sqrt(WHEEL_R ** 2 - (tangential * 0.5) ** 2) - thickness * 0.5
    for index in range(blocks):
        angle = index * (2 * math.pi / blocks)
        direction = (0.0, math.cos(angle), math.sin(angle))
        stagger = 1 if index % 2 else -1
        add_box_dir(bm, (x + stagger * WHEEL_W * 0.14,
                         y + direction[1] * ring, z + direction[2] * ring),
                    (WHEEL_W * 0.60, tangential, thickness), direction,
                    mat=M_RUBBER)

    cleanup(bm)
    # No bevel pass on the wheels. Four instances make every edge cost four times,
    # and rubber has no highlight worth catching -- the tread's own edges already
    # break up the silhouette.
    return finish(bm, name, parent=parent, materials=mats, pivot=hub,
                  shade_smooth_angle=40.0)


# ---------------------------------------------------------------------------
# Turret
# ---------------------------------------------------------------------------


def build_turret_base(mats, parent, pivot):
    bm = bmesh.new()
    x, y = 0.0, TURRET_Y

    # Pedestal from the bed floor up to the ring.
    add_cyl(bm, (x, y, (FLOOR_Z + RING_Z - 0.06) / 2), 0.13,
            RING_Z - 0.06 - FLOOR_Z, SEG_PIPE, mat=M_GUN)
    add_cyl(bm, (x, y, FLOOR_Z + 0.03), 0.26, 0.06, SEG_PIPE, mat=M_STEEL)
    # Traverse ring.
    add_cyl(bm, (x, y, RING_Z - 0.03), 0.30, 0.07, SEG_RING, mat=M_STEEL)
    add_cyl(bm, (x, y, RING_Z + 0.01), 0.24, 0.05, SEG_RING, mat=M_GUN)
    # Pintle post up to the trunnion.
    add_cyl(bm, (x, y, (RING_Z + PITCH_Z) / 2), 0.055, PITCH_Z - RING_Z, SEG_PIPE,
            mat=M_GUN)
    # Trunnion yoke arms the gun pivots between.
    for sx in (-1, 1):
        add_box(bm, (sx * 0.085, y, PITCH_Z - 0.02), (0.04, 0.12, 0.20),
                mat=M_STEEL)
    # Ammunition box bracket hanging off the ring.
    add_box(bm, (0.30, y - 0.06, RING_Z + 0.06), (0.10, 0.24, 0.14), mat=M_STEEL)

    if FINAL:
        for index in range(8):
            angle = index * (2 * math.pi / 8)
            add_box(bm, (x + math.cos(angle) * 0.285, y + math.sin(angle) * 0.285,
                         RING_Z - 0.03), (0.035, 0.035, 0.085), mat=M_RUST)

    cleanup(bm)
    if FINAL:
        bevel(bm, 0.006, 1, 45.0)
        cleanup(bm)
    return finish(bm, "turret_base", parent=parent, materials=mats, pivot=pivot,
                  shade_smooth_angle=40.0)


def build_turret_gun(mats, parent, pivot):
    bm = bmesh.new()
    z = PITCH_Z

    # Receiver.
    add_box(bm, (0, -0.95, z), (0.13, 0.50, 0.15), mat=M_GUN)
    add_box(bm, (0, -0.72, z + 0.09), (0.10, 0.16, 0.05), mat=M_GUN)
    # Barrel jacket, then the exposed barrel.
    add_cyl(bm, (0, -0.40, z), 0.055, 0.60, SEG_PIPE, axis='Y', mat=M_GUN)
    add_cyl(bm, (0, 0.02, z), 0.028, 0.30, SEG_PIPE, axis='Y', mat=M_GUN)
    # Muzzle brake.
    add_cyl(bm, (0, 0.22, z), 0.045, 0.12, SEG_PIPE, axis='Y', mat=M_STEEL)

    # Spade grips and trigger, behind the receiver where the gunner stands.
    add_box(bm, (0, -1.24, z), (0.12, 0.10, 0.13), mat=M_GUN)
    for sx in (-1, 1):
        add_tube(bm, (sx * 0.06, -1.24, z - 0.03), (sx * 0.15, -1.30, z - 0.14),
                 0.020, SEG_TUBE, mat=M_GUN)
        add_cyl(bm, (sx * 0.15, -1.30, z - 0.17), 0.026, 0.10, SEG_PIPE,
                mat=M_LEATHER)
    add_box(bm, (0, -1.28, z - 0.09), (0.05, 0.05, 0.07), mat=M_CHROME)

    # Rear sight.
    add_box(bm, (0, -1.14, z + 0.11), (0.05, 0.03, 0.07), mat=M_GUN)
    add_box(bm, (0, -0.16, z + 0.07), (0.02, 0.03, 0.05), mat=M_GUN)

    # Ammunition box and the belt feeding into the receiver.
    add_box(bm, (0.20, -1.00, z - 0.14), (0.16, 0.30, 0.20), mat=M_CANVAS)
    links = 7 if FINAL else 4
    for index in range(links):
        t = index / (links - 1)
        add_box(bm, (0.20 - t * 0.12, -1.00 + t * 0.06, z - 0.05 + t * 0.045),
                (0.05, 0.035, 0.02), mat=M_CHROME)

    if FINAL:
        # Cooling slots on the jacket, cut as shallow boxes rather than booleans --
        # the depth reads in the normal map and booleans here would cost a fortune.
        for index in range(8):
            angle = index * (2 * math.pi / 8)
            add_box(bm, (math.cos(angle) * 0.055, -0.40, z + math.sin(angle) * 0.055),
                    (0.018, 0.42, 0.018), mat=M_STEEL)

    cleanup(bm)
    if FINAL:
        bevel(bm, 0.005, 1, 45.0)
        cleanup(bm)
    return finish(bm, "turret_gun", parent=parent, materials=mats, pivot=pivot,
                  shade_smooth_angle=40.0)


def build_turret_shield(mats, parent, pivot):
    bm = bmesh.new()
    y = -0.52
    z = PITCH_Z
    # Everything here is relative to the trunnion, so raising the turret carries the
    # shield with it instead of leaving it stranded at an old absolute height.
    # Built from four plates around a central barrel gap rather than one plate with
    # a boolean hole: same silhouette, a fraction of the triangles, no ngons.
    add_box(bm, (0, y, z + 0.23), (0.62, 0.035, 0.30), mat=M_RUST)
    add_box(bm, (0, y, z - 0.16), (0.62, 0.035, 0.16), mat=M_RUST)
    for sx in (-1, 1):
        add_box(bm, (sx * 0.245, y, z), (0.13, 0.035, 0.16), mat=M_RUST)
    # Folded side wings, angled back.
    for sx in (-1, 1):
        # Kept planar: the top and bottom edges share a z, so the quad lies in one
        # plane and extrude_face_region has a normal it can trust. A skewed quad
        # here extrudes along an averaged normal and throws geometry off-model.
        add_plate(bm, [(sx * 0.31, y - 0.01, z - 0.26),
                       (sx * 0.31, y - 0.01, z + 0.35),
                       (sx * 0.42, y - 0.16, z + 0.35),
                       (sx * 0.42, y - 0.16, z - 0.26)],
                  sx * 0.03, mat=M_RUST)
    # Vision slit hood over the top edge -- the tallest point on the turret.
    add_box(bm, (0, y - 0.05, z + 0.36), (0.62, 0.12, 0.035), mat=M_STEEL)

    cleanup(bm)
    if FINAL:
        bevel(bm, 0.006, 1, 45.0)
        cleanup(bm)
    return finish(bm, "turret_shield", parent=parent, materials=mats, pivot=pivot,
                  shade_smooth_angle=35.0)


def build_steering_wheel(mats, parent, pivot):
    bm = bmesh.new()
    x, y, z = pivot
    radius = 0.165
    # Rim built from chords around the tilted plane, so the rake is in the geometry
    # and the pivot Empty above stays identity.
    segments = 16 if FINAL else 10
    points = []
    for index in range(segments):
        angle = index * (2 * math.pi / segments)
        local = Vector((math.cos(angle) * radius, 0.0, math.sin(angle) * radius))
        tilted = Vector((local.x,
                         local.z * math.sin(STEER_TILT),
                         local.z * math.cos(STEER_TILT)))
        points.append(Vector((x, y, z)) + tilted)
    for index in range(segments):
        add_tube(bm, tuple(points[index]), tuple(points[(index + 1) % segments]),
                 0.019, 5, mat=M_LEATHER, cap=False)
    for index in range(3):
        angle = index * (2 * math.pi / 3) + 0.4
        local = Vector((math.cos(angle) * radius * 0.92, 0.0,
                        math.sin(angle) * radius * 0.92))
        tilted = Vector((local.x, local.z * math.sin(STEER_TILT),
                         local.z * math.cos(STEER_TILT)))
        add_tube(bm, (x, y, z), tuple(Vector((x, y, z)) + tilted), 0.014, 5,
                 mat=M_GUN)
    add_cyl(bm, (x, y, z), 0.045, 0.05, SEG_PIPE, axis='Y', mat=M_GUN)

    cleanup(bm)
    # NOT "steering_wheel". Godot's importer runs with nodes/use_node_type_suffixes
    # on, and a node name ending in "wheel" is its suffix for VehicleWheel3D -- the
    # mesh imported as a physics node named "steering", which only works parented to
    # a VehicleBody3D. The same mechanism is what makes -convcolonly work, so it
    # cannot be turned off; the name just has to end in something else.
    return finish(bm, "steering_wheel_rim", parent=parent, materials=mats,
                  pivot=pivot, shade_smooth_angle=45.0)


# ---------------------------------------------------------------------------
# Collision proxies
# ---------------------------------------------------------------------------


def build_collision(parent):
    """Convex hulls, one object per Godot collision node.

    `-convcolonly` rather than `-convcol`: the proxy should generate a shape and
    not be drawn. Godot's importer turns each into a StaticBody3D; the vehicle
    prefab reuses the generated ConvexPolygonShape3D under its own body.
    """
    proxies = {
        "body-convcolonly": [((0, -0.42, 0.80), (1.46, 2.40, 0.62))],
        "hood-convcolonly": [((0, 1.12, 0.80), (1.40, 1.14, 0.52))],
        "cage-convcolonly": [((0, -0.10, (TUB_TOP + CAGE_Z) / 2 + 0.06),
                              (1.32, 1.10, CAGE_Z - TUB_TOP + 0.10))],
        # Capped at the shield top: a proxy taller than the visible turret would
        # become the model's measured height and blow the spec's 2.1 m.
        "turret-convcolonly": [((0, -0.88, (RING_Z - 0.06 + SHIELD_TOP) / 2),
                                (0.70, 0.90, SHIELD_TOP - RING_Z + 0.06))],
    }
    for sx, side in ((-1, "l"), (1, "r")):
        for axle_y, track, tag in ((AXLE_F, TRACK_F, "f"), (AXLE_R, TRACK_R, "r")):
            # Exactly one diameter tall: the proxy is what the vehicle rests on, so
            # anything larger would park the jeep with its wheels in the ground.
            proxies[f"wheel_{tag}{side}-convcolonly"] = [
                ((sx * track, axle_y, HUB_Z), (WHEEL_W + 0.04, WHEEL_R * 2.0,
                                               WHEEL_R * 2.0))]

    created = []
    for name, boxes in proxies.items():
        bm = bmesh.new()
        for center, size in boxes:
            add_box(bm, center, size)
        cleanup(bm)
        obj = finish(bm, name, parent=parent, pivot=(0, 0, 0))
        obj.display_type = 'WIRE'
        obj.hide_render = True
        created.append(obj)
    return created


# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------


def build(detail="final", material_factory=None):
    """material_factory, when given, is surfacing.build_all -- the procedural
    surfaces used for the bake. Without it the flat placeholder colours are used,
    which is what the blockout renders with. It is called after wipe_scene() so its
    materials are not collected as orphans."""
    _apply_detail(detail)
    wipe_scene()
    mats = material_factory(ZONES) if material_factory else build_materials()

    root = new_empty("jeep_turret_root", (0, 0, 0))

    build_body(mats, root)
    build_interior(mats, root)
    build_cage(mats, root)
    build_greebles(mats, root)

    steer_pivot = new_empty("steering_wheel_pivot", tuple(STEER_HUB), parent=root)
    build_steering_wheel(mats, steer_pivot, tuple(STEER_HUB))

    wheels = (("fl", -TRACK_F, AXLE_F, True), ("fr", TRACK_F, AXLE_F, True),
              ("rl", -TRACK_R, AXLE_R, False), ("rr", TRACK_R, AXLE_R, False))
    for tag, x, y, steers in wheels:
        hub = (x, y, HUB_Z)
        parent = root
        if steers:
            parent = new_empty(f"wheel_{tag}_steer", hub, parent=root)
        spin = new_empty(f"wheel_{tag}_spin", hub, parent=parent)
        build_wheel(mats, spin, f"wheel_{tag}", hub)

    yaw_pivot = (0.0, TURRET_Y, RING_Z)
    pitch_pivot = (0.0, PITCH_Y, PITCH_Z)
    yaw = new_empty("turret_yaw", yaw_pivot, parent=root, size=0.25)
    build_turret_base(mats, yaw, yaw_pivot)
    pitch = new_empty("turret_pitch", pitch_pivot, parent=yaw, size=0.20)
    build_turret_gun(mats, pitch, pitch_pivot)
    build_turret_shield(mats, pitch, pitch_pivot)

    collision_root = new_empty("collision", (0, 0, 0), parent=root)
    build_collision(collision_root)

    bpy.context.view_layer.update()
    return root
