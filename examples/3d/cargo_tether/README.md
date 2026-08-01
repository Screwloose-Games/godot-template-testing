# cargo_tether — towing a mass you cannot steer

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#)

You fly a ship with a crate on an elastic tether behind it. Every course change whips the crate
somewhere you did not ask for, and the thing you are protecting is the thing you cannot directly
control. The winch — reel in, pay out — is the lever you get: short and tucked in to thread a gap,
long and swinging wide to carry speed round a corner.

Open `scenes/cargo_run.tscn` and press **F6** — a 1456 m course through a seeded asteroid field,
past seven turrets and three chokepoint gates, to a delivery ring. `scenes/tether_sandbox.tscn` is
the smaller hand-authored corridor the mechanic was proven in, and is still the faster place to test
a change.

This folder is a self-contained example inside a bigger project, so it does not claim the project's
main scene and it needs no edit to `project.godot` — the input actions register themselves at
runtime.

## Controls

| Input | Action |
|---|---|
| `W` `S` | main engine, retro (retro is 45% of main — for corrections, not travel) |
| `A` `D` | strafe |
| `Space` `Ctrl` | vertical thrusters |
| `Q` `E` | roll — free; hold and you spin forever, you just do not keep spinning after you let go |
| mouse | pitch and yaw |
| `Shift` | boost — 3.2 s of tank, and the main way you snap the tether |
| **`R` `F`** | **winch in / out.** R sits above F, so "up shortens" is one finger without leaving WASD |
| mouse wheel | winch, in 1.5 m steps (see the note below on why this is not the primary binding) |
| `G` | release the cargo, or grab it again within 8 m at under 12 m/s |
| `Z` | toggle the inertial dampener (starts **off** — drifting is the fantasy) |
| `X` | hold to brake on all axes. The "stop, I need to think" button |
| `C` | hold to look back |
| `Backspace` | restart |
| `Esc` | release the mouse |

## What is built

A complete loop. Fly the sandbox corridor, thread eight asteroids past three turrets that lead their
shots, and fly *through* the delivery ring at the end for a time-and-integrity grade. `Backspace`
runs it again.

- **6DOF flight** with boost, a per-axis inertial dampener and an all-axis brake.
- **The tether**: elastic spring-damper, snapping, deliberate release and re-grab, and the winch.
- **Damage**: cargo integrity and ship hull, priced off measured impact speed, with contact i-frames.
- **Turrets**: closed-form lead solve, rate-limited slew, fire cone, line of sight, seeded spread.
- **Projectiles**: 96 pooled raycast shots drawn as one MultiMesh — a single draw call.
- **The run**: clock, dock, fail conditions, soft restart, score and grade.
- **The HUD**: integrity and tension bars, telemetry, result banner, and the off-screen cargo marker.

- **The course**: seeded generator, 1456 m spine curving in all three axes, 117 asteroids that drift
  and spin, three built chokepoint gates, seven emplacements, a starfield.

- **Verification**: nine structural checks and fifteen behavioural ones, plus a tuning harness and a
  screenshot tool.

## Verification

Two suites, both of which must pass before a change is done.

`verify_cargo_tether_static.gd` — nine structural checks: the mass ratio, the zero-g body settings,
the layer matrix against `TetherLayers`, the reserved-and-empty `PROJECTILE` bit, that every
Node-typed export resolves in both scenes, that nothing references this folder absolutely, and that
every `.gd` has its `.uid`.

`verify_cargo_tether_runtime.tscn` — fifteen behavioural blocks, driving the real `ShipController`
through `Input.action_press()` rather than poking its internals. Selected results:

```
[zero-g]      control fell 4.95 m; unpowered drift 0.0000 m
[tow-cost]    79.8 m towed of 126.7 m free -> 0.630
[slack]       tension 0.000 N, cargo moved 0.0000 m
[third-law]   cargo pulled the ship to 2.85 m/s sideways
[torque-yank] tether yaws the hull to 1.55 rad/s; the autopilot holds it to 0.40
[winch]       closed 13.61 m free, 1.94 m loaded (14%) -- stall curve holds
[dampener]    off: 40.00 m/s retained; on: 0.44 m/s remaining
[impact]      5 m/s cost 0.0, 45 m/s cost 77.2
[turret-lead] leads 18.3 deg ahead of the target, into its travel
```

