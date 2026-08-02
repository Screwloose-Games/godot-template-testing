# Procedural vehicle toolkit

Builds engine-ready vehicles in Blender from a Python description, bakes a texture
atlas, and exports a glTF that passes `.github/scripts/validate-model-files.py`
without a manual step anywhere in the chain.

Built while making `assets/art/3d/vehicles/jeep_turret` (14,720 tris, 1.900 × 2.140 ×
3.807 m, one 2048 atlas, 8 convex collision proxies, turret and wheel rig). This
document is the retrospective from that build: what was slow, what had to be
redone, and what is now automated so it does not have to be redone again.

---

## Making the next vehicle

Copy `models/jeep_turret.py` and change the constants and part functions. That file
is the only bespoke code — everything else is generic.

```python
import sys; sys.path.insert(0, "tools/blender-vehicle")
import build

build.blockout("my_truck", repo_root=".")   # ~4 s, renders 5 views for sign-off
build.produce("my_truck", repo_root=".")    # ~110 s, ships the asset
```

`blockout` builds the same geometry at lower segment counts with flat colours.
**Get the silhouette signed off before running `produce`** — `produce` spends
~90 seconds baking, and a rejected shape throws all of it away.

`produce` runs build → unwrap → surface → bake → audit → export → render → save,
and **stops on the audit rather than the export**. A model that fails the audit
never becomes a file, so a mistake costs one rebuild instead of an export, a
validator run, a Godot import and a round trip through the editor.

A model module needs a `SPEC` dict (target dimensions, poly budget, asset dir), a
`ZONES` list of material zones, and a `build(detail, material_factory)` function.

---

## What actually took time

Machine time is dominated by exactly one operation:

| Stage | Time |
|---|---|
| Geometry build (14.7k tris, ~90 primitive calls) | 0.3 s |
| UV unwrap + pack, 12 objects into one atlas | 0.7 s |
| glTF export | 0.4 s |
| Five beauty renders | ~3 s |
| **2048 atlas bake (5 passes)** | **90–110 s** |
| 256 test bake, same 5 passes | 3.4 s |

Everything except the bake is effectively free — a full `produce` with `skip_bake`
is 5.7 seconds. Two consequences worth internalising:

- **Iterate on geometry freely.** Rebuilding the whole vehicle costs less than
  moving a vertex by hand. There is no reason to patch geometry in place.
- **The bake is the only thing worth being careful about.** It ran three times at
  full resolution during this build; two of those were avoidable (see below).
  Prove the bake path at 256 first — it is 3.4 s and exercises every code path.

The rest of the elapsed time was *diagnosis*, not computation. The single most
expensive incident cost four diagnostic round trips and one wasted 93-second
re-bake, and the bug was a one-line environment leak.

---

## What had to be redone

| # | What went wrong | Root cause | What prevents it now |
|---|---|---|---|
| 1 | `SMOOTH_BY_ANGLE` modifier missing | Blender 4.1 removed auto-smooth; 5.x only offers a geometry-nodes asset | `primitives.mark_sharp()` writes sharp flags onto edges — no modifier, survives export as split normals |
| 2 | Fender flares read as slabs, and pushed width to 2.05 m against a 1.90 target | Built as axis-aligned boxes across the wheel top | `add_box_dir()` (oriented box) + flares placed off `HALF_W`, not off the track |
| 3 | Model sat 10 mm underground | Wheel collision proxy sized 2.05 × radius | `audit.ground_contact()` |
| 4 | Tread blocks poked outside the tyre radius | Axis-aligned boxes on a circle — corners escape | `add_box_dir()`, with the ring radius solved so block *corners* land on the radius |
| 5 | **Gun fired through the cab** | Trunnion at 1.46 m, below the windshield (1.56) and cage (1.70) | Clearance is now asserted in the model module's constants; the blockout checkpoint surfaces it visually |
| 6 | Raising the turret stranded the shield and left the turret proxy at 2.21 m — which silently became the model's *measured height* | Shield and proxy used hard-coded absolute Z | Both derive from `PITCH_Z`/`SHIELD_TOP`; `audit.collision_within_visual()` catches the class |
| 7 | Geometry thrown off-model by a shield wing | Non-planar quad — `extrude_face_region` pushes along an averaged normal | `add_plate()` raises on non-coplanar corners |
| 8 | Triangle budget: 33,560 → 16,924 → 16,040 → **14,720** (three tuning passes) | 2-segment bevels on everything; no per-part visibility | `audit.triangle_budget()` reports per-object counts against per-part lines |
| 9 | Normal map baked essentially flat | Bump node `Strength` is a **blend factor**, not a height — values of 0.03 do nothing | Documented below; `ZONE_SURFACES` now carries calibrated 0.13–0.70 values |
| 10 | Blamed AO noise, added denoising + a blur, re-baked (93 s wasted) | Misdiagnosis — see #11 | Measuring before changing anything |
| 11 | **Every render after the first bake was a 1-sample Cycles render** | `bake` sets `engine = CYCLES` and `samples = 1` and leaves them; the render helper only set EEVEE samples | `render.render()` pins the engine explicitly on every call |
| 12 | `steering_wheel` imported into Godot as a **VehicleWheel3D** | Godot's node-type suffixes match `_wheel` as well as `-wheel` | `audit.godot_name_suffixes()` |
| 13 | Godot kept serving a stale imported scene | `filesystem_manage(reimport)` marks the file; it does not rebuild the `.scn` | Use `scan`, then verify the `.scn` mtime moved |

