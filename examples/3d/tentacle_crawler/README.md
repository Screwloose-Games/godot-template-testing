# tentacle_crawler

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#).

A cosmic-horror thing that drags itself down grey zero-g corridors by throwing
tentacles at the walls and hauling. Carrion, or a symbiote — black, gangly, and
entirely procedural.

**Nothing here is keyframed.** A `Marker3D` carries the player's *intent*; the body
and all eight tentacles are solved from it every physics tick by algorithms.

The creature is an imported `.glb` with **no skin, no `Skeleton3D` and no
`AnimationPlayer`** — its "bones" are 141 nested plain `Node3D`s in eight chains, and
every one of them is posed from the gait solver's own curve every physics tick. So
`SkeletonIK3D`, `SkeletonModifier3D`, bone maps and retargeting are all irrelevant
here, and `nodes/import_as_skeleton_bones` would not change that: it only affects
files that have skins, and this one has none.

The question this prototype exists to answer is whether hauling yourself through a
tube by throwing grappling limbs at it feels good to drive.

## How to run

Open either scene and press **F6**, or from the command line:

```
godot --path <godot project root> res://examples/3d/tentacle_crawler/scenes/crawl_sandbox.tscn
godot --path <godot project root> res://examples/3d/tentacle_crawler/scenes/corridor_run.tscn
```

`crawl_sandbox.tscn` is a hand-authored 60 m straight box with a pinch in the
middle — the fast place to feel a tuning change. `corridor_run.tscn` is the
generated 244 m course with bends, a climb, a narrow section and a chamber.

## Controls

| Input | Does |
|---|---|
| `W` `A` `S` `D` / arrows | fly the marker **relative to the camera** — `W` goes directly away from it |
| `Space` / `Ctrl` | rise / sink (the camera's up, not the world's) |
| `Shift` | boost |
| `Q` / `E` | roll — **off by default**, and ignored entirely under the orbit camera |
| mouse | orbit the camera around the creature. Click to capture the pointer, `Esc` to release |
| `V` | swap to the chase camera — the cinematic shot, which steers the old way |

You are flying the marker, not the creature. The creature trails it and works out
how to follow.

**Steer by moving the camera.** Forward is measured off the orbit rig, including its
pitch, so you hold `W` and swing the mouse to bend the course rather than releasing
to re-aim. Orbit above the creature and `W` dives. Under `V`'s chase camera the older
scheme is still there: the mouse rotates the marker itself and it flies in its own
frame.

## The loop

Fly the marker forward. The creature notices it is behind, its tentacles hunt for
walls ahead, plant, and haul. Stop, and it coasts to a halt exactly a leash-length
back and keeps writhing in place.

## How it works

**The marker leads, the body lags.** A spring with a 4 m dead zone. Inside that
distance it pulls nothing at all, which is why the creature visibly trails rather
than wearing the marker like a cursor.

**Tentacles do the moving, two at a time.** Eight strands cycle
`SEARCHING → REACHING → PLANTED → PULLING → RELEASING`, and above that sits a gait
that moves them in *pairs*. Two limbs shoot forward one after the other, both plant,
both haul on the same tick, and the creature lunges. Each hunts in its own sector of
a cone opened around the direction the body is *travelling* — not where its nose
points, which is what lets it turn a corner instead of grinding into one. One lunge
is a raised-cosine impulse worth `2 × 38 × 0.30 × 0.5 × along² ≈ 6.8 m/s` of Δv.

A strand strokes **once** per grip. It does not decide to; the gait tells it to, and
tells its partner on the same tick. That is the whole difference between this and a
continuous haul — eight limbs pulling on private timers average out into a smooth
drag no matter how the numbers are set.

**Pairs are opposed, and chosen fresh each lunge.** The two members sit at least a right
angle apart on the sector ring, so their lateral pulls cancel and the sum is forward —
two anchors on the same side would throw the creature at that wall. The pair is picked
from whichever strands are idle rather than fixed in advance: permanent couples deadlock,
because four grips can land one in each couple and then no couple has both members free.

**Idle limbs trail backward.** A searching strand streams behind the body instead of
casting around for a grip. Six of eight strands are idle at any moment, so when they
hunted forwards they drowned out the two that were actually reaching, and the gait read
as flailing. Forward now only ever means "this limb is reaching".

