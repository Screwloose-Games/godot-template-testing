# exploration_quadraped

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#).

A self-contained example inside a larger project. See `README.md` for what it does, how to
run the tools, and the four self-containment rules — the short version: paths are relative
to the file that uses them, `load()`/`ResourceSaver`/`FileAccess` go through the local
`_res()` helper, anything that would be a project setting is registered at runtime by a
node in the scene that needs it (`actors/wolf/wolf_input_actions.gd`), and an `@export`
beats reading a project setting. Do not add anything here that requires editing the host
`project.godot`.

## Verification before declaring done

A `.gd` edit is not finished when it is written. It is finished when it parses and runs.

- The `PostToolUse` hook runs `tools/check_gd.ps1` on every edited `.gd` file
  (Godot `--check-only` + `gdlint`). If it reports problems, fix them before moving on.
- **The hook only catches parse, type, argument-count and naming errors.** It cannot
  see any of the traps listed below. Those need a real run.
- For anything touching scenes, physics or animation, run the relevant suite and paste
  the result — do not infer success from "the file saved":
  ```
  godot --headless --path <godot project root> --script res://examples/3d/exploration_quadraped/tools/verify_wolf_static.gd   # structure
  godot --headless --path <godot project root> res://examples/3d/exploration_quadraped/tools/verify_wolf_dynamic.tscn          # speed calibration
  godot --headless --path <godot project root> res://examples/3d/exploration_quadraped/tools/verify_wolf_runtime.tscn          # movement/jump/slopes
  ```
- Use the **`_console.exe`** Godot build on Windows. The plain binary detaches stdout and
  error lines vanish silently.
- After a fix, re-run the full suite, not just the case that failed, and say explicitly
  whether anything else broke.

## GDScript traps that no linter catches

Every one of these was hit in this project and cost a debug cycle. `gdlint` and
`godot --check-only` report **nothing** for any of them — they are all valid GDScript
that behaves differently than it reads.

**Lambdas capture locals by value.** Writing to a captured local from inside a lambda
updates the closure's copy; the outer variable never changes. Signal handlers that set a
flag must use a **member variable** or a named method, never a captured local.
```gdscript
var fired: bool = false
sig.connect(func() -> void: fired = true)   # WRONG: outer `fired` stays false
```

**`owner` can only be set once the node shares a tree with the owner.** When building a
scene programmatically, `add_child()` the parent into the tree *first*, then set `owner`
on descendants. Setting `owner` on children of a node that is not yet in the tree fails
silently and `PackedScene.pack()` then drops them. For instanced sub-scenes set `owner`
on the **instance root only** — that is what preserves the instance link.

**`SceneTree._initialize()` runs before the root is in the tree.** `global_transform`
returns identity and `AnimationPlayer.seek()` cannot resolve track targets. Do that work
on the first `_process()` tick instead.

**`godot --check-only` exit codes are unreliable.** Parser errors exit 1, but *analyzer*
errors (type mismatch, wrong argument count) print `Parse Error` and still exit **0**.
Grep the output; never trust the exit code. `tools/check_gd.ps1` already does this.

**Nonexistent methods and invalid properties on native classes are not checked at all** —
`node.totally_fake_method()` and `light.sdfgi_enabled = true` both compile clean and fail
at runtime. Verify API surface against the docs or `mcp__godot-ai__api_manage`.

**Measure peak, not final, when testing traversal.** A wolf that climbs a 2 m platform and
walks off the far side ends at ground level, so a final-height assertion reports failure on
a successful climb.

**`CharacterBody3D` has no built-in step climbing.** A 0.2 m box edge is a vertical wall
that `move_and_slide()` slides along. See `WolfController._try_step_up()`.

## Component boundaries

A scene owns its internals. Nothing outside a component may name a node inside it, a
`parameters/…` path, or an animation state name. Callers describe *what is happening*; the
component decides what that looks like.

- **Scene-unique names do not cross a scene boundary.** `%Foo` resolves against a node's
  `owner`, not by walking the tree — so a `%Name` authored in `foo.tscn` is registered on
  `foo.tscn`'s root and **also resolves from outside it**. Putting the subtree in its own
  scene is the only thing that makes the outside lookup return null. That is what turns this
  section from a convention into an enforced rule. (Verified on 4.7.1, not assumed.)
- **One deliberate hop is still allowed.** A caller holding the component *can* reach inside
  it. That is intended — it is how the rig verifiers work — but it must be explicit and
  greppable, never a reach *through* the host.
- **`wolf.tscn` contains no animation.** The 180° `ModelPivot`, the GLB instance and the
  `AnimationTree` live in `actors/wolf/wolf_animator.tscn`, instanced as `%Animator`.
  `WolfController` drives it only through `update_ground()`, `enter_ground()`, `enter_air()`
  and `enter_fall()`.