Two patterns behind most of that list:

**Hard-coded absolute coordinates.** #6 was one change (raise the turret) breaking
three things that each independently knew where the turret was. Everything
downstream of a movable part must derive from that part's constant.

**Environment state leaking between stages.** #11 is the expensive one. The bake
mutates global scene state (`engine`, `samples`, `use_denoising`, bake settings)
and nothing restored it, so a later stage inherited settings that made correct data
look broken. Any stage that mutates global state must set what it needs rather than
inherit it. That is now true of `render.render()`.

Worth naming: **I diagnosed #11 by measuring instead of guessing.** After two wrong
theories, computing the high-frequency energy of all three textures showed only
2–7 % of texels above threshold — the maps were fine, so the problem had to be
render-side. One cheap measurement ended a hunt that two plausible-sounding
hypotheses had already extended by a 93-second re-bake.

---

## What the audit now catches

`audit.py` runs inside Blender before the export. Every check exists because this
build tripped over it.

| Check | Catches | Visible to the repo validator? |
|---|---|---|
| `identity_transforms` | Any rotation/scale on a node | Yes — but only after export |
| `no_child_meshes` | Mesh parented under a mesh | No |
| `godot_name_suffixes` | Names Godot reinterprets as node types | **No** — the glTF is valid; Godot reinterprets it |
| `collision_within_visual` | A proxy that becomes the model's declared size | **No** — it measures the file, so the proxy *is* the size |
| `ground_contact` | Model floating or sunk | **No** |
| `dimensions` | Bounds outside ±10 % of spec | Yes |
| `triangle_budget` | Total and per-part overruns | Total only |
| `uvs_in_unit_square` | UVs outside the tile | No |

The three "no" rows are the ones that matter most: they are failures the repo's own
gate cannot see, and each cost a full round trip through Godot to discover.

---

## Environment reference

Non-obvious behaviour confirmed by direct observation during this build.

### Blender 5.2

- **`SMOOTH_BY_ANGLE` is not a modifier.** Write `edge.smooth = False` on the bmesh.
- **Bump node `Strength` is a blend factor (0–1)**, mixing geometric and perturbed
  normals — not a height in metres. Values under ~0.1 bake to a flat normal map.
- **Cycles has no metallic bake pass.** Route the channel through an Emission node
  and bake `EMIT`. Doing base colour and roughness the same way gives one code path
  and exact, noise-free results at 1 sample — better than the `DIFFUSE`/`ROUGHNESS`
  passes, which carry sampling noise.
- **Baking mutates scene state** (`render.engine`, `cycles.samples`,
  `use_denoising`, `render.bake.*`) and does not restore it.
- **`smart_project` / `pack_islands` need a `VIEW_3D` context override** when called
  from a script.
- **Sample textures in object space, not UV space.** Atlas-packed UVs break a
  UV-space procedural at every island edge.
- **Don't let Blender set `matrix_parent_inverse`.** It is baked into the exported
  node transform. Compute local positions from world positions yourself.
- Delete cameras and lights *before* baking — they occlude the AO pass and ride
  along into the export.

### Godot 4.7

- **A single glTF root gets wrapped**, not promoted. `jeep_turret_root` became
  `sm_jeep_turret/jeep_turret_root`, so paths in an inherited scene need the prefix.
- **Node-type suffixes match `_name`, `-name` and `$name`.** Godot's `_teststr()`
  accepts all three, which is why `steering_wheel` became a `VehicleWheel3D`. The
  full list is in `audit.GODOT_NODE_SUFFIXES`. This cannot be disabled — it is the
  same mechanism that makes `-convcolonly` work.
- **`-convcolonly` produces `StaticBody3D` + `ConvexPolygonShape3D`.** A drivable
  vehicle wants a `VehicleBody3D`, so the prefab layer should reuse the generated
  shape resources under its own body.
- **`reimport` ≠ `scan`.** Only a full scan rebuilds the cached `.scn`.
- The editor's framing AABB includes gizmos and collision debug. For real geometry
  bounds, target only the visual meshes — or trust the validator.

### This repo

- A static asset (no skins, no animations) is checked by `gltf_transforms.py` **all
  the way down the mesh chain**, not just at scene roots. Any rotation > 0.5° or
  scale off 1.0 by > 1e-3 is a hard fail. Hence: pivots are Empties carrying
  translation only, and all rotation lives in the mesh data.
- Non-cardinal pivots (a raked steering column) cannot be expressed in the glTF at
  all. Put them in the container `.tscn` as a `Marker3D` and rotate about
  `marker.global_basis.z`. Do **not** reach for `allow_unapplied_transforms` — it
  disables the check for the entire model.
- Triangles are counted **per instance**. Four wheels cost four times; collision
  proxies count.
- `facing_direction` is INFO-only and can never fail — confirm it from a render.
- Spec keys are validated against `schemas/model-spec.schema.json` with
  `additionalProperties: false`; a typo'd key is a hard error, not a silent no-op.

---

## Still manual

- **Art direction.** Proportions, part layout and the material zone table are
  judgement, and the blockout checkpoint exists to get them wrong cheaply.
- **The container `.tscn`.** Hand-authored. Marker positions are derived from the
  model's Blender constants by hand — a generator that emitted markers from a dict
  in `SPEC` would close the last real gap, and is the obvious next thing to build.
- **The `.spec.yaml`.** Its numbers duplicate `SPEC`; it could be generated.
- **Godot `.import` sidecars.** Require the editor (or a headless import pass).
