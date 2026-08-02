# cargo_tether

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#).

A self-contained example inside a larger project. See `README.md` for what it does and the four
self-containment rules — the short version: paths are relative to the file that uses them,
`load()`/`ResourceSaver`/`FileAccess` go through the local `_res()` helper, anything that would be a
project setting is registered at runtime by a node in the scene that needs it
(`actors/ship/ship_input_actions.gd`), and an `@export` beats a project setting. Do not add anything
here that requires editing the host `project.godot`.

## Verification before declaring done

A `.gd` edit is not finished when it is written. It is finished when it parses and runs.

- The `PostToolUse` hook runs `tools/check_gd.ps1` on every edited `.gd` (Godot `--check-only` +
  `gdlint`). Fix what it reports before moving on.
- **The hook cannot see any of the traps below.** Those need a real run.
- Both suites, and the output pasted — do not infer success from "the file saved":
  ```
  godot --headless --path <root> --script res://examples/3d/cargo_tether/tools/verify_cargo_tether_static.gd
  godot --headless --path <root>         res://examples/3d/cargo_tether/tools/verify_cargo_tether_runtime.tscn
  ```
- Anything touching the spring, the winch or the masses must ALSO re-run the measurement harness and
  paste the numbers — the README quotes them, so they are not allowed to drift silently:
  ```
  godot --headless --path <root> res://examples/3d/cargo_tether/tools/measure_tether_response.tscn
  ```
- Anything touching the camera, the tether visual, materials or lighting must re-run the capture
  tool **and actually look at the PNGs**. Every physics assertion in this folder passes against a
  tether that renders as nothing at all.
  ```
  godot --path <godot project root> res://examples/3d/cargo_tether/tools/capture_sandbox.tscn
  ```
- Use the **`_console.exe`** build on Windows. **`C:\godot\godot.cmd` is not usable here**: it wraps
  the non-console binary and ends with `pause > nul`, so it hangs headless runs and detaches stdout.
- `gdformat` owns formatting and will rewrite most files you touch. Run it, then **re-run the
  harness** — and say explicitly whether anything else broke, not just the case you were fixing.

## Traps that no linter catches

Every one of these was hit while building this example. `gdlint` and `godot --check-only` report
nothing for any of them.

**A `.tscn` that assigns a Node-typed `@export` needs `node_paths=PackedStringArray(...)` on the
node header.** Without it Godot assigns the `NodePath` to the property, cannot resolve it because
the target is not in the tree yet, and leaves it **null with no error anywhere**. `TetherLink` then
bails out of `_physics_process` on its null check every frame, so the tether renders, reports and
does absolutely nothing. The only visible symptom is a separation of exactly `0.00` forever. The
generated jeep scene has this attribute; a hand-written scene will not unless you put it there.

**A new example's `class_name`s do not exist until the project is re-imported.** Adding
`class_name TetherLink` and immediately running the scene fails with `Could not find type
"TetherLink" in the current scope` for every file that refers to it, because the global script
class cache has not been rescanned. Run `godot --headless --path <root> --import` once after adding
any new `class_name`.

**`rest_length` is anchor-to-anchor, not centre-to-centre.** The ship's anchor sits 3.0 m behind its
origin and the cargo's 1.2 m ahead of its own, so the anchors are 4.2 m closer than the bodies.
Spawning the cargo `rest_length` behind the ship starts the line 4.2 m slack — which, because slack
is exactly zero force, means the tether applies nothing at all and never will until something else
pulls them apart. The sandbox spawns the cargo at **18.2 m** for a 14 m rest length, and
`measure_tether_response.gd` carries `ANCHOR_SPAN` for the same reason.

**A sleeping `RigidBody3D` silently ignores `apply_force()`.** In zero gravity with no input a
drifting body will sleep, and the tether stops existing until something wakes it. `can_sleep = false`
is set in both `.tscn` files *and* forced in `TetherLink._guard_sleep()`, because the failure mode is
"the tether works sometimes" and that is very expensive to chase.