Two rules the suite follows, both learned here. **Assert behaviour, never a property read-back** —
"rest_length is now 6" passes just as happily against a winch that writes the variable and moves
nothing. And **a negative assertion gets a positive control first** — `[zero-g]` proves the ship
*can* fall before proving it does not, because "nothing fell" passes beautifully against a ship
whose physics never ran.

The `[dampener]` line is the one worth reading twice: with it off, 40 m/s is retained *exactly*.
That is the proof the drift is genuinely Newtonian rather than lightly damped.

## The course

`scenes/cargo_run.tscn` is **generated**. Edit `tools/build_cargo_run.gd` and re-run it; hand edits
are lost. It is seeded (`COURSE_SEED`), so regenerating gives a clean diff rather than a page of
noise.

```
spine        1456 m, 7 control points, curving in x, y AND z
asteroids    90 scattered (r 3-11 m) + 27 in gate rings
clearance    min 8.3 m at a gate, mean 29.5 m
gates        t = 0.28 / 0.55 / 0.82, 9 m guaranteed aperture
turrets      7, standoff 34-58 m from the spine
par time     20.8 s (1456 m at 70 m/s)
```

**The generator refuses to emit an impossible course.** After placing the rocks it walks the spine
every 2 m and measures clearance to the nearest asteroid *surface*, minus the drift each rock is
allowed, and exits 1 if any sample is inside the guaranteed corridor. A generator that can quietly
produce a wall across the only route will, eventually, on the morning of a deadline.

**The chokepoints are built, not hoped for.** The first version narrowed the *permitted* radius near
each chokepoint and scattered rocks at random — which at this density put the nearest rock 20 m from
the spine almost everywhere and measured a minimum clearance of 19.6 m. The "chokepoints" did
nothing. A gate is a ring of nine rocks placed deliberately, leaving a 9 m aperture. That is where
the winch stops being optional: a crate on 26 m of line swings 30 m off the axis of travel.

**The asteroids drift analytically**, as a pure function of elapsed time and index rather than an
integrated velocity — so the field is deterministic, accumulates no drift over a four-minute run,
rewinds by assigning `_elapsed = 0`, and can be asserted at t = 12 s without simulating twelve
seconds. The motion is a bounded oscillation, so nothing ever leaves the course and the corridor
guarantee holds for the whole run rather than only at t = 0.

## Turrets

They are **terrain with a clock**. You have no weapon, so a turret is not an enemy to be beaten —
it is a hazard with a rhythm and a shadow, and you learn to route around it the way you route around
a rock. It is indestructible for the same reason a rock is.

The firing solution is a closed-form intercept — solve `|T + Vt − P| = st` for flight time — but the
solution is the easy part. Three things make it *fair*, and they matter more:

- **The slew limit** (70°/s). Change your velocity vector and the turret's aim is now wrong and takes
  time to correct. This is what makes juking work; without it a turret is a hitscan with no
  counterplay at all.
- **The fire cone** (4°). It only shoots when actually aligned, so a mid-slew turret visibly holds
  fire — that pause is the tell the player reads.
- **Seeded spread** (1.2°, rolled once per burst). Flying a straight line past a turret is
  survivable-but-punished rather than instantly fatal, and a run stays reproducible.

They prefer the cargo over the ship by 15%. **The threat model is that they shoot the thing you are
protecting**, and it costs one multiply.

## Scoring

`score = integrity × 100 × 30 + max(0, par_time − elapsed) × 40`, graded S/A/B/C above 3400 / 2800 /
2100 / 1200. Integrity is weighted heavier than time on purpose — this is a delivery job, and a
prototype that paid better for recklessness would be testing a different question.

**Arriving without the crate is not a failure.** It is a completion worth zero integrity, which
grades F and still pays the time bonus. That is a more interesting outcome than a failure screen and
it keeps a bad run playable to the end. Losing the crate only ends the run if you *leave* it —
detached, beyond 250 m, for eight seconds. Any one of those alone would turn a recoverable mistake
into a restart.

A crate still on the tether counts as delivered, and so does one you released that coasts through
the ring. It has to: a correctly towed crate is 14–30 m astern when the ship crosses the line, so
asking whether it is inside the dock volume at that instant marks every clean delivery as a failure.
It did exactly that for one test run — 100% integrity, grade F.

