# Capture-Point Skirmish — 3D RTS prototype

> **How to run:** open `rts_skirmish.tscn` in the editor and press **F6** (*Run Current
> Scene*). It is not the project's main scene and is deliberately not registered in
> `globals/scene_manager.gd` — see [Self-contained](#self-contained) below.
>
> From a terminal:
> ```
> godot --path <repo root> res://examples/3d/realtime_strategy_example/rts_skirmish.tscn
> ```

A prototype, not a game. Its only job is to answer **"is this loop fun?"** — everything here
is built to be cheap to change and cheap to throw away.

## The loop

Hold more capture points than the enemy → their reinforcements drain → when their ticket
count hits zero, you win. Points also pay gold, gold buys units at your HQ, and units fight
over points. Destroying the enemy HQ is still an instant win, but it means abandoning the
points that are actually draining them — that tension is the game. A five-minute clock is a
backstop; on expiry whoever has more tickets wins.

Being level on points drains nobody, so a stalemate pressures both sides to break the tie
rather than turtle. Losing a unit also costs a couple of tickets, so trading badly has a
price even while you hold ground.

Three unit types form a counter triangle, with both a bonus and a penalty applied — a **3×
swing** between mirrored matchups, loud on purpose so you learn it from one engagement:

**Grunt** beats **Archer** beats **Tank** beats **Grunt**

| | Cost | Build | HP | DPS | Range | Speed |
|---|---|---|---|---|---|---|
| Grunt (capsule) | 50 | 3 s | 120 | 18 | 2 m | 6.0 |
| Archer (thin capsule) | 75 | 4 s | 70 | 22 | 12 m | 5.0 |
| Tank (box) | 150 | 8 s | 400 | 30 | 2.5 m | 3.5 |

Starting gold is 150 — enough for three Grunts on frame one — so the first real decision
happens immediately rather than after a build-up. Production is a **single queue per HQ**, so
you cannot convert 400 banked gold into an army the moment you feel threatened. That is what
makes the buy *order* a decision. (Opening with a Tank is a trap: 8 seconds of build time
with nothing on the field.)

**New units route themselves to the most contested point** rather than idling next to your
base. Right-click a destination with the HQ selected to take manual control of the rally
point — after that the HQ stops overriding you.

## Controls

| Input | Action |
|---|---|
| Left click | Select (Shift adds, Ctrl removes) |
| Left drag | Box select |
| Double click | Select every on-screen unit of that type |
| Right click | Move — **always obeyed**, units break off a fight to go; on an enemy, attack; with the HQ selected, set rally |
| Ctrl + right click | Attack-move: go there, but stop and fight what you meet on the way |
| **Z / X / C** | Build Grunt / Archer / Tank |
| 1–4 | Recall control group · Ctrl+1–4 (or Shift) to assign · double-tap to recentre |
| WASD / arrows / screen edge / middle-drag | Pan |
| Mouse wheel | Zoom |
| Space / F | Centre on HQ / on selection |
| H | Toggle the on-screen controls panel |
| Esc or P | Pause (the template's shared pause menu) |
| R | Restart, on the result screen |

Production is on **Z/X/C** rather than 1/2/3 because the number row is control groups and
WASD is the camera.

## Where the knobs are

| What | Where |
|---|---|
| Tickets, drain rate, economy, capture rates, HQ stats, camera, counter multipliers | `data/rts_config.gd` |
| Per-unit-type stats | `data/unit_grunt.tres`, `unit_archer.tres`, `unit_tank.tres` |
| AI reaction speed, **how often it skips a purchase**, counter accuracy, push threshold | exported on the `AiCommander` node |
| Map layout, capture point values | `map/skirmish_map.tscn` |

`data/rts_config.gd` is the file to open for a balance pass. The unit `.tres` files can be
edited with the game running.

The three knobs most likely to need moving first:

- `TICKET_DRAIN_PER_POINT` (2.5) — how fast a lead closes out a match.
- `HQ_TRICKLE_INCOME` (8.0) — how survivable it is to hold nothing.
- `AiCommander.purchase_skip_chance` (0.35) — difficulty. Toward 0 is harder, 0.6 easier.

## Layout

```
rts_skirmish.tscn/.gd     Root: wiring, opening camera, restart
data/                     Tuning constants, physics-layer names, unit stat resources
core/                     RtsWorld (state + event hub + unit registry), economy, screen-space helpers
units/                    RtsUnit (CharacterBody3D) and its visuals
buildings/                HQ (production, rally, defensive gun) and capture points
camera/                   RTS camera rig
player/                   Selection, orders, formations, drag overlay, order pings
ai/                       Enemy commander
ui/                       HUD, production buttons, result panel
map/                      Arena, navmesh, obstacles, HQ and capture-point placement
```

## What the first playtest changed

The original build was measurably unfair, and in the least interesting way. With a completely
idle player the enemy tripled its income **eleven seconds in** off two units, and by t=30 it
was earning 15/s against 3/s. It never out-fought you; it out-*earned* you before the first
fight happened. Four things were wrong:

1. **The economy was the whole game and had no floor.** Base trickle was 3/s against 18/s of
   point income, so touching a point first was effectively the win condition, and there was no
   catch-up mechanic. Now: trickle 8/s, points worth less, plus bonus income per point of
   deficit. Points are tempo and position, not an economy lock.
2. **Your army was idle by default; the AI's never was.** Player units walked to a rally point
   8m from the HQ and stopped. AI units got an objective within a second. That is a pure
   attention tax — you paid it just to keep pace, and every second spent microing a fight was a
   second not spent re-tasking. Now new units auto-route to the most contested point.
3. **Melee units were nearly blind.** Acquire radius was `attack_range × 1.5`, so a Grunt
   noticed enemies within 3m while an Archer saw 18m. Armies drifted past each other and
   Archers were quietly correct regardless of the counter triangle. Floored at 9m.
4. **The AI had inhuman economic efficiency**, converting gold to units the instant it could,
   forever. It now skips purchases and thinks more slowly, so it wins on decisions rather than
   on mechanics.

The win condition also moved from "destroy the HQ" to the ticket race, because the HQ was a
distant abstract goal while the capture points were the actual moment-to-moment game — the
fun and the win condition were in different places.

Measured after the change, with the same idle-player test: income ratio at first capture went
from 3:1 to 1.55:1, and an idle player now loses in ~70s via a visible draining bar instead of
a hidden economic death spiral. A player who only spams the cheapest unit and lets auto-rally
do the walking now finishes ahead of the AI.

## Notable decisions

**Self-contained.** Everything lives in this folder. No edits to `project.godot`, no entry in
`globals/scene_manager.gd`. Two consequences shape the code:

- *No input actions.* All RTS input is raw `InputEventMouseButton` / `InputEventKey`. The one
  exception is the pre-existing global `pause` action, which the shared pause menu handles
  itself.
- *No autoloads.* `core/rts_world.gd` is the match-wide event hub and unit registry, but it is
  a plain node in the `rts_world` group, resolved via `RtsWorld.find_in(node)`. A static
  singleton would have been simpler and wrong: statics survive `reload_current_scene()`, so
  restarting would hand every new unit a reference to the previous match's freed state.

**Screen coordinates go through `core/rts_screen.gd`.** The project stretches with
`canvas_items`, and mixing `InputEvent.position` with `Camera3D` projection is the classic
"my clicks are offset once I resize the window" bug. Nothing here reads `event.position`;
picking uses `Viewport.get_mouse_position()`, which is defined in the same space the camera
projects into. The drag overlay reads its own mouse position in canvas space, because that is
the space it draws in.

**Box select is screen-space, not a physics frustum query.** Each unit's chest is projected
with `unproject_position()` and tested against the rectangle, with a
`is_position_behind()` guard. A hand-built frustum is more code and gets the edge cases wrong.

**Units are `CharacterBody3D` with no gravity** (`MOTION_MODE_FLOATING`) and they do not
collide with the ground at all — the arena is flat, so there is nothing to stand on, and
skipping it removes every floor-snap and sinking bug at a stroke.

**A move order is an order, not a suggestion.** Plain right-click clears the unit's target and
suppresses re-acquisition until it arrives, so a squad can be pulled out of a losing fight.
This was originally an implicit attack-move, which meant units in combat silently ignored
movement commands: the auto-acquired target outranked the destination, and the 0.25s re-scan
handed the target straight back even when `move_to()` cleared it. Disengaging is half of what
movement orders are for. Attack-move is now explicit (Ctrl), and the AI and HQ reinforcements
use it, since neither has any notion of retreating. Units resume defending themselves the
moment they arrive and go idle.

**Formations before avoidance.** A move order for N units is spread into concentric rings and
handed out nearest-first (`player/rts_formation.gd`). Giving a whole squad one identical
destination is the single biggest cause of an RTS feeling broken, and no amount of RVO tuning
fixes a genuinely unsolvable problem.

**Avoidance is switched off the instant a unit stops.** RVO keeps nudging neighbours forever
otherwise, and an arrived squad spends the rest of the match vibrating.

**The navmesh is hand-authored, not baked.** `map/skirmish_map.tscn` carries a single quad
`NavigationMesh` covering the arena; the rocks are `NavigationObstacle3D` with avoidance
enabled. Nothing depends on someone remembering to press "Bake NavMesh", which would fail
silently by leaving every unit unable to path.

**Nothing paths before the navigation map exists.** `NavigationServer3D` has not built its map
during the first frames, and a path requested then comes back empty — leaving units standing
still forever. `rts_skirmish.gd` awaits two physics frames before anything moves.

**Physics layers are named in `data/rts_layers.gd`.** The template README asks for named
layers mirrored in a constants class; since this example cannot name them in
`project.godot`, that file is the *only* record of what each bit means.

## Known gaps and next steps

- **The difficulty may now be too low.** The fairness fixes were deliberately generous, and a
  bot that only presses one build key beats the AI. `purchase_skip_chance` is the dial; expect
  to pull it down from 0.35 once the loop itself feels right.
- **Whether the counter triangle actually matters is still unverified.** The melee acquire fix
  was supposed to make it live, but nobody has played enough matches to say whether you really
  change what you build in response to what they field, or whether Grunt-spam is just correct.
  That is the single most important question left.
- **The AI does not react to being counter-picked mid-match** beyond its production scoring —
  it will not retreat a losing fight.
- **Ticket costs on unit death may be too small to notice** (2 per unit against 400). Position
  is meant to dominate, but if fights feel weightless this is the first place to look.
- **No audio.** Deliberate: silent placeholders add nothing to a fun-evaluation, and the
  template's `SoundManager` routes through a 16-voice pool that RTS combat would turn to mush
  without a rate limit. If added later, use
  `.claude/generate-placeholder-audio/generate_placeholder_audio.py` with
  `--dest` pointing inside this folder — never raw ffmpeg, since CI validates filenames and
  WAV specs.
- **Mouse picking is verified at 1280×720 only.** The coordinate spaces were confirmed to
  agree (Control layout, viewport mouse position and camera projection are all in the same
  1280×720 design space under `canvas_items` stretch), but the editor's embedded game window
  could not be resized to re-test. If clicks are ever offset from the cursor,
  `core/rts_screen.gd` is the single place to fix it.
- **No fog of war**, and the AI reads the player's army composition directly. Honest for a
  prototype whose question is about the counter triangle.