**The pulse is the gait, not the drag.** A burst, then a deliberate ballistic glide
of at least `GLIDE_MIN` while the next pair is already flying forward. The spent pair
stays stuck to the wall through all of it and pays out behind the body until it is
about a metre back, then lets go. `brake_multiplier` used to supply the pulse by
tripling drag between strokes; it now sits at 1.0, because braking through the coast
destroys exactly the phase the gait exists to produce.

**It knows the world only through raycasts.** A 14-ray fan for walls, a cone for
anchors, one ray ahead for the corner peek. It never reads the corridor's
centreline, so it behaves identically in the hand-authored box, the generated
course, and any level you drop it into.

**Curves have inertia.** Each strand is a cubic Bézier whose two control points are
themselves spring-lagged. When the body lurches the midsection stays behind about
150 ms and then whips — that lag is the whole symbiote read, and a plain Bézier has
none of it. The chain is then laid along that curve rather than solved at the anchor,
which is the point: a limb that tracks its target exactly looks mechanical however
correct its joint angles are.

**Limbs are not interchangeable.** The model's chains run from 14 bones to 23, so each
strand carries its own reach (4.4 m to 7.5 m) and its own search sector, both solved at
`_ready` from the geometry rather than from an index. Two consequences are worth
knowing: a strand reaches as far as it physically can rather than taking the nearest
hit — the search sweeps its cone open from the inside and keeps the farthest thing it
finds, which is what "full stretch" means here — and a strand that keeps failing widens
its search rather than starving politely. Measured mean is 79% of a strand's own reach;
the remainder is geometry, not the solver settling.

## Measured numbers

From `tools/measure_crawl_response.tscn` at 60 Hz. **These are measured, not
chosen** — retune anything and re-run it, then update this table or delete it.

The harness unwires the camera and drives the marker in its own frame, dead level.
In play forward comes off the orbit rig, so a purely cosmetic change to where that
rig rests would otherwise tilt the drive and rewrite this table; what is measured
here is the leash, the drag and the lunge cadence, not the framing.

| | idle (marker parked) | driven (forward held) |
|---|---|---|
| travelled | 0.00 m in 8 s | 36.49 m in 8 s (4.56 m/s) |
| speed | 0.00 m/s | 0.02 – 25.32 m/s, mean 5.33 |
| marker separation | 4.00 m, dead steady | 1.78 – 22.40 m, mean 6.47 |
| lunges | 0 in 8 s | 13 in 8 s (0.62 s apart) |
| planted | 4 for 91% of the time | 3–4 for 59% |

The **lunges** row counts bursts, not per-strand strokes — two strands haul on the same
tick, so one entry here is one whole pull of the creature.

**The idle creature no longer strains in place**, which used to be a listed trade-off.
It falls out of the gait rather than being handled: a cycle only starts when a pair is
free, and a pair only becomes free when a spent one has been outrun and let go. Standing
still, nothing is ever outrun, so the creature simply holds its four grips. Parked, it
grips; driven, it lunges. Separation settling to exactly 4.00 m is the leash slack.

On the generated course it covers **97% of 244 m** with a minimum wall clearance of
2.14 m and never once leaves the shell.

The peak speed is the marker's, not the creature's own: at `move_speed` 27 m/s the
leash is what supplies the lurch, and `leash_max_accel / body_drag` is the real ceiling
on how fast this thing can ever go. The mean is grip-limited instead — the creature
cannot pull faster than its pairs cycle, which is what keeps the lunge readable at
speed.

## Layout

```
assets/models/         cosmic-horror.glb -- no skin, no animations, 141 bone nodes
actors/crawler/        crawler.tscn + crawler_body.gd   the integrator
components/
  marker_pilot/        the 6DOF marker; the ONLY file that reads input
  probe/               corridor_probe.gd, the 14-ray fan
  rig/                 crawler_rig.gd -- assembles the imported model at _ready
  tentacle/            tentacle_array.gd (state) + tentacle_bones.gd (bone posing)
  camera/              orbit rig (drives; owns "forward"), chase rig, and the director
data/                  crawler_layers, tentacle_tuning, crawler_math -- no engine deps
materials/             one .tres per corridor surface, plus the anchor pad
scenes/                crawl_sandbox.tscn (hand-authored), corridor_run.tscn (GENERATED)
tools/                 generator, both verify suites, the measure and capture rigs
```

