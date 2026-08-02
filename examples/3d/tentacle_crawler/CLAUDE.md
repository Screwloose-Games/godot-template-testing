# tentacle_crawler

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#).

A self-contained example inside a larger project. See `README.md` for what it does and the four
self-containment rules — the short version: paths are relative to the file that uses them,
`load()`/`FileAccess` go through the local `_res()` helper, anything that would be a project
setting is registered at runtime by a node in the scene that needs it
(`components/marker_pilot/crawler_input_actions.gd`), and an `@export` beats a project setting.
Do not add anything here that requires editing the host `project.godot`.

## Verification before declaring done

A `.gd` edit is not finished when it is written. It is finished when it parses and runs.

- The `PostToolUse` hook runs `tools/check_gd.ps1` on every edited `.gd` (Godot `--check-only`
  + `gdlint`). Fix what it reports before moving on.
- **The hook cannot see any of the traps below.** Those need a real run.
- Both suites, and the output pasted — do not infer success from "the file saved":
  ```
  godot --headless --path <root> --script res://examples/3d/tentacle_crawler/tools/verify_tentacle_crawler_static.gd
  godot --headless --path <root>         res://examples/3d/tentacle_crawler/tools/verify_tentacle_crawler_runtime.tscn
  ```
- Anything touching the leash, the anchor gains, the drag or the tuning constants must ALSO
  re-run the measurement harness and paste the numbers — the README quotes them, so they are
  not allowed to drift silently:
  ```
  godot --headless --path <root> res://examples/3d/tentacle_crawler/tools/measure_crawl_response.tscn
  ```
- Anything touching the bone poser, the model, the materials, the lighting or the corridor
  generator must re-run the capture tool **and actually look at the PNGs**. Every physics
  assertion in this folder passes against a creature that renders as nothing at all.
  ```
  godot --path <root> res://examples/3d/tentacle_crawler/tools/capture_crawler.tscn
  ```
- Use the **`_console.exe`** build on Windows. `C:\godot\godot.cmd` wraps the non-console binary
  and ends with `pause > nul`, so it hangs headless runs and detaches stdout.
- `gdformat` owns formatting and will rewrite most files you touch. Run it, then **re-run the
  suites** — and say explicitly whether anything else broke, not just the case you were fixing.

## Traps that no linter catches

Every one of these was hit while building this example. `gdlint` and `godot --check-only`
report nothing for any of them.

**GODOT TREATS CLOCKWISE WINDING AS FRONT-FACING, and an outward-wound trimesh is invisible to
raycasts.** `ConcavePolygonShape3D.backface_collision` defaults to `false`, so the generated
corridor's walls did not exist as far as any query was concerned. The failure does not look
like a winding bug: the corridor renders perfectly *from outside*, the creature still finds a
few anchors on rib geometry, and nothing errors anywhere. The tell was the body probe reporting
its full 25 m range in all fourteen directions inside a 9 m tube. The hand-authored sandbox
never hit it because `BoxShape3D` is a solid convex primitive with no winding to get wrong.

**A `Transform3D` literal in a `.tscn` takes the basis ROWS, so the local axes are the COLUMNS.**
A `DirectionalLight3D` emits along its local −Z, which is the negated *third column* —
components 3, 6 and 9 — not components 7, 8 and 9. Reading it as columns builds a light aimed
somewhere else entirely, and you then write a comment describing the direction you meant rather
than the one you got. Probe it rather than deriving it.

**A sealed tube with `shadow_enabled` renders its whole interior at ambient only.** The
directional light is outside the shell, so the shell occludes it completely: uniform flat grey,
no form on anything, and a black creature that is genuinely invisible. It looks exactly like a
broken material. Both lights here have shadows off, deliberately.

**A NON-UNIFORM PARENT SCALE TIMES A CHILD ROTATION IS A SHEAR, and nested bones compound
it.** Godot composes a child's global basis as `parent.basis * child.basis`, so the squash on
`%Hull` would skew every bone under it in proportion to how hard the creature happened to be
heaving — worst at the exact moment you are looking at it — and down a 22-link chain that shear
compounds as `s^k`. This is why `%Limbs` is a SIBLING of `%Hull` rather than a child, and why
the poser puts its stretch in the link TRANSLATION and never in a bone scale.