**`Camera3D.fov` is VERTICAL, not horizontal** (`keep_aspect` defaults to `KEEP_HEIGHT`). An 88°
"wide" setting is about 120° horizontal at 16:9: the ship shrank to fifty pixels on a 22 m arm and
the speed ramp read as the camera running away. The lens ramps 60 → 78 vertical.

**A chase rig that sits on its target cannot be oriented by "look from here at the target".** That
direction degenerates to whatever tiny offset separates the rig from its own look point, and the
`SpringArm3D` then pushes the camera along it in whichever direction it happens to face — which
parked the camera in *front* of the ship looking back at its own nose. `_eye_point()` predicts where
the camera will land from the ship's own +Z first, and the orientation is solved from there.

**A `ProceduralSkyMaterial` draws a sun disk and scattering halo per `DirectionalLight3D`.** With a
sun and a fill light that painted two gradients and a visible diagonal seam across empty space, and
flattening the sky/ground colours did not remove it because the seam was the scattering. The
environment uses a flat colour background instead.

**Sky ambient against a near-black sky lights nothing.** `ambient_light_source = SKY` is the obvious
choice and it made every surface facing away from the sun pure black, so the ship was an unreadable
silhouette. Ambient is a `COLOR` source here, deliberately decoupled from the background.

**Writing a control target every frame means nothing else can ever drive it.** `ShipController` used
to set `tether.target_length = tether.rest_length` on every idle frame, which silently overwrote any
value a capture tool or verifier set on the next physics tick — the winch looked broken rather than
overridden. It now latches **on the release edge only**.

**A positive control needs a stationary target.** The projectile-damage control in
`capture_sandbox.gd` fired two rounds down a line computed once, while the cargo was still coasting
at 116 m/s — the second shot was aimed 29 m behind it, and the control reported half the expected
damage as though the game were broken. It now resets the run first. The general shape: a control
that shares state with the thing it is testing is not a control.

**"Cargo arrived at 100%" and "the weapons do not work" are the same output.** So is "the MultiMesh
draws nothing" and "you did not look at the right part of the screen" — the first tracer capture
photographed rounds fired at the crate, which trails *behind the camera*. Both now have explicit
controls: rounds fired, and a burst crossing the view ahead of the ship.

**`Vector3.slerp` asserts its rotation axis is unit length, and a physics-driven basis is not.**
`global_basis.y` drifts off unit length by a part in a thousand within seconds of the hull being
tumbled, and the camera then spammed `The axis Vector3 (...) must be normalized` every frame.
Normalising the *inputs* does not fix it — the complaint comes from inside the rotation. The rig
uses a normalised lerp instead, which has no axis-angle step at all; for a camera up vector the
easing difference is invisible.

**A controller can hide the thing you are trying to measure.** `[torque-yank]` measured 0.019 rad/s
and looked like a tether applying force centrally. It was measuring ShipController's attitude hold,
which commands zero body rate with more authority than the tether has. The check now runs the yank
twice, once with `rate_gain` zeroed — 1.55 rad/s free, 0.40 rad/s held. Both numbers are the
assertion: the first proves the force lands on the tail anchor, the second proves the pilot wins.

**Two of these systems are authority-limited, not gain-limited**, and a test that forgets it reads a
correct clamp as a failure. The dampener asks for 88 kN at 40 m/s and gets the 12 kN a lateral
thruster has, so it decelerates at a flat 12 m/s² and needs 3.3 s to stop from 40. The winch is the
same shape against its stall curve.

**Lambdas capture locals by value.** A signal handler that sets a flag must use a member variable or
a named method — `sig.connect(func() -> void: fired = true)` leaves the outer `fired` false forever.

**Nodes added during `SceneTree._initialize()` never receive `_ready()`.** Both tool scripts here are
`.tscn` wrappers for that reason. Running the `.gd` with `--script` reports nothing and exits 0,
which looks exactly like a pass.