## The numbers

Every figure below is printed by `tools/measure_tether_response.tscn`. None of them were chosen by
feel.

**The tether is a one-sided spring** — exactly zero force below the rest length. That means it is a
mass on a *rope*, not a mass on a spring, and it has no classical period: each time the line comes
taut it gets half a cycle and is then thrown back into a free coast. Measured, a 3 m stretch rings
down in a single taut episode lasting **0.467 s** against a predicted half period of 0.73 s.

| Measurement | Result | Predicted |
|---|---|---|
| Tow cost — 3 s of thrust, towed vs free | **0.630** | 0.625 (= 1000 / 1600) |
| Steady stretch at cruise (17.5 m/s²) | **1.55 m** of 6.0 allowed | 1.54 |
| Steady stretch boosting (33.3 m/s²) | **2.94 m** of 6.0 allowed | 2.9 |
| Winch reel-in, loaded vs free | **0.135** | ≤ 0.25 |
| Full-band reel while boosting | finite, peak 3.48 m, no snap | no divergence |

Ordinary flight *never* snaps the line — 2.94 m of a 6.0 m break even under boost. Only violence
does, which is the risk/reward the whole design rests on.

**The winch earns its place.** Flying the same canned corner on a short line and a long one:

| Tether | Peak lateral offset | Peak swing off-stern |
|---|---|---|
| 8 m | 14.95 m | **179.6°** |
| 26 m | 31.78 m | 78.8° |

A ratio of 2.13 against a geometric ceiling of 2.48 — the metric saturates once both tethers swing
near-perpendicular, so 2.13 is most of the difference that geometry permits. The more interesting
number is the second column: **on a short tether the crate whips right around to the front of the
ship**, where a long one only reaches out to the side. Short is not simply "smaller"; it is a
different and more violent shape of motion.

## Why the numbers are what they are

**The 0.6 cargo:ship mass ratio decides whether this is fun**, and it is felt as three separate
things. You keep 62.5% of your acceleration while towing — at 0.2 the crate is scenery, at 1.0 every
manoeuvre is a chore. A crate swung to 2.5 m of stretch pulls 17 kN, which is 17 m/s² sideways on
the ship, comparable to your own main engine, so it can genuinely throw you off line. And the same
pull at the 3.0 m tail anchor is 13.6 rad/s² of yaw you did not ask for, against 29 rad/s² of
control authority — you always win that fight, but not instantly, and the second it costs you is
what makes a bad swing hurt.

**Reeling in does real work for free.** Shortening the rest length under load raises the overshoot,
which raises the tension, which pulls the crate in and pulls you back. The spring already is the
motor, so there is no winch force term. Paying out is fast and unconditional because slack costs
nothing — which quietly makes reel-out a panic button that drops tension to zero in one step.

**The mouse wheel is bound but is not the primary winch control.** A wheel event is a press followed
immediately by a release, so it physically cannot express "held", and the mouse is already carrying
pitch and yaw while captured. It sets a stepped target that the rate limiter then chases, which also
keeps a wheel click from becoming a step input into a stiff spring.

**The camera keeps a partial world-up reference** (`roll_follow = 0.35`) rather than rolling with the
ship. Full roll-follow barrel-rolls the frame, which is the textbook 6DOF motion-sickness trigger
and — more decisive here — makes the swing happen in a rotating reference frame, so the player
cannot tell an arc from a roll. "Up" is arbitrary in deep space, but it is *consistent*, and the
consistency is the whole value. It is exported if you disagree.

**Rotation is always damped; translation is not.** With no rotational authority over an existing
spin, one clipped asteroid leaves you tumbling behind a mouse that can only add rate. Translation
damping is the toggle, because drifting sideways while pointing backwards is the point.

## Layout

```
data/tether_layers.gd        physics bits and named masks; the only record of what each bit means
actors/ship/                 the RigidBody3D, the 6DOF controller, the runtime input registrar
actors/cargo/                the crate; tracks per-step delta-v for the damage model to come
components/tether/
  tether_link.gd             THE SPRING. The only file that applies a tether force.
  tether_winch.gd            rest-length actuator: rate limit and stall curve. No engine deps.
  tether_line.gd             the visual, and the state readout -- see below
components/camera/           6DOF chase rig; frames ship and cargo, no Euler chain, no pole
scenes/tether_sandbox.tscn   hand-authored first playable. F6 here.
tools/                       the measurement harness, the capture tool, the lint gate
```