**A chain of 23 bones spans 22 links.** `_bone_00` sits ON its socket with a zero translation.
Counting bones instead of links hands every strand a quarter-metre of reach it does not have,
and the only symptom is tips stopping just short of their anchors — which reads as the solver
being wrong rather than the arithmetic.

**A `_vox_` cube's name CONTAINS `_bone_`.** `tentacle_00_bone_00_vox_0` matches a naive
`_bone_` search, so walking a chain on that token alone steps out of the chain into a cube on
the first hop and reports every tentacle as two links long. Nothing errors: a two-link chain
poses perfectly well, it just does not reach.

**Godot does NOT infer `vertex_color_use_as_albedo`.** The body and gullet carry their colour
entirely as baked `COLOR_0` with no base colour factor at all, so straight out of the importer
both surfaces render FLAT WHITE. The import is faithful; the flag simply is not inferred.
`[rig]` asserts it rather than trusting it.

**`nodes/import_as_skeleton_bones` does nothing without a `skins` array**, and this model has
none. It will not turn the tentacle chains into a `Skeleton3D`. Do not spend an afternoon on it.

**A `SpringArm3D` cannot be longer than the tube it is in.** The chase arm rides the body's own
backward axis and the body rolls, so in an 8 m-tall corridor any tilt walks it into the ceiling:
asking for 16 m measured an ACTUAL 4.6 m. `capture_crawler` prints hit-length against requested
length, because "the camera is too close" and "the camera is fine and a wall is shortening it"
are the same photograph.

**A sector is fixed relative to whichever wall the creature is hugging.** The body's up-axis is
solved to point away from the nearest wall, so a strand's search cone is pinned to that frame.
A creature crawling along one wall therefore aims its far-side limbs across the whole tube
forever — with short chains, those strands never plant once and the only symptom is "half the
tentacles do not work".

**Take the anchor at the strand's OWN working distance, not the nearest one.** Nearest-wins is
the obvious rule and it starves short limbs: every strand prefers the same near wall, the long
ones can reach it too and get there first, and `ANCHOR_MIN_SEPARATION` then locks the short ones
out of the only band they can physically reach.

**FIXED PAIRS DEADLOCK.** Grouping the eight strands into four permanent couples is tidy,
deterministic and easy to assert against — and a couple can only fire when BOTH its members
are idle. Four strands are gripping at any moment and nothing stops them landing one in each
couple, at which point every couple is blocked and the gait stops until a grip happens to
expire. Measured: 10 lunges in 8 s fell to 6, with the creature hanging on nothing for 0.78 s.
Pair dynamically among the free strands; opposition is a property of the pair you pick, not
of having picked it in advance.

**Calling a release routine on something already releasing restarts it.** `_begin_release`
sets `_extend = 1.0`, so invoking it every tick on a RELEASING strand pins the retraction at
full extension forever: the strand never reaches SEARCHING, whatever is waiting on it never
proceeds, and the whole gait livelocks behind one limb. Nothing errors, and the phase string
looks plausible the entire time.

**Six idle limbs beat two working ones, visually.** The searching flail used to orbit each
shoulder at a polar angle measured off the TRAVEL axis, i.e. forwards. With two strands
reaching and six waving in roughly the same direction, the gait was reported as "the tentacles
are flailing" when the gait itself was measurably correct — anchors on walls, forward, paired,
hauling. The eye could not find the two that mattered. Idle limbs now stream BACKWARD, which
costs nothing and leaves forward meaning exactly one thing.

**A reach-forward rule belongs in the OBJECTIVE, not in the predicate.** Scaling
`FORWARD_BIAS_MIN` by the strand's own reach looks like the obvious way to stop long limbs
gripping sideways. It is a trap: a limb gripping a wall `c` to the side at polar angle `t`
reaches `c / sin(t)` and lands only `c / tan(t)` ahead, so demanding more distance ahead forces
a narrower angle, which demands more reach than the strand has. At a 0.45 fraction the shortest
chain needed 4.46 m against the 4.4 m it owns and took zero anchors in 8 s; total anchors fell
from 23 to 8. Maximising the forward component in the search instead rejects nothing.

