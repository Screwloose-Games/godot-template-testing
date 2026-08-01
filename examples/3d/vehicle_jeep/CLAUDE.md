# vehicle_jeep

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#).

A self-contained example inside a larger project. See `README.md` for what it does and the four
self-containment rules — the short version: paths are relative to the file that uses them,
`load()`/`ResourceSaver`/`FileAccess` go through the local `_res()` helper, anything that would be a
project setting is registered at runtime by a node in the scene that needs it
(`actors/jeep/jeep_input_actions.gd`), and an `@export` beats reading a project setting. Do not add
anything here that requires editing the host `project.godot`.

## Verification before declaring done

A `.gd` edit is not finished when it is written. It is finished when it parses and runs.

- The `PostToolUse` hook runs `tools/check_gd.ps1` on every edited `.gd` (Godot `--check-only` +
  `gdlint`). Fix what it reports before moving on.
- **The hook cannot see any of the traps below.** Those need a real run.
- Anything touching scenes, physics or the rig needs both suites, and the output pasted — do not
  infer success from "the file saved":
  ```
  godot --headless --path <godot project root> --script res://examples/3d/vehicle_jeep/tools/verify_jeep_static.gd
  godot --headless --path <godot project root>        res://examples/3d/vehicle_jeep/tools/verify_jeep_runtime.tscn
  ```
- Use the **`_console.exe`** build on Windows. **`C:\godot\godot.cmd` is not usable here**: it wraps
  the non-console binary and ends with `pause > nul`, so it hangs headless runs and detaches stdout.
- `gdformat` owns formatting and will rewrite most files you touch. Run it, then **re-run both
  suites** — and say explicitly whether anything else broke, not just the case you were fixing.

## Traps that no linter catches

Every one of these was hit while building this example. `gdlint` and `godot --check-only` report
nothing for any of them.

**Nodes added during `SceneTree._initialize()` never receive `_ready()`.** The collision harvest
happens in `_ready()`, so the first version of `verify_jeep_static.gd` reported "adopted no hull
collision, 8 static proxies remain" against a jeep that was completely correct — it was measuring the
harness. Everything in that verifier runs on the first `_process()` tick instead.

**A `uid` beats a path, and the model's uid is not the container scene's.**
`uid://bssqwg5tkirgv` belongs to `sm_jeep_turret.gltf`; the container `.tscn` beside it has no uid at
all. Writing that uid into `jeep_visuals.tscn` silently loaded the raw glTF: same meshes, same wheel
pivots, no `mk_*` markers. Reference the container scene by path only.

**Godot's importer strips `-convcolonly`.** The eight proxies arrive named `body` / `cage` / `hood` /
`turret` / `wheel_fl..rr` — which means the wheel proxies share names with the wheel *meshes*, and
`find_child("wheel_fl")` returns the `StaticBody3D`, not the `MeshInstance3D`. Look them up by path.

**`ResourceSaver.FLAG_RELATIVE_PATHS` does nothing to text scenes in 4.7.1.** Verified by saving the
same `PackedScene` with and without it and diffing: both absolute. `build_proving_ground.gd` rewrites
the paths itself afterwards. (`String.path_to_file()` is also not bound in GDScript, so the relative
path is computed by hand.)

**`add_to_group(name)` defaults to non-persistent**, so the group never reaches the `.tscn` and every
surface patch loads as tarmac with no error anywhere.

**`connect()` without `Object.CONNECT_PERSIST` is dropped by `PackedScene.pack()`.** Symptom: a
turret that never moves.

**`engine_force` pushes toward the body's +Z**, i.e. backwards. See
`JeepController.FORWARD_ENGINE_SIGN`.

**Wheel node positions are overwritten from the first physics frame.** The authored rest Y is only
readable in `_ready()`, and nothing exposes current suspension compression, so the HUD's readout has
exactly one possible source.

**Lambdas capture locals by value.** A signal handler that sets a flag must use a member variable or
a named method — `sig.connect(func() -> void: fired = true)` leaves the outer `fired` false forever.

**`owner` can only be set once the node shares a tree with the owner.** When building a scene
programmatically, `add_child()` the parent first, then set `owner` on descendants; for instanced
sub-scenes set `owner` on the **instance root only**, which is what preserves the instance link.

