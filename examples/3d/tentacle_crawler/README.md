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

**Tentacles do the moving.** Eight strands cycle
`SEARCHING → REACHING → PLANTED ⇄ PULLING → RELEASING`. Each hunts in its own
sector of a cone opened around the direction the body is *travelling* — not where
its nose points, which is what lets it turn a corner instead of grinding into one.
A planted strand pulls steadily; a stroking one adds a raised-cosine impulse worth
`22 × 0.34 × 0.5 = 3.74 m/s` of Δv.

**The ratchet is one line.** Gripping but not hauling triples the body's drag, so
between strokes it nearly stops and each stroke is a visible lurch. Pulse, glide,
pulse. Delete `brake_multiplier` and every test still passes — the creature just
glides everywhere and stops being a creature.

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
knowing: a strand prefers anchors at *its own* working distance rather than the nearest
one — otherwise the long limbs camp the near wall and the short ones can never get past
them — and a strand that keeps failing widens its search rather than starving politely.

## Measured numbers

From `tools/measure_crawl_response.tscn` at 60 Hz. **These are measured, not
chosen** — retune anything and re-run it, then update this table or delete it.

The harness unwires the camera and drives the marker in its own frame, dead level.
In play forward comes off the orbit rig, so a purely cosmetic change to where that
rig rests would otherwise tilt the drive and rewrite this table; what is measured
here is the leash, the drag and the stroke ratchet, not the framing.

| | idle (marker parked) | driven (forward held) |
|---|---|---|
| travelled | 0.00 m in 8 s | 36.61 m in 8 s (4.58 m/s) |
| speed | 0.00 m/s | 0.01 – 23.81 m/s, mean 5.12 |
| marker separation | 4.00 m, dead steady | 2.84 – 24.74 m, mean 7.17 |
| strokes | 2 in 8 s | 10 in 8 s (0.80 s apart) |
| planted | 4–5 for 99% of the time | 2–5 for 89% |

Idle separation settling to exactly 4.00 m is the leash slack, and it is the point:
the creature holds station rather than creeping past the marker.

On the generated course it covers **97% of 244 m** with a minimum wall clearance of
1.96 m and never once leaves the shell.

The peak speed is the marker's, not the creature's own: at `move_speed` 27 m/s the
leash is what supplies the lurch, and `leash_max_accel / body_drag` is the real ceiling
on how fast this thing can ever go. The mean is grip-limited instead — the creature
cannot pull faster than its tentacles cycle, which is what keeps the ratchet readable
at speed.

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
- **Retune in this order:** `stroke_gain` → `body_drag` → `brake_multiplier` →
  `fire_interval`, and `leash_slack` **last** — it sets both the trailing distance
  and the point at which the creature decides it has arrived, so it moves two
  feelings at once.

## Known trade-offs

- **The idle creature strokes without moving.** At rest the strands still grip and
  heave; the drive is gated to zero, so nothing comes of it. It reads as straining
  in place, which suits the thing, but the animation and the motion are honestly
  decoupled in that one state.
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