**"Farthest anchor" and "furthest forward anchor" are different limbs.** A search that
maximises raw distance prefers the near-perpendicular ray every time, because that is much the
cheapest route to a lot of distance. It passes every assertion in this folder and looks like
waving.

**Retire by POSITION, not by age.** A grip planted early and still well in front of the body
has not finished its job; one planted a moment ago on a wall already shot past is dead weight.
Trimming the oldest let go of limbs still 3 m ahead — `[release-behind]` measured a +3.05 m
median release depth, i.e. the propelling pair cut loose while still reaching.

**A guard against dropping the last grips will silently disable the release rule it sits in
front of.** "Never release while only the pair is planted and nothing is inbound" reads as a
safety net; a strand is only REACHING for a couple of tenths, so in practice it blocks the soft
rule almost always and limbs trail until the -3.5 m deadlock hatch collects them. Gate it on
one remaining grip, not on the pair size, or the second of a spent pair gets stranded after the
first leaves and the release depths come out bimodal.

**Bounding the planted count by retiring the spent pair eagerly DELETES the gait's back
half.** Releasing the old grips the moment a fresh pair takes over is the obvious way to keep
the count under the ceiling, and it is a behaviour change wearing a bookkeeping change's
clothes: the propelling limbs are supposed to stay stuck to the wall and pay out behind the
body until they are about a metre back. Measured, the eager version released at a mean of
0.05 m — level with the body — which reads as the limbs popping off rather than being outrun.
Trim only the SURPLUS above the ceiling, oldest first, and leave `RELEASE_BEHIND` in charge of
the normal case. `[release-behind]` exists to catch exactly this and asserts the mean depth,
because the creature still crawls perfectly well while getting it wrong.

**A ceiling enforced before `_update_tips` is enforced a tick late.** `_update_tips` is what
turns REACHING into PLANTED, so a trim that runs earlier in the same tick cannot see the two
grips that tick just created. The count then overshoots for exactly one frame — invisible to
a per-interval sampler, and caught immediately by the per-tick one. Order matters more than
the trim does.

**A "currently hauling" exemption set has to be PRUNED, not just written.** Anything the
retirement pass skips must stop being skipped when the burst ends. A strand left in that set
is exempt from the ceiling permanently, and the symptom is a planted count that creeps one
over and stays there — which looks like an off-by-one in the ceiling rather than a stale set.

**A search that sweeps in equal angles quantises away the thing it is maximising.** Ray
distance in a tube goes as `clearance / sin(angle)`, so near the angle where a wall first
comes into range one step overshoots the strand's reach and misses while the next lands well
inside it. Everything between is reach that was available and not taken: at 7 sweep steps the
mean came out at 75% of reach, at 16 it was 79%. Carry the farthest hit and keep sweeping
until one clears the band rather than returning the first thing found.

**"Nothing is gripping" is a legitimate state for a lunging creature, and asserting a floor of
one grip fails honestly.** The spent pair hangs on until it has trailed behind, and the fresh
pair is still in flight when it lets go, so there is a real intended moment mid-lunge with
nothing attached. Bound how LONG it may hold nothing (0.13 s measured, 0.35 s asserted), not
whether it ever does.

**The editor resurrects deleted `.tscn` files.** A scene left in `.godot/editor/`'s
`open_scenes` list is re-saved by the next `--import` run — with ABSOLUTE paths, which `[paths]`
then fails on. Deleting a scene means clearing that list too.

**`const X: PackedStringArray = PackedStringArray([...])` is not a constant expression.** It is
a parse error with no line of context beyond the constant's name. Use `Array[String]`.

**`global_transform` and `global_basis` SETTERS fail on a node that is not in the SceneTree.**
They read the parent chain to solve for a local value, print `Condition "!is_inside_tree()" is
true`, and write identity. Scene generators must assign the local `transform`/`basis`.

**`PackedScene.pack()` writes `node_paths=` itself** when a Node-typed `@export` holds an actual
object reference. Assigning the object in a generator is therefore *more* reliable than
hand-writing the attribute — hand-writing is where the silent-null trap lives.