**`godot --check-only` exit codes are unreliable.** Analyzer errors print `Parse Error` and still
exit 0. Grep the output; `tools/check_gd.ps1` already does.

**Nonexistent methods and invalid properties on native classes are not checked at all.** Verify API
surface against the docs or `mcp__godot-ai__api_manage`, or against a real run.

## Component boundaries

`jeep_visuals.gd` is the **only** file in this example allowed to name a node inside
`sm_jeep_turret.tscn` — `wheel_fl_steer`, `turret_yaw`, `steering_wheel_pivot`, `mk_*`,
`jeep_turret_root`, `collision`. `jeep_controller.gd` talks to it through the facade
(`take_body_shapes`, `set_wheel_pose`, `set_steering_normalized`, `aim_turret`, `set_headlights`,
`debug_state`) and `verify_jeep_static.gd` check 9 greps the controller's source, **comments
included**, to enforce it: a file that should not touch a model node should not document one either.

- **Assert the boundary by grepping source, not by inspecting the tree.** A literal
  `get_node("jeep_turret_root/turret_yaw")` is invisible to any amount of node inspection.
- **Owning the vocabulary means owning the tuning.** Turret slew rates and headlight settings are
  exported on `JeepVisuals`, not passed in per call, for the same reason `JeepSurfaces` is read by
  both the solver and the HUD: two files spelling `0.14` independently is how a readout stops
  describing the game.
- **One deliberate hop is allowed.** `verify_jeep_runtime.gd` reaches `%Visuals` directly. That is
  intended and greppable — what is forbidden is reaching *through* the jeep to a model node.
- **`%Visuals` must stay at identity.** Wheel poses arrive in body space and are written onto model
  pivots; a pitch, roll or scale there would tilt every wheel by a constant nothing would flag. Model
  offsets go on a pivot *inside* `jeep_visuals.tscn`. Asserted by check 5.
- **Positive controls before negative assertions.** "No `StaticBody3D` remains under the jeep" passes
  beautifully against a model that never had any, which is why check 3 counts the proxies first.

## Project-specific invariants

- **`scenes/proving_ground.tscn` is GENERATED.** Edit `tools/build_proving_ground.gd` and re-run it.
  The rubble field is seeded (`RUBBLE_SEED`) so regenerating gives a clean diff rather than noise.
  `jeep.tscn` and `jeep_visuals.tscn` are hand-authored.
- **`jeep.tscn` deliberately contains no `CollisionShape3D`.** The hulls are adopted at runtime from
  the model. If you add one by hand, `verify_jeep_static.gd` check 4 will fail on the count.
- **Two numbers in `jeep.tscn` are derived, not chosen**, and check 6 recomputes both:
  `wheel_radius = 0.4173` (measured off the mesh) and wheel node
  `y = 0.4173 + wheel_rest_length − target_gravity/(4·suspension_stiffness)`.
- **`center_of_mass` must stay pinned and low.** On `AUTO`, hulls spanning y 0.49 → 2.14 put it near
  y = 1.1 and the jeep rolls over in the first corner — a symptom that reads as a steering problem.
  Check 7 guards it.
- **Grip numbers are not free parameters.** A tyre only slips once the engine asks for more than the
  surface can pass, and that threshold is far below intuition: at `wheel_friction_slip` 3.5 the mud
  run measured 100% of the tarmac distance. If you retune `max_engine_force` or the base slip, re-run
  `[mud]` and `[ice]` — they are the only things that will tell you the surfaces still matter.
- **`RPM_SIGN` and `FORWARD_ENGINE_SIGN` are calibration constants, each pinned by a test.** If a
  future engine release flips a convention, flip the constant; do not rewrite the geometry around it.
- **Directions are asserted, not eyeballed.** Wheel roll direction (`spin_deltas` must be negative
  driving forward) and steering-rim direction (its top must reach x ≈ −1 at half-lock left) are both
  derivable, so both are in `[visual-rig]`. Do not replace them with "looks right in the editor".

## Style

Tabs (width 4), LF. `class_name` then `extends` at the top. Typed `@export`/`@onready` with explicit
`: Type` and `-> void` returns. `%UniqueName` access over `$Path`. Member order: `class_name` →
`extends` → signals → enums → consts → exports → public → private → onready. Lines under 100
characters; `gdformat` owns the rest and will reflow what you write.
