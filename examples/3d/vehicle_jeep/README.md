# Jeep — VehicleBody3D + terrain that you can feel

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#)

A drivable `sm_jeep_turret` on a proving ground built to make the physics legible: graded ramps,
a washboard, square steps, a rubble field, and mud and ice that visibly take grip away. The wheel
meshes, the steering rim and the turret are all driven from the live physics state, so what the art
does and what the solver does cannot drift apart.

Open `scenes/proving_ground.tscn` and press **F6**. This folder is a self-contained example inside a
bigger project, so it does not claim the project's main scene, and it needs no edit to
`project.godot` — the input actions register themselves at runtime (see
[Self-containment](#self-containment)).

## Controls

| Input | Action |
|---|---|
| `W` `S` / arrows | throttle, reverse (holding the opposite of travel brakes first) |
| `A` `D` / arrows | steer — lock tapers from 32° to 11° as speed rises |
| `Space` | handbrake — **rear wheels only**, which is what makes the ice circle fun |
| mouse | orbit the camera *and* aim the turret at whatever is under the crosshair |
| `L` | headlights |
| `R` | flip upright where you stand |
| `T` | respawn at the spawn point |
| `H` | toggle the debug readout |
| `Esc` | release the mouse |

## The course

Four lanes radiate from the spawn apron at the origin. Every number below was printed by
`tools/build_proving_ground.gd`, and every outcome measured by `tools/verify_jeep_runtime.tscn`.

**Lane A — ramps, straight ahead (−Z).** 10° / 20° / 30° / 40°, at x = −24 / −8 / +8 / +24. Each is
a single box rotated about +X and sunk until the near lip of its top face sits exactly on y = 0, so
crest height works out to `length × sin(angle)`: 1.74 / 3.42 / 5.00 / 6.43 m. All four are
approached from the same line (near lip at z = −18).

Measured, with the 12 m run-up the course gives you: 10° summits (peak +1.90 m), 30° summits
(+5.31 m), 40° does not (+3.97 m of a 6.43 m crest). Sustained gradeability is engine-limited around
30° — 8.8 kN of drive against the 12.6 kN that gravity asks for on the 40 — so what gets you up the
30 is partly momentum. That is also how a player meets them, which is why the test measures
summiting rather than pretending the approach is a standing start.

A **mud apron** sits on the run-up to the 20° ramp. Crossing it kills your run-up speed, which is
the point.

**Lane B — broken ground, right (+X).** Six cylinders laid across the direction of travel, 0.18 m
proud and 2.2 m apart: a washboard that loads all four suspensions at speed. Then square steps of
0.15 / 0.30 / 0.45 / 0.75 m. Then 36 seeded, half-buried, randomly tilted rubble blocks.

The steps are the interesting ones, because what stops the jeep is **not** the wheel radius. A
raycast vehicle's wheels have no lateral collision — they are rays that apply suspension force — so
a square edge does not block anything by being taller than the 0.417 m wheel. It blocks by fouling
the **hull**, whose underside sits at y = 0.49. Measured: the jeep drives clean over 0.15, 0.30 and
0.45 m, and high-centres on 0.75 m (1.33 m travelled of the 6.00 m needed). An earlier version of
this course topped out at 0.50 m and the jeep sailed over it, rising only 0.22 m on the way.

**Lane C — grip, left (−X).** A 3.6 m mud lane and a 3.6 m ice lane laid edge to edge, joining at
x = −32.10. The track is 1.56 m, so straddling the join puts the **left wheels on mud and the right
on ice in the same frame** — the case a chassis-mounted `Area3D` cannot express at all. Plus a
radius-9 ice circle for handbrake donuts, and a 12 × 12 mud pit to get stuck in.

Measured: a 3 s standing start covers 25.50 m on tarmac and 15.95 m on mud — 63%. On ice, mean
`get_skidinfo()` under full throttle is 0.268, where 1.0 is full grip.

## How it works

### The model already had the rig

`assets/3d/vehicles/jeep_turret/sm_jeep_turret.tscn` ships separate `wheel_*_steer` / `wheel_*_spin`
pivots, a `turret_yaw` → `turret_pitch` chain, a raked `steering_wheel_pivot`, eight convex collision
proxies and eight `Marker3D` attachment points. Nothing here re-models any of that; the example is
the consumer the container scene's own header comment asks for.

### Collision is harvested at runtime, not extracted to disk

The `-convcolonly` proxies import as `StaticBody3D` nodes, and static bodies riding inside a moving
`VehicleBody3D` are a contradiction — the four wheel proxies would sit exactly where the wheel rays
are cast. So `JeepVisuals.take_body_shapes()` copies the four hull shapes onto the body, then
destroys the container.

Two gates, because one is not enough. The name predicate skips anything called `wheel_*`; the
geometry gate rejects any hull reaching below y = 0.30, since every real hull proxy starts at
y ≥ 0.49 and every wheel proxy reaches y = 0.00. A `.tres` extract was rejected for the usual
reason: it would go stale the day the model is re-exported and nothing anywhere would say so.

`free()`, not `queue_free()` — a deferred free leaves the proxies alive for the rest of the frame,
and a physics step landing in that window is the bug.

### The wheel meshes are driven, never reparented

`VehicleWheel3D` must be a direct child of the body, and the model's pivots live inside an instanced
sub-scene, so the two hierarchies stay separate and state is copied every physics frame. Only the
**origin** of `wheel.transform` is taken — it already carries suspension travel — and the basis is
rebuilt from two scalars, because the engine's own wheel basis is a mirror (determinant −1) and
whether that is compensated is exactly the sort of thing that compiles clean and looks wrong.

Roll has no exposed angle, so it is integrated from `get_rpm()`. Two signs are involved and they are
handled differently: the geometric one is derivable (a positive rotation about +X carries the contact
patch forward, which is a wheel rolling *backwards*, so driving forward must decrease the angle),
while `get_rpm()`'s own convention is not — measured, it returns **−474.5 while driving forward at
+20.63 m/s**, hence `JeepVisuals.RPM_SIGN = -1.0`.

### One mouse, two consumers

The camera orbits with the mouse, and the turret slews toward the point under the crosshair — the rig
casts a ray from the camera through screen centre and emits the hit as `aim_point_changed`. Three
things make that read as one control rather than two fighting:

- the camera is instantaneous and the turret is rate-limited, so the gun trails the look, which reads
  as a heavy weapon rather than as lag;
- aiming at the hit *point* rather than parallel to the camera removes parallax by construction — the
  turret sits 1.24 m above and 0.95 m behind the optical axis, so a parallel gun misses up close;
- looking backwards over the hull is just a large yaw error, so there are no special cases.

The jeep knows nothing about any camera. That is not decoration: `verify_jeep_runtime` deletes the
camera rig entirely and still aims the turret.

### Grip

Per wheel, via `get_contact_body()` and node groups, so two wheels can be on mud while two are on
ice. Only `wheel_friction_slip` is modulated — it is the traction coefficient, which is what mud and
ice actually reduce. `wheel_roll_influence` is an anti-roll-bar knob affecting how much the body
*leans*, not how much the tyre *slides*, so touching it here would be a category error.

The numbers matter more than they look. A tyre only lets go once the engine asks for more than the
surface can pass, and that threshold is far lower than intuition suggests. At the authored base of
3.5 the mud run covered **100%** of the tarmac distance; at base 1.0 with mud at 0.28, still 100%.
The shipped values (base 1.0, mud 0.14, ice 0.06, against 2200 N per traction wheel) are where the
difference actually reaches the solver.

## Layout

```
actors/jeep/
  jeep.tscn              VehicleBody3D + 4 wheels + %Visuals + the input registrar.
                         Contains NO collision shapes -- they are adopted at runtime.
  jeep_controller.gd     input, engine, brakes, per-wheel surfaces, respawn. Names no model node.
  jeep_visuals.tscn      the model instance + two headlights
  jeep_visuals.gd        the visual facade -- owns every model node name in the example
  jeep_surfaces.gd       grip/drag tables. No engine deps, read by both physics and HUD.
  jeep_input_actions.gd  registers `jeep_*` actions at runtime, so project.godot needs no edit
components/camera/       chase rig; a SIBLING of the jeep, and the source of the turret's aim point
ui/jeep_hud.tscn|.gd     20 Hz debug readout + crosshair
scenes/proving_ground.tscn  GENERATED -- edit the builder, not this
tools/                   diagnostics, the generator, and the two verification suites
```

Two numbers in `jeep.tscn` are derived rather than chosen, and `verify_jeep_static.gd` recomputes
both so they cannot drift apart silently:

- `wheel_radius = 0.4173`, measured off the wheel mesh by `tools/dump_jeep_model.gd`, not the spec
  sheet's rounded 0.42.
- wheel node `y = 0.5673` = `0.4173 + wheel_rest_length − g/(4·stiffness)`. The engine hangs the
  wheel centre below the node by the suspension length, so getting this wrong makes the art float or
  sink. Mass cancels out, so retuning mass does not move it. Measured settled wheel centres: 0.4108
  front, 0.4241 rear.

`center_of_mass` is the highest-risk number here. The adopted hulls span y 0.49 → 2.14 on a 1.55 m
track; left on `AUTO` the centre lands near y = 1.1 and the jeep rolls over on the first hard corner
— a symptom that reads as bad steering tuning and sends you off to retune the wrong thing. It is
pinned to (0, 0.35, 0.05) and asserted statically.

## Self-containment

Same four rules as `examples/3d/exploration_quadraped`, in the order to reach for them:

1. **Paths are relative to the file that uses them.** Note that `ResourceSaver` will not do this for
   you: `FLAG_RELATIVE_PATHS` is a documented flag that has **no effect** on text scenes in 4.7.1 —
   verified by saving the same `PackedScene` with and without it and diffing, both absolute. So
   `build_proving_ground.gd` rewrites the paths itself, on the text, after saving.
2. **`load()`, `ResourceSaver` and `FileAccess` need real `res://` paths**, so every tool resolves
   them through a local `_res()` helper.
3. **Project settings become nodes.** `jeep_input_actions.gd` registers the actions at runtime,
   skipping any the host already defines and erasing only what it created. Every action is prefixed
   `jeep_`, unlike the wolf's bare names — this repo already contains a wolf that owns
   `move_forward`, and a host whose `jump` silently became the handbrake is an hour of debugging.
4. **An `@export` beats a project setting.** `target_gravity` is 14 m/s² (arcade; the whole
   suspension tune derives from it) and is applied by calibrating `gravity_scale` against the world's
   real gravity on the first physics tick — measured 1.429 here — so the jeep handles identically in
   a host project whose gravity is anything at all.

**Known deviation, deliberate:** the model itself lives outside this folder, at
`assets/3d/vehicles/jeep_turret/`. Copying ~16 MB of PNGs into an examples folder in a web-first repo
is not a trade worth making. It is referenced from exactly one file, `jeep_visuals.tscn`, so
relocating the example is a one-path edit — and `verify_jeep_static.gd` checks 1 and 2 fail
immediately if it breaks.

## Tools

All take `--path <godot project root>`: the folder holding `project.godot`, not this example folder.
Use the **`_console.exe`** build on Windows. In particular **do not use `C:\godot\godot.cmd`** — it
wraps the non-console binary and ends with `pause > nul`, so it hangs headless runs and swallows
every error line.

```bash
G=Godot_v4.7.1-stable_win64_console.exe

# Diagnostic. Run this FIRST if the model is ever re-exported: node paths, the class the
# importer decided each node is, and every collision proxy's root-space AABB.
$G --headless --path <root> --script res://examples/3d/vehicle_jeep/tools/dump_jeep_model.gd

# Regenerate the proving ground (prints the ramp/step/grip table the docs quote)
$G --headless --path <root> --script res://examples/3d/vehicle_jeep/tools/build_proving_ground.gd

# Verification
$G --headless --path <root> --script res://examples/3d/vehicle_jeep/tools/verify_jeep_static.gd
$G --headless --path <root>        res://examples/3d/vehicle_jeep/tools/verify_jeep_runtime.tscn
```

`verify_jeep_static.gd` is ten structural checks: the model dependency resolves, every driven pivot
exists *with its expected class*, the collision harvest actually happened, `%Visuals` is at identity,
the wheel geometry recomputes, the centre of mass is pinned, the generated scene's groups and signal
connection survived packing, and the component boundary holds.

`verify_jeep_runtime.tscn` drives the real course and measures behaviour rather than reading
properties back: distance on mud versus tarmac, two wheels reporting mud while two report ice in one
frame, peak height on each ramp, whether each step was crossed. Both the wheel-spin direction and the
steering-wheel direction are asserted, not left to be eyeballed — the rim's top must end up at
x = −1.0 under half-lock left, and every wheel's roll increment must be negative while driving
forward.

## Gotchas

**Do not add `uid="uid://bssqwg5tkirgv"` to the model reference in `jeep_visuals.tscn`.** That uid
belongs to `sm_jeep_turret.gltf`, not to the container scene beside it, which has no uid of its own.
Godot resolves uid before path, so writing it there silently loads the raw glTF instead: same meshes,
same wheel pivots, but none of the container scene's `mk_*` markers, and `JeepVisuals._ready()` then
dies on a null steering axis. This is how the first version of that file failed.

**Nodes added during `SceneTree._initialize()` never receive `_ready()`.** The jeep's whole collision
harvest happens in `_ready()`, so a structural check written in `_initialize()` reports "adopted no
hull collision, 8 static proxies remain" against a completely correct jeep. `verify_jeep_static.gd`
runs everything on the first `_process()` tick for exactly this reason.

**`engine_force` is positive toward the body's +Z**, which is backwards. Driving forward needs a
negative engine force (`JeepController.FORWARD_ENGINE_SIGN`). Getting it wrong is not cosmetic: the
reverse/brake logic reads forward speed, so a jeep accelerating backwards under throttle immediately
decides it should brake, and the result is a vehicle that oscillates at walking pace.

**`add_to_group()` defaults to non-persistent.** Without `persistent = true` the group is never
written into the `.tscn` and every low-grip patch silently loads as tarmac.

**`connect()` without `Object.CONNECT_PERSIST` is dropped by `PackedScene.pack()`.** The only symptom
is a turret that never moves.

**Suspension compression has no getter.** The authored wheel Y is only readable *before* the first
physics frame — the engine rewrites the node position every step — so the HUD's readout depends on
caching it in `_ready()`.

## Known trade-offs

- **The mud/ice `DRAG` term only bites while coasting.** Godot's wheel solver takes the braking
  branch only when `engine_force` is zero, so drag does nothing under throttle: raising mud's drag to
  6.0 changed the measured mud distance by 0.02 m. Grip is the only lever that works while
  accelerating; drag is what makes mud feel sticky when you lift.
- **`turret-convcolonly` does not follow the turret.** It hangs off `collision`, not `turret_yaw`, so
  it is the turret's *rest* volume. A fully traversed turret has collision pointing forward.
- **The headlight lenses do not brighten with the beam.** The glow is an emissive material inside the
  imported glTF, shared with the tail lights, so fixing it would need an override that also changes
  the tail lights.
- **A steep ramp is a visibly floating plank.** The wedge is a rotated box, so at 40° there is a 5.5 m
  gap under its high end. Honest for a greybox; the wolf example's 55° ramp has the same property.
- **The top of a ramp is a cliff.** That is what `T` is for.
- **`continuous_cd` is off**, for the web frame budget. It is the first thing to try if a wheel ever
  tunnels a thin plate.

Not implemented, and listed as extensions rather than gaps: firing the turret (it aims only), physics
interpolation, engine audio, tyre-mark decals. A second jeep needs `collision_mask = 1|2` on both and
nothing else.