**`ResourceSaver` writes absolute `res://` paths and `FLAG_RELATIVE_PATHS` still does nothing to
text scenes in 4.7.1.** The generator rewrites its own output; `[paths]` greps for the absolute
form.

**A grep for a banned token fires on the comment that bans it.** `[render]` reported five
violations against `crawl_sandbox.tscn` whose only crime was a header explaining that none of
those effects may be used. Both `.gd` (`#`) and `.tscn`/`.tres` (`;`) need their comments
stripped before any source check — the files in this repo are heavily commented by house style,
and every rule is written down next to the code that obeys it.

**A check that prints PASS unconditionally will print it directly under its own failures.**
`[render] PASS` appeared beneath five `[render] FAIL` lines. Compare the failure count before
and after; a summary that gets skimmed and believed has to be right.

**Reusing one world across checks makes later checks measure earlier ones.** `[input-owner]`
reported a broken input map because the preceding check had flown the marker into the far end of
a 60 m corridor, where pressing forward moves it exactly nothing. Reload between checks.

**A control that shares a mechanism with the thing it controls for is not a control.** The
push-off check left the marker wired, so what it actually measured was the *leash* hauling the
creature back to the corridor axis — it reported a working probe on a build where `probe_gain`
was zero. Detach everything the variable under test is not.

**Gating a force by projecting onto the direction to a target breaks down at the target.** The
drive gate projected out the component along `_travel`, which is correct arithmetic and useless
in practice: once the creature has arrived, `_travel` is the bearing to a point two metres away
and swings through large angles every tick, so almost none of a 10 m/s² pull was removed. The
creature thrashed past a stationary marker at a mean of 5.6 m/s while the player held nothing.
Gate the whole force by a scalar instead.

**A launch ceiling has to count strands that are still in flight.** Counting only *planted*
strands let a launch go out while another was mid-reach, and the 2..4 band was measured
overshooting to five of six.

**The orbit rig's resting pitch is a flight bias, not a framing choice.** Forward is measured
off that rig with its pitch included, so the angle it sits at when nobody has touched the mouse
is the angle a held `W` flies at. At the -0.25 rad it was framed with, a player holding forward
and nothing else sinks ~2.2 m/s and is scraping the corridor floor within seconds — which reads
as the creature being dragged down, not as the camera being tilted. Any change to `_pitch`'s
initial value is a handling change.

**A camera tool that toggles blindly captures the wrong camera.** `capture_crawler` called
`director.toggle()` twice around a shot it named `orbit_view`; the day orbit became the default
that filename started containing a chase shot. Ask for the rig you want by name
(`set_orbit_active`), not for "the other one".

**A `SpringArm3D` refusing to pass through a wall is the arm working.** The chase camera sat two
metres off the creature's back with the blob filling half the frame, because the spawn point was
two metres inside a corridor mouth and the arm correctly declined to go outside it. The bug was
the spawn depth.

**Lambdas capture locals by value.** A signal handler that sets a flag must use a member
variable or a named method.

**Nodes added during `SceneTree._initialize()` never receive `_ready()`.** Every tool here is a
`.tscn` wrapper for that reason, except the two that genuinely only inspect files. Running one
of those as a bare `--script` reports nothing and exits 0, which looks exactly like a pass.

**`godot --check-only` exit codes are unreliable.** Analyzer errors print `Parse Error` and
still exit 0. Grep the output; `tools/check_gd.ps1` already does.

**A new `class_name` does not exist until the project is re-imported.** Run
`godot --headless --path <root> --import` once after adding one, or every file referring to it
fails with `Could not find type`. The same run is what generates the `.uid` sidecars that
`[uid]` requires.

## Component boundaries

- **`CrawlerBody` is the only file that writes the body's transform.** One integrator, one
  owner, one `global_transform =` at the end of the tick.
- **`TentacleArray` is the only file that raycasts for anchors**, and the only one that owns
  strand phase or lifecycle. It applies no force at all.
- **`MarkerPilot` is the only file that reads input.** It owns `Input`, `Input.mouse_mode`, the
  `ui_cancel` release and every `crawler_*` action. That is what lets the creature be driven by
  a verifier with no player, no camera and no HUD in the scene. `[input]` greps for it.
