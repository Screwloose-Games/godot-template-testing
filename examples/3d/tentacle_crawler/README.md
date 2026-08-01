# tentacle_crawler

Godot 4.7 · GL Compatibility renderer · Jolt Physics · GDScript only (no C#).

A cosmic-horror thing that drags itself down grey zero-g corridors by throwing
tentacles at the walls and hauling. Carrion, or a symbiote — black, gangly, and
entirely procedural.

**Nothing here is keyframed.** A `Marker3D` carries the player's *intent*; the body
and all six tentacles are solved from it every physics tick by algorithms. There is
no skeleton, no `AnimationPlayer`, no imported model. The creature is four spheres
and an `ImmediateMesh`.

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

**Tentacles do the moving.** Six strands cycle
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
none of it.

## Measured numbers

From `tools/measure_crawl_response.tscn` at 60 Hz. **These are measured, not
chosen** — retune anything and re-run it, then update this table or delete it.

The harness unwires the camera and drives the marker in its own frame, dead level.
In play forward comes off the orbit rig, so a purely cosmetic change to where that
rig rests would otherwise tilt the drive and rewrite this table; what is measured
here is the leash, the drag and the stroke ratchet, not the framing.

| | idle (marker parked) | driven (forward held) |
|---|---|---|
| travelled | 0.00 m in 8 s | 43.33 m in 8 s (5.42 m/s) |
| speed | 0.00 m/s | 0.05 – 13.91 m/s, mean 6.15 |
| marker separation | 4.00 m, dead steady | 3.19 – 11.40 m, mean 7.64 |
| strokes | 6 in 8 s | 13 in 8 s (0.62 s apart) |
| planted | 3–4 for 98% of the time | 2–4 for 99% |

Idle separation settling to exactly 4.00 m is the leash slack, and it is the point:
the creature holds station rather than creeping past the marker.

On the generated course it covers **97% of 244 m** with a minimum wall clearance of
1.07 m and never once leaves the shell.

## Layout

```
actors/crawler/        crawler.tscn + crawler_body.gd   the integrator
components/
  marker_pilot/        the 6DOF marker; the ONLY file that reads input
  probe/               corridor_probe.gd, the 14-ray fan
  tentacle/            tentacle_array.gd (state) + tentacle_ribbons.gd (geometry)
  camera/              orbit rig (drives; owns "forward"), chase rig, and the director
data/                  crawler_layers, tentacle_tuning, crawler_math -- no engine deps
materials/             one .tres per greybox surface
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

# behaviour: lag, ratchet, anchors, stagger, corridor traversal, ribbon geometry
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
- **The wall push-off does not centre.** It only acts within 2.6 m of a surface, so
  in a 9 m corridor there is a wide dead band through the middle. Centring proper is
  a side effect of where the anchors happen to be.
- **Six strands, one creature.** Nothing here is pooled or instanced for a crowd. A
  second crawler is a second full set of raycasts.