**The tether visual is the state readout.** There is no gravity sag, because in zero g a cable does
not droop and a downward curve is a lie players read as a bug. What a trailing cable does is bow
*against* its own relative motion, and the bow magnitude is solved from the slack rather than picked
— so the line bows while there is rope spare and goes dead straight the instant it comes taut. That
straightening is the best "you are about to snap this" cue available, and it falls out of the
geometry being honest. It is drawn as a world-space-width ribbon rather than `PRIMITIVE_LINE_STRIP`,
because line width is ignored on most GL Compatibility targets and the tether is this game's entire
HUD.

## Self-containment

Same four rules as `examples/3d/vehicle_jeep`:

1. **Paths are relative to the file that uses them.** The Godot editor rewrites them to absolute on
   re-save, which breaks the folder silently.
2. **`load()`, `ResourceSaver` and `FileAccess` need real `res://` paths**, so tool scripts resolve
   them through a local `_res()` helper.
3. **Project settings become nodes.** `ship_input_actions.gd` registers the actions at runtime,
   skipping any the host already defines and erasing only what it created. Every action is prefixed
   `ship_`, because this repo already contains a wolf that owns `move_forward` and a jeep that owns
   `jeep_*`.
4. **An `@export` beats a project setting.** Gravity is zeroed per body rather than assumed, damping
   modes are `REPLACE` so a host's `default_linear_damp` cannot add invisible drag to "Newtonian"
   drift, and the spring's stability bound is computed against the tick rate read at runtime.

## Tools

All take `--path <godot project root>`: the folder holding `project.godot`, not this folder. Use the
**`_console.exe`** build on Windows; `C:\godot\godot.cmd` ends with `pause > nul` and hangs headless
runs.

```bash
G=Godot_v4.7.1-stable_win64_console.exe

# After adding any new class_name, or every type in this folder will fail to resolve.
$G --headless --path <root> --import

# Regenerate the course. Prints the table this README quotes, and exits 1 rather
# than emit a course with a wall across it.
$G --headless --path <root> --script res://examples/3d/cargo_tether/tools/build_cargo_run.gd

# Verification. The static one via --script, the runtime one via its .tscn --
# a node added during SceneTree._initialize() never receives _ready(), so running
# the runtime .gd directly reports nothing and exits 0.
$G --headless --path <root> --script res://examples/3d/cargo_tether/tools/verify_cargo_tether_static.gd
$G --headless --path <root>         res://examples/3d/cargo_tether/tools/verify_cargo_tether_runtime.tscn

# The tuning instrument. Asserts nothing, prints everything.
$G --headless --path <root> res://examples/3d/cargo_tether/tools/measure_tether_response.tscn

# Flies on rails and saves PNGs. NOT --headless: the dummy driver renders nothing
# and every capture comes back blank, which looks exactly like a rendering bug.
# Defaults to the sandbox; pass a scene after `--` to photograph that instead.
$G --path <root> res://examples/3d/cargo_tether/tools/capture_sandbox.tscn
$G --path <root> res://examples/3d/cargo_tether/tools/capture_sandbox.tscn \
    -- res://examples/3d/cargo_tether/scenes/cargo_run.tscn
```

## Known trade-offs

- **A cargo trailing straight astern sits behind the camera.** The arm is 9–22 m and the tether is
  6–30 m, so while you fly straight the crate is genuinely off-screen behind you. This is why `C`
  exists and why the off-screen cargo marker is a required part of the HUD rather than a nicety.
  Pulling back far enough to frame a 30 m tether would render the ship a dot.
- **Asteroid collision is a single sphere at the mean radius** while the mesh is non-uniformly
  scaled, so visual and collision disagree by up to ±25%. Deliberate at greybox; keep the scale band
  narrow.
- **`continuous_cd` is off** for the frame budget. At the 110 m/s soft cap a body advances 1.83 m per
  step, well inside the smallest asteroid.
- **The soft speed cap is drag, not a clamp.** A hard velocity clamp is a wall you can feel, and it
  silently eats the momentum the spring just gave you.