- **The live orbit rig owns the movement FRAME; the marker adopts it.** `MarkerPilot` still
  reads the stick, but while `CrawlerCameraDirector.wants_look()` is true it takes its facing
  from `drive_basis()` rather than accumulating mouse deltas, so forward is away from the
  camera. The rig that takes the mouse and the rig that defines forward are the same flag on
  purpose. With no director wired the marker falls back to its own frame, which is the state
  every tool and both suites run in — a change to the drive frame will not show up there.
- **`TentacleBones` reads state and writes transforms.** It must not contain `apply_`, `Input.`
  or `intersect_ray`, and `[input]` asserts that too. It owns the Bezier and the anchor pads;
  it decides nothing about where a strand goes.
- **`CrawlerRig` owns the model's shape and nothing else.** It runs once at `_ready`, splits the
  import across `%Hull` and `%Limbs`, and then does no per-tick work at all. It is also the only
  file that knows the model's node names.
- **`TentacleTuning` and `CrawlerMath` have no engine dependencies at all** — the same contract
  as cargo_tether's `TetherWinch`. The solver, the renderer and the verifier read one copy of
  every predicate instead of three files spelling `0.25`.
- **The creature is generator-agnostic.** It knows the world only through raycasts.
  `[independence]` greps `actors/` and `components/` for `Centerline`, `Path3D`, `Curve3D` and
  `corridor_run`, with comments stripped, which is what turns that from an intention into a rule.

## Project-specific invariants

- **`scenes/corridor_run.tscn` is GENERATED.** Edit `tools/build_corridor_run.gd` and re-run it.
  `scenes/crawl_sandbox.tscn` is hand-authored and is the faster place to test a change.
- **The generator refuses to emit a broken corridor** rather than emitting one and hoping: below
  2.2 m clearance, below a 9 m bend radius (at these widths the inner wall self-intersects and
  opens a *hole* in the shell), or any two non-adjacent rings within 2 m.
- **`maxf(along, 0.0)` on the stroke term is load-bearing.** Without it two strands gripping
  opposite walls and stroking together produce a net force of zero while both visibly heave, and
  the creature vibrates in place — which reads as a physics bug, not a tuning problem. Same
  clamp, same reason, as the leash and as cargo_tether's `TetherLink`.
- **The drive ramp is measured from `leash_slack`, not from zero.** The creature's resting place
  is exactly a leash-length behind the marker; a ramp measured from zero commands full drive at
  that distance, so it hauls, overshoots, gets pulled back and hauls again — a limit cycle on a
  player who is not touching the controls.
- **The pulse comes from the GAIT, not from `brake_multiplier`.** That was true of the old
  continuous haul — tripling drag between strokes was the entire "drags itself" read, and at
  1.0 the creature just glided. The pair-lunge gait inverts it: the pulse is a synchronised
  two-strand burst followed by a deliberate `GLIDE_MIN` of ballistic coast, and braking
  through the coast destroys the phase the gait exists to produce. `brake_multiplier` now
  ships at 1.0 and is kept only as the lever for a heavier variant.
- **A strand strokes ONCE per grip, and never on its own initiative.** `_age_strands` has no
  `PLANTED → PULLING` edge; `TentacleArray._advance_cycle` grants PULLING to a whole pair on
  one tick. Restoring a per-strand stroke timer re-creates the continuous haul no matter what
  the gains are set to — eight limbs pulling out of phase average out, which is exactly what
  a lunge must not do.
- **The `CREATURE` collision bit is reserved and deliberately unoccupied.** `[layers]` fails if
  anything claims it, which is how the next person finds out the body is kinematic on purpose
  before they change it.
- **Numbers in `README.md` are measured, not chosen.** Retune anything and re-run
  `measure_crawl_response`, then update the table or delete it. A quoted number that no longer
  holds is worse than no number.

## Style

Tabs (width 4), LF. `class_name` then `extends` at the top. Typed `@export`/`@onready` with
explicit `: Type` and `-> void` returns. `%UniqueName` access over `$Path`. Member order:
`class_name` → `extends` → signals → enums → consts → exports → public → private → onready.
Lines under 100 characters; `gdformat` owns the rest and will reflow what you write.