## Self-containment

This folder is a guest in a larger project and must not need anything from it.

1. **Paths are relative to the file that uses them.** The Godot editor rewrites
   `ext_resource` paths to absolute `res://` on re-save, which breaks this silently;
   `[paths]` in the static suite greps for it.
2. **`load()` / `FileAccess` need real `res://` paths**, so tools build them with a
   local `_res()` helper from their own `resource_path`.
3. **Project settings become nodes.** Input actions are registered at runtime by
   `crawler_input_actions.gd`, refcounted, skipping anything the host already owns,
   and erased on the way out. Nothing here edits `project.godot`.
4. **An `@export` beats a project setting.** Gravity is not read; there is none.

## Tools

```
# regenerate the course (edit the generator, never the output)
godot --headless --path <root> --script res://examples/3d/tentacle_crawler/tools/build_corridor_run.gd

# structure: wiring, layers, boundaries, paths, uids, tuning invariants
godot --headless --path <root> --script res://examples/3d/tentacle_crawler/tools/verify_tentacle_crawler_static.gd

# behaviour: lag, ratchet, anchors, stagger, corridor traversal, bone pose
godot --headless --path <root> res://examples/3d/tentacle_crawler/tools/verify_tentacle_crawler_runtime.tscn

# the numbers in the table above
godot --headless --path <root> res://examples/3d/tentacle_crawler/tools/measure_crawl_response.tscn

# screenshots -- NOT headless, and you have to actually look at them
godot --path <root> res://examples/3d/tentacle_crawler/tools/capture_crawler.tscn
godot --path <root> res://examples/3d/tentacle_crawler/tools/capture_crawler.tscn -- res://examples/3d/tentacle_crawler/scenes/corridor_run.tscn
```

## Gotchas

- **`scenes/corridor_run.tscn` is generated.** Edit `tools/build_corridor_run.gd`
  and re-run it. The skeleton is fixed and only the wall jitter is seeded, so
  regenerating gives a clean diff.
- **The creature has no collider at all.** That is deliberate — it is kinematic, and
  it is also why the camera's `SpringArm3D` can never catch on it.
- **Both directional lights have shadows off.** A sealed tube lit by a light from
  outside is entirely in shadow, and the interior renders at ambient only.
- **Retune in this order:** `stroke_gain` → `body_drag` → `GLIDE_MIN` →
  `PULL_HANDOFF`, and `leash_slack` **last** — it sets both the trailing distance
  and the point at which the creature decides it has arrived, so it moves two
  feelings at once, and `[lag]` asserts against it directly. Reach for
  `drive_distance` instead when the creature overshoots.

## Known trade-offs

- **Idle limbs trail; they do not hunt.** A searching strand streams backward along the
  body rather than casting about for a grip, so a parked creature reads as poised rather
  than busy. That is deliberate — six of eight strands are idle at any moment, and when
  they waved forward they drowned out the two that were actually reaching — but it does
  mean the creature looks less curious than it is.
- **The wall push-off now centres, deliberately.** `probe_comfort` sits above the
  corridor's half-height, so the push comes from every side at once and the creature
  runs down the middle. That is a gait decision, not a comfort one: the body rolls so
  its up-axis points away from the nearest wall, which pins each strand's sector
  relative to whichever wall it is hugging — and crawling along one wall left the four
  raised arms permanently aimed across a tube they could not span. All four starved.
- **470 MeshInstance3D, one creature.** The model is 468 voxel cubes plus a body and a
  gullet, and on GL Compatibility that is ~478 draw calls in a shot (the capture tool
  prints the number). Triangles are trivial at ~29k, so this is purely draw-call bound.
  If it needs to come down, merge each bone's three cubes at import time via an
  `EditorScenePostImport` script — 423 draws become 141 — before reaching for a
  MultiMesh, which would move the cost onto per-frame GDScript instead.
- **The chase camera is tight.** The creature is 3.9 m across in an 8 m-tall tube, and
  a `SpringArm3D` riding a body that rolls walks into the ceiling: asking for 16 m
  measured an actual 4.6 m. The lens was widened instead. The orbit rig, which is the
  camera the game starts on, frames it fine.
- **Nothing here is pooled or instanced for a crowd.** A second crawler is a second
  full set of raycasts and another 470 draw calls.