- **Owning a subsystem means owning its vocabulary.** `AnimationTree.set()` on a parameter
  path that does not exist does nothing and reports nothing, so two files spelling the same
  path independently is a silent-failure generator: renaming a state machine node fixes one
  and breaks the other. This is why `GAIT_RATE_MIN` is public on `WolfAnimator` — three
  private copies of `0.35` is how a calibration test stops testing what the game does.
- **Assert the boundary by grepping the source, not by inspecting the tree.** Node-shape
  checks are trivially bypassed by a literal `get_node("ModelPivot/Model/AnimationTree")`,
  and no scene inspection catches a `parameters/…` string. `verify_wolf_static.gd` check 9
  scans `wolf_controller.gd` for the vocabulary — **comments included**, because the
  controller should not even document the mixer.
- **Order negative assertions after positive controls.** "`%AnimationTree` is unreachable
  from `Wolf`" passes vacuously if the component was renamed. Check that `%Animator` resolves
  *and* that `%AnimationTree` resolves from inside it first.
- **A component's transform relative to its host is part of its contract.** `WolfAnimator`
  caches its root-motion correction against *itself*, and callers read the result as the
  body's frame. A yaw is harmless (the readout takes a horizontal magnitude); a pitch, roll
  or scale tips baked forward motion onto Y, which the readout zeroes — so `measured_speed()`
  would silently *under-report* foot slip and the calibration test would stop testing.
  `%Animator` must stay at identity; model offsets go on `%ModelPivot`, inside it.
- **Tools split by what they are testing.** Testing the rig → instantiate
  `wolf_animator.tscn` directly and use `%AnimationTree` inside it
  (`verify_wolf_static`, `verify_wolf_dynamic`, `measure_paw_contact`). Needing the whole
  wolf in a world → fetch `%Animator` and use the facade only (`verify_wolf_runtime`,
  `capture_wolf_shots`).
- **Gait *names* are animation; gait *speeds* are locomotion.** `WolfGaitLadder` is pure
  maths with no engine deps, so both sides use it: the controller for
  `fastest_speed()` (turn-rate scaling), the animator for `ground_animation_params()`,
  `slowest_speed()` and `dominant_gait_name()`. `gait_changed` is emitted by the animator and
  relayed by the controller, so gameplay consumers talk to the actor.

## Project-specific invariants

- **Never add a `_subresources/animations` entry to `grey-wolf-gaits-and-jump.glb.import`.**
  Touching any animation's subresource dict makes `settings/loop_mode` apply with its
  default of `0` (None), silently un-looping the gait clips — the wolf takes one step and
  freezes. `verify_wolf_static.gd` assertion 5 guards this.
- **Animation names carry no `-loop` suffix.** The glTF importer strips it and renames the
  clip, so `walk-loop` in the source arrives as `walk`.
- **`root_motion_track` is the bare node path**, `wolf_rig/grey_wolf`, with no `:position`
  subname. The `:Hips` form in Godot's docs is for skeleton bones and never matches a
  `Node3D` track. It is what stops the wolf sliding.
- **`blend_position` is not the current speed.** Under `SYNC_MODE_CYCLIC_MUTABLE` it must go
  through `WolfGaitLadder.blend_position_for_speed()`; at 3.42 m/s the value is 3.573.
- **Blend points must stay bare `AnimationNodeAnimation`.** Cyclic sync's `_check_can_sync()`
  rejects nested nodes, so wrapping one in a `TimeScale` silently disables phase locking.
- `wolf_animation_tree.tres` and `demo_world.tscn` are **generated**. Edit the builders in
  `tools/`, never the output. `wolf.tscn` and `wolf_animator.tscn` are **hand-authored** —
  building them programmatically would walk straight into the `owner` trap above, since the
  `AnimationTree` is parented *inside* an instanced sub-scene.
- **`demo_world.tscn` does not need regenerating when `wolf.tscn` gains or loses a child.**
  It instances the wolf and never descends inside, so structural changes propagate. Only a
  change to the `Wolf` root's own exported properties needs a rebuild — regenerating
  needlessly churns `unique_id` on ~30 unrelated nodes.
- The wolf model faces **+Z** (Godot's backward), hence the 180° `%ModelPivot` — which lives
  in `wolf_animator.tscn`, not `wolf.tscn`.

## Style

Tabs (width 4), LF. `class_name` then `extends` at the top. Typed `@export`/`@onready` with
explicit `: Type` and `-> void` returns. `%UniqueName` access over `$Path`. Member order:
`class_name` → `extends` → signals → enums → consts → exports → public → private → onready.
Keep lines under 100 characters (`gdlint` enforces this).