**`add_to_group()` defaults to non-persistent** and **`connect()` without `Object.CONNECT_PERSIST` is
dropped by `PackedScene.pack()`.** Both bite the course generator, not the hand-authored scenes.

**`godot --check-only` exit codes are unreliable.** Analyzer errors print `Parse Error` and still
exit 0. Grep the output; `tools/check_gd.ps1` already does.

## Component boundaries

- **`TetherLink` is the only file that applies a tether force.** One node computes one force and
  applies `+F` and `-F`, so Newton's third law holds by construction rather than by two files
  agreeing on a sign. A sign error split across two files produces a cargo that trails perfectly
  while the ship flies as if it were empty — which reads as "the tether works".
- **`ShipController` is the only file that reads input.** It owns the mouse, `Input.mouse_mode`, the
  `ui_cancel` release and every `ship_*` action including the winch pair. That is what lets the
  tether be driven programmatically with no player, no camera and no HUD in the scene.
- **`TetherWinch` has no engine dependencies at all.** It is pure maths, like `JeepSurfaces`, so the
  solver, the HUD and the verifier read the same stall curve instead of three files spelling `0.12`.
- **`TetherLink` reads no input and `TetherWinch` names no node.** Assert these by grepping source,
  including comments: a file that should not touch input should not document it either.

## Project-specific invariants

- **`scenes/cargo_run.tscn` is GENERATED.** Edit `tools/build_cargo_run.gd` and re-run it. The
  layout is seeded (`COURSE_SEED`) so regenerating gives a clean diff rather than noise.
  `scenes/tether_sandbox.tscn` is hand-authored and is the faster place to test a change.
- **A difficulty feature has to be built, not permitted.** The generator's first chokepoints worked
  by narrowing the *allowed* rock radius near three points and scattering at random — which at this
  density changed nothing, because the nearest rock to the spine was already 20 m away almost
  everywhere. Measured minimum clearance: 19.6 m against a nominal 9 m gate. Gates are now explicit
  rings. If you add a hazard by relaxing a constraint, measure whether anything actually filled it.

- **The rate limit in `TetherWinch.step()` is the spring's stability guarantee**, not a comfort
  feature. Nothing may write `rest_length` directly. At the shipped rate the worst single-step change
  is 0.10 m, which is 680 N — 1.7% of break tension. A mouse wheel writing `rest_length` would be a
  step input into a stiff spring, which is how these detonate.
- **We cannot raise the physics tick rate to stabilise anything.** That is a project setting and rule
  3 forbids touching `project.godot`. `TetherLink._guard_stiffness()` clamps `spring_k` against
  `Engine.physics_ticks_per_second` read at runtime instead, so a 30 Hz host degrades rather than
  explodes. Treat any `spring_k` above ~15 000 as needing a re-measurement.
- **`max_overshoot` is absolute, not a fraction of the rest length.** A rope breaks at a *tension*,
  and with a constant spring rate an absolute overshoot is exactly a break tension. Relative would
  make a short winch setting unbreakable, which is an exploit the winch finds within a minute.
- **The `maxf(tension, 0.0)` clamp is load-bearing.** Closing fast at low stretch makes the damping
  term negative and larger than the spring term, and an unclamped rope *pushes* — which reads to a
  player as the crate bouncing off an invisible wall.
- **The 0.6 cargo:ship mass ratio is the design.** Change it before you change `spring_k`, and change
  thrust last of all — thrust also sets the pendulum period (`omega = sqrt(a / L)`), so it moves two
  feelings at once.
- **Numbers in `README.md` are measured, not chosen.** If you retune anything, re-run the harness and
  update them, or delete them. A quoted number that no longer holds is worse than no number.

## Style

Tabs (width 4), LF. `class_name` then `extends` at the top. Typed `@export`/`@onready` with explicit
`: Type` and `-> void` returns. `%UniqueName` access over `$Path`. Member order: `class_name` →
`extends` → signals → enums → consts → exports → public → private → onready. Lines under 100
characters; `gdformat` owns the rest and will reflow what you write.
