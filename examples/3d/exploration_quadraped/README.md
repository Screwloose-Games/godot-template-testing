# Grey Wolf — AnimationTree + Character Controller

Godot 4.7 · GL Compatibility renderer · Jolt Physics

A player-controlled quadruped built on `grey-wolf-gaits-and-jump.glb`, with a speed-indexed
gait ladder (walk → amble → pace → trot → canter → gallop) that stays phase-locked and
foot-planted at every speed.

Open `scenes/demo_world.tscn` and press **F6** to run it. This folder is a self-contained
example inside a larger project, so it does not claim the project's main scene, and it
needs no edit to `project.godot`: every path in it is relative to the file that uses it,
and the input actions register themselves at runtime (see [Self-containment](#self-containment)).

## Controls

| Input | Action |
|---|---|
| `W` `A` `S` `D` / arrows | move (camera-relative) |
| mouse | orbit camera |
| `Shift` | sprint — gallop, 4.64 m/s |
| `Alt` | walk — 0.55 m/s |
| *(no modifier)* | cruise — trot, 1.76 m/s |
| `Space` | jump |
| `Esc` | release the mouse |

## How it works

Every gait clip in the GLB has forward root motion baked into its `wolf_rig/grey_wolf`
position track: stride `D` metres over clip length `L` seconds. That makes each gait a known
ground speed `v = D / L`, and those six speeds are strictly monotonic, so the blend space is
indexed directly in metres per second.

| gait | `L` | `D` | `v = D/L` |
|---|---|---|---|
| walk | 1.00 s | 0.55 m | 0.550 m/s |
| amble | 0.72 s | 0.70 m | 0.972 m/s |
| pace | 0.58 s | 0.85 m | 1.466 m/s |
| trot | 0.54 s | 0.95 m | 1.759 m/s |
| canter | 0.56 s | 1.40 m | 2.500 m/s |
| gallop | 0.42 s | 1.95 m | 4.643 m/s |

Three things are worth knowing before changing any of it.

**The model is not skinned.** `skins: 0` — it is 38 separate meshes parented into a joint
hierarchy, animated via node transforms. There is no `Skeleton3D`, so bone mapping and
retargeting do not apply; the tree blends plain `Node3D` transform tracks.

**`root_motion_track` is what stops the wolf sliding.** Designating
`wolf_rig/grey_wolf` as the root motion track makes the mixer *not* write that track to the
node, so it holds its rest transform, and accumulate it for retrieval instead. Movement is
code-driven, so the accumulated value is only used for the debug readout
(`WolfAnimator.measured_speed()`) — but the suppression is load-bearing. If that path ever
stops matching exactly, the wolf creeps forward and snaps back once per gait cycle.
Note it is the bare node path: **no `:position` suffix** (the `:Hips` form in Godot's docs is
for skeleton bones and will never match a `Node3D` track).

**The wolf model faces +Z**, which is Godot's *backward*, so `%ModelPivot` is yawed 180°
(inside `wolf_animator.tscn`). The real fix is re-exporting facing −Z, which would delete the
pivot and a whole class of sign bug.

### Where the boundary is

`wolf.tscn` is three nodes: the body, its capsule, and `%Animator`. Everything about how the
wolf *looks* — the model, the pivot, the `AnimationTree` and its whole `parameters/…`
namespace — lives inside `wolf_animator.tscn` and is unreachable from the wolf:
`wolf.get_node("%AnimationTree")` returns `null`, because scene-unique names resolve against
a node's owner and do not descend into an instanced sub-scene. `WolfController` talks to it
through `update_ground()`, `enter_ground()`, `enter_air()` and `enter_fall()`, and names no
clip, state or parameter path. `verify_wolf_static.gd` check 9 enforces that by grepping the
controller's source, comments included. See "Component boundaries" in `CLAUDE.md`.

### Phase locking and the speed correction

The blend space uses `SYNC_MODE_CYCLIC_MUTABLE`, which scales each point's delta by
`L_i / T` where `T = Σ wᵢ·Lᵢ`. Every clip's normalised phase then advances at `delta / T`,
identically — so the ladder is phase-locked permanently rather than drifting, which is what
would otherwise cause foot-contact ghosting between clips of 1.00 s and 0.42 s.

The cost is that produced speed becomes `s = (Σ wᵢ·Dᵢ) / (Σ wᵢ·Lᵢ)` — blended stride over
blended cycle. That is physically exact but is a *ratio of blends*, not a blend of ratios, so
it no longer equals `blend_position`. Left uncorrected it means up to 4.5% foot slip
mid-blend. `WolfGaitLadder.blend_position_for_speed()` inverts the relation in closed form, so
the ladder is phase-locked *and* speed-exact at once — measured at 0.00% error across the
whole range (see the calibration sweep below).

Because of this, `blend_position` is **not** simply the current speed. At 3.42 m/s the correct
blend position is 3.573.

### Jump

`jump` is a single 0.75 s clip covering takeoff, air and landing. Rather than slicing it,
airtime is computed at takeoff (`2·v/g`, exactly 0.75 s with `gravity = 20` and
`jump_velocity = 7.5`) and `parameters/Airborne/AirRate/scale` fits the clip to it. Known
limitation: an unbounded fall longer than the scaled clip holds the landing pose.

Slicing was rejected because Godot's `_create_slices` keeps absolute track values and only
rebases time, so a looped air slice's Z track would run 0.40→0.90 instead of 0→0.50 and jerk
backward 0.5 m every cycle. Fixing that needs a post-import `import_script`.

## Layout

```
actors/wolf/
  wolf.tscn                  CharacterBody3D + capsule + %Animator. Contains no animation.
  wolf_controller.gd         movement, turning, jump, step-up. Names no clip or parameter.
  wolf_input_actions.gd      registers the actions the controller reads, so project.godot needs no edit
  wolf_animator.tscn         180-degree ModelPivot + the GLB + the AnimationTree
  wolf_animator.gd           the animation facade -- owns the whole parameter namespace
  wolf_gait_ladder.gd        the speed <-> blend_position maths (no engine deps, unit-testable)
  wolf_animation_tree.tres   GENERATED -- edit the builder, not this
components/camera/           orbit rig; a SIBLING of the wolf, so it does not spin with the body
scenes/demo_world.tscn       GENERATED -- ramps 10/25/40/55 deg, 0.2 m + 0.4 m steps, a wall
assets/models/wolf/          the GLB and its import settings
tools/                       build + verification scripts
```

## Self-containment

This folder is a demo dropped into a host project, so everything it needs lives inside it.
Four rules, in the order to reach for them:

1. **Paths are relative to the file that uses them.** `.tscn` / `.tres` `ext_resource`
   entries and `preload()` both resolve relative to the file being loaded, so
   `path="wolf_animator.tscn"` and `preload("../actors/wolf/wolf_gait_ladder.gd")` keep
   working wherever the folder is moved. Note the Godot editor rewrites `ext_resource`
   paths back to absolute `res://` form whenever it re-saves a scene.
2. **`load()`, `ResourceSaver` and `FileAccess` do not do that** — they need a real
   `res://` path. The tool scripts keep the relative literal and resolve it through a
   local `_res()` helper built from `get_script().resource_path.get_base_dir()`.
3. **Project settings become nodes.** Anything that would otherwise live in
   `project.godot` is registered at runtime by a node inside the scene that needs it, and
   unregistered on the way out. `actors/wolf/wolf_input_actions.gd` does this for the
   seven input actions: it skips any action the host project already defines, and erases
   only the ones it created. That is why `verify_wolf_runtime.tscn` passes on a project
   whose input map is empty.
4. **Prefer an export over a project setting.** `WolfController.gravity` is an
   `@export`, not a read of `physics/3d/default_gravity`, so the jump arc does not depend
   on the host's physics config.

`tools/setup_project_settings.gd` still exists for baking the bindings into `project.godot`
permanently, but nothing requires it, and it repoints the host project's main scene.

## Tools

All take `--path <godot project root>`: the folder holding `project.godot`, which is the
host project this demo was dropped into, not this example folder. Use the
**`_console.exe`** build on Windows — the plain binary detaches stdout and error lines
vanish.

```bash
# Regenerate the AnimationTree (after editing the gait ladder)
godot --headless --script res://examples/3d/exploration_quadraped/tools/build_wolf_animation_tree.gd
# Regenerate the demo world
godot --headless --script res://examples/3d/exploration_quadraped/tools/build_demo_world.gd
# Input map, main scene, layer names, Jolt settings
godot --headless --script res://examples/3d/exploration_quadraped/tools/setup_project_settings.gd

# Verification
godot --headless --script res://examples/3d/exploration_quadraped/tools/verify_wolf_static.gd    # 8 structural assertions
godot --headless res://examples/3d/exploration_quadraped/tools/verify_wolf_dynamic.tscn          # speed calibration sweep
godot --headless res://examples/3d/exploration_quadraped/tools/verify_wolf_runtime.tscn          # end-to-end: movement, jump, slopes

# Diagnostics
godot --headless --script res://examples/3d/exploration_quadraped/tools/dump_glb_info.gd         # node paths, clip names, loop modes
godot --headless --script res://examples/3d/exploration_quadraped/tools/measure_paw_contact.gd   # paw height vs ground
godot --resolution 1280x720 res://examples/3d/exploration_quadraped/tools/capture_wolf_shots.tscn  # renders PNGs to user://wolf_shots
```

`verify_wolf_dynamic.tscn` is the highest-value test: it drives `WolfAnimator.update_ground()`
— the exact call the game makes every physics frame — and measures the root motion that
results, so it catches ladder arithmetic errors, root-motion loop-wrap spikes, cyclic sync
misbehaving, and discontinuities at the four speed-band joins. It instantiates
`wolf_animator.tscn` alone: no body, no collision, no physics.

`verify_wolf_static.gd` runs checks 1–8 against `wolf_animator.tscn` and check 9 against
`wolf.tscn`, asserting the rig did not leak back out.

## Gotchas

**Do not add a `_subresources/animations` entry to `grey-wolf-gaits-and-jump.glb.import`.**
Touching any animation's subresource dict makes `settings/loop_mode` apply with its default of
`0` (None), silently un-looping the gait clips. The symptom is a wolf that takes one step and
freezes. If you must add one, also write `"settings/loop_mode": 1` for every looping clip.
`verify_wolf_static.gd` assertion 5 is the permanent guard.

**Animation names have no `-loop` suffix.** The glTF importer detects the suffix, sets
`LOOP_LINEAR`, and *renames* the clip — `walk-loop` in the source file arrives as `walk`.

**Blend points must stay bare `AnimationNodeAnimation`.** Cyclic sync's `_check_can_sync()`
rejects nested nodes, so wrapping a point in a `TimeScale` would silently disable phase
locking. That is why `GaitRate` sits *outside* the blend space.

## Known trade-offs

- **`pace` and `trot` have incompatible footfall patterns** (lateral vs diagonal couplets) at
  overlapping speeds, so blending them produces a gait no real quadruped performs and can read
  as a limp. Blend points are named, so dropping it is one line in the builder:
  `space.remove_blend_point(space.find_blend_point_by_name(&"pace"))`. This is the first thing
  to try if the mid-range looks wrong.
- **`canter → gallop` spans 2.50 → 4.64 m/s**, an 86% jump and the widest segment in the
  ladder. Biasing `sprint_speed` to sit on gallop rather than mid-blend helps.
- **The collision capsule is vertical** (r 0.30, h 0.98), not body-length. A 2.2 m horizontal
  capsule sweeps as the wolf yaws and gets popped out of corridors. The cost is that the
  0.98 m capsule does not cover the 2.36 m body, so head and tail can clip walls. Fix by
  adding a *second* additive horizontal capsule, not by rotating this one.
- **Step-up is explicit**, in `WolfController._try_step_up()` — `CharacterBody3D` has no
  built-in step climbing, so a 0.2 m box edge is just a vertical wall. `max_step_height`
  defaults to 0.3 m.
