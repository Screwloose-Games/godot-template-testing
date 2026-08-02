# Game Design Document — Working Title: TBD

**Version:** 0.1 (derived from the July 31, 2026 design kickoff)
**Status:** Living draft. Sections marked **[OPEN]** are not decided. Sections marked **[SOFT]** are directional agreement that hasn't been tested in a build yet.
**Engine:** Godot
**Platform:** PC
**Jam length:** 2 weeks

---

## 1. High concept

A first-person, zero-gravity horror game about mining an asteroid you should not be inside of.

You park your ship outside a rock, EVA into its tunnels with a shared power supply strapped between you and your crew, and strip it for anything valuable. Every tool you own runs off the same tank. Every noise you make is an advertisement. Something already lives in here, it doesn't need light to move, and you cannot kill it.

Get the loot. Get out. Get the high score.

---

## 2. Design pillars

**1. You are never the powerful thing in the room.**
No weapons that solve problems. Tools buy time, create distance, or make noise. The player's only real advantages are patience and information.

**2. Scarcity is the antagonist; the creature is the punctuation.**
The horror budget is spent on environment, resource pressure, darkness, and sound *first*. The creature raises the stakes on systems that are already tense on their own. If the creature were removed entirely, a run should still be unpleasant in the right way.

**3. Zero-G is a liability, not a superpower.**
Floating removes precision, orientation, and the ability to put your back against something. Disorientation is a feature. The one thing that feels at home here is the thing hunting you.

**4. Every convenience costs something shared.**
Light, digging, and breathing all draw from one tank that somebody has to carry and somebody has to crank. Comfort for one player is a bill paid by the group.

**5. Five minutes, fully felt.**
Short runs with real dead air in them. Silence is content. Nothing gamey competes with the build-up.

---

## 3. Genre and references

**Genre:** First-person co-op survival horror / extraction

| Reference | What we take | What we leave |
|---|---|---|
| Lethal Company | Loot-run structure, comedic-terrible group dynamics, score as the goal | Industrial interiors, quantity of content |
| Deep Rock Galactic | Voxel caves, destructible geometry, mining feel | Power fantasy, killable hordes, abundant light |
| Alien Isolation | One stalker, evasion over combat, tools that only delay | AI sophistication — explicitly out of budget |
| Subnautica | Environmental dread, oxygen pressure, terrifying open volumes, unexplained noises | Survival crafting, scale, metagame |
| Void Bastards | Everything is scarce, run-to-run structure, sortie into a hostile interior | Roguelike upgrade economy |
| Carrion / Venom symbiote | Monster silhouette and movement language | — |

**Tone:** cosmic horror, not gothic (Doom) and not industrial (Dead Space). Industrial was rejected on art cost — it demands railings, ladders, panels, machinery. Caves demand rock.

---

## 4. Core gameplay loop

```
       ┌──────────────────────────────────────────────┐
       │                                              │
   Arrive at asteroid                                 │
       │                                              │
       ▼                                              │
   EVA into tunnels ──► Find a resource node          │
       │                     │                        │
       │                     ▼                        │
       │              Mine (LOUD) ──► Chase down       │
       │                     │        floating chunks  │
       │                     ▼                        │
       │              Creature investigates            │
       │                     │                        │
       │                     ▼                        │
       │              Hide / flee / cut the cord      │
       │                     │                        │
       ▼                     ▼                        │
   Haul loot back to the ship ─────────────────────────┘
       │
       ▼
   Score tallied
```

**Moment-to-moment:** float, look, listen, decide whether the next twenty seconds of noise are worth what's in the wall.

**Run-to-run:** none for MVP. Score is the only thing that persists. **[OPEN]**

### Loop scoping decisions
- **The asteroid interior is the game.** All MVP effort goes here.
- **The exterior ship-flying loop is a secondary loop**, built only if time allows. If it never ships, nothing breaks.
- **The ship is absolute safety.** No threat can reach you aboard. It is the only place the tension releases.

---

## 5. Player and movement

### Movement model
- First person, six degrees of freedom, thruster-based.
- Newtonian physics — momentum carries, stopping is deliberate.
- Capsule collider. Players will collide with tunnel walls constantly; that's expected and part of the texture.
- No gravity. No walking surface. **[SOFT]** — mag boots or localized gravity anomalies were raised in passing but are not in scope.

### Player capabilities
- **No classes, no roles.** Every player has identical capabilities. Differentiation comes from what you're carrying at any given moment, not from a loadout screen.
- Carrying loot occupies you — a player hauling cargo can't dig, and likely can't deploy light. **[SOFT]**

### Known risk
Zero-G movement may strip the player of too much agency to feel good rather than merely bad. This is prototype #1 for exactly that reason. The design position is that discomfort is a legitimate horror tool, but "unreadable" is not the same as "tense."

---

## 6. Resource systems

### The tank (shared power/oxygen unit)
The central object of the game. One physical unit, carried by a player, that the crew is tethered to.

| Property | Behavior |
|---|---|
| Powers | Lights, digging tool, oxygen regeneration |
| Tether | Limits how far any player can travel from the unit |
| Recharge | Manual hand crank — **generates noise** |
| Carried | Somebody has to physically haul it; that player is compromised |
| Shared | More players mine faster but drain the same pool — self-balancing across crew size |

**Designed tensions:**
- Crank now (noise, and you're a sitting duck while doing it) or ration what's left.
- Turn off your lights to get more digging power. **[SOFT]**
- Split up to be efficient, or stay tethered and stay safe.
- **Cut the cord:** a player can abandon the tether and run for it, taking their odds alone and leaving the crew short a pair of hands. **[SOFT]**

### Oxygen
Currently unified into the tank rather than modeled as a separate system. Each player may hold a personal oxygen reserve that the tank replenishes. **[SOFT]**

**[OPEN]** — AJ's variant: thrust consumes breathable air, so movement and survival draw on the same meter. Liked in the room; needs a prototype before it's in or out.

### Light / senses — **[OPEN, HIGH PRIORITY]**
This is the game's hook and it is not chosen yet. Candidates:

| Option | Upside | Downside |
|---|---|---|
| Headlamp + consumable glow sticks | Familiar, readable, easy to ration | Least novel |
| Limited draw distance / fog | Cheap, controls art load | Can read as a technical limitation rather than a design choice |
| Radar / instrument readout | Flying blind on imperfect data; strong for "ship pings you the creature's proximity" | Abstract; risks feeling like a UI game |
| Echolocation shader (outlines only) | Distinctive; would cut a large share of texturing work | Loads the burden onto engineering; unproven |

Whatever is chosen, some form of restricted vision is mandatory. If players can see as far as they want, the game is flat.

---

## 7. Mining

- Resource nodes are embedded in tunnel walls.
- **Mining is loud** and is the primary way you attract attention. The core mining decision is "one more node or not."
- **Zero-G extraction:** broken chunks fly off and ricochet down tunnels rather than snapping to the player. Retrieval is a second, separate risk decision — the ore you want just bounced into a tunnel you haven't lit. **[SOFT]**
- The digging tool draws from the tank and can run dry. Running out mid-tunnel — potentially having dug yourself somewhere you can't dig back out of — is considered a *feature*.

### Terrain destruction
- Voxel terrain with marching-cubes smoothing, deformable by the digging tool.
- **Constrained deliberately.** The player must never be able to carve a clean escape route on demand. Charge limits are the primary brake.
- Secondary benefit: player-dug tunnels make the level *more* confusing to navigate, not less.

---

## 8. The creature

### Design
- **One creature.** Not swarms. A player who can't shoot resents a crowd; a player who can't shoot fears a singular thing.
- **Unkillable.** Tools scare it, delay it, or break line of sight. Nothing removes it.
- **Silhouette:** an amorphous black mass. Carrion / Venom-symbiote language rather than a legible animal.
- **Locomotion:** shoots tendrils that grab walls and pull itself along — procedurally animated from position, not keyframed. This gives high perceived polish for zero rigging cost and sidesteps the fact that Goxel produces nothing riggable.
- **Unaffected by zero-G.** It should read as native to a place the players are obviously trespassing in.

### AI
Deliberately modest. **A simple state machine with raycast vision**, roughly:

```
  PATROL ──(noise heard)──► INVESTIGATE ──(player seen)──► HUNT
     ▲                            │                          │
     └──────(timeout)─────────────┴──────(lost player)───────┘
```

**Explicitly not attempting Alien Isolation.** That was the meeting's key scope decision: an ambitious stalker AI would eat the whole budget and leave no time for the sound, lighting, and atmosphere that carry more of the fear anyway. A crude monster in a well-built environment beats a clever monster in an empty one.

**[OPEN]** — Does it crawl on walls? Wall-crawling across deformable geometry is meaningfully harder than a floating navigator that raycasts around obstacles. Floating is the cheaper default.

**[OPEN]** — Detection specifics: what alerts it, detection radius, how noise propagates, what it does on losing the player, whether it can dig.

---

## 9. Multiplayer

- **Designed co-op-first.** The game's best material — shared tank, split duties, someone cranking alone in the dark while the others mine — only exists with more than one player.
- **Must be genuinely good solo.** Not a degraded mode. Non-negotiable.
- **Target: 2 players.** Higher counts are not a design target; if 3–4 works, fine, if it's weird, acceptable.
- **[OPEN] Local co-op vs. networked.** Not resolved. Networked is more valuable to the team's goals and one programmer wants to own it; local is dramatically cheaper and would free that person for other work.
- If networked: **player 1 is authoritative** as the simplest workable model. Prototype code doesn't need to account for this yet, but systems built after the decision should.

---

## 10. Progression and scoring

- **Objective: score.** Loot value extracted per run. Framed in-fiction as money or haul value.
- **No spending, no upgrades, no meta-progression in MVP.** Historically this category never survives a jam anyway, so it's cut up front rather than half-built.
- **If progression is ever added**, the rules are fixed: rewards must be **temporary or consumable**, and may only buy *time* — never capability that makes the horror trivial. A permanent light source or a durable power increase would break the game. A headlamp you can lose when the creature hits you would not.

---

## 11. Pacing

Target run length: **~5 minutes.**

- **No threat at spawn.** The opening stretch is quiet on purpose — it teaches the controls and lets dread accumulate.
- Anticipation is the product. A minute of floating through a dark tunnel hearing something you can't identify is the game working correctly.
- Nothing "gamey" — card draws, upgrade popups, tutorial overlays — may interrupt the build-up. They dissolve immersion faster than anything else on the list.
- Difficulty should escalate within a run so that the last minute is not the first minute. **[OPEN]** — mechanism undefined.

---

## 12. Art direction

### Pipeline (locked)
```
  Goxel (voxel authoring) ──► GLTF export ──► Godot (marching-cubes smoothing, transform correction)
```

- **Goxel** is the sole authoring tool for assets. Chosen because its constraints force stylistic alignment between artists automatically — two artists in Blender would diverge; two artists in Goxel cannot.
- **No Blender round-trip.** Every manual step in an asset pipeline compounds under deadline and makes reversing decisions expensive later.
- **Origin handling:** Goxel gives no origin control (center-origin only). Correction is automated in Godot rather than fixed by hand per asset.
- **Static meshes only.** Goxel has no rigging or animation.

### Visual style
- Voxel geometry smoothed via marching cubes — not blocky, not Minecraft.
- Low fidelity, high output. The target is "cohesive and charming," not "detailed." Players need to care whether their friends die; they don't need pores.
- **Minimal character animation.** Simple characters, few appendages, restraint as a stylistic choice. **No Mixamo** — canned humanoid animation reads as generic and produces a quality cliff the moment anything non-humanoid appears.
- **If any character gets real animation investment, it's the creature.** That's what the player is looking at when it matters.
- Environments are caves, not facilities.

### Process
- **Mood board before assets.** A standing team retro complaint is jumping to asset production before the picture is clear. Miro is the shared board; anyone may contribute references.
- Art direction authority sits with the two art leads.
- Asset needs are published as a **prioritized bounty board** so additional contributors can self-serve.

---

## 13. Audio

**Currently unowned. This is the most significant staffing gap in the project.**

Given that the design deliberately routes horror through environment and sound rather than AI sophistication, audio is doing more work here than in a typical jam entry — arguably more than music.

Requirements sketch:
- Ambient cave tone; silence used as a deliberate instrument
- Creature vocalizations and movement cues, ideally audible before the creature is visible
- Unexplained noises with no source, Subnautica-style — the cheapest fear in the game
- Mining, cranking, and thruster noise as **diegetic gameplay signals** (the player must be able to hear how loud they're being)
- Proximity/directional audio for locating teammates and threats

**[SOFT]** Production idea: record the team's pets and pitch them down for creature vocalizations.

---

## 14. Technical scope budget

The team has capacity for roughly **two hard problems**. Current allocation:

1. **Destructible voxel terrain** (marching cubes, in-engine)
2. **Multiplayer** — pending the local-vs-networked decision

Everything else must be achievable with off-the-shelf approaches, templates, or deliberate simplification. This budget is why the creature AI is a state machine rather than a behavior tree, and why the level is not guaranteed to be procedural.

**[OPEN] Level generation:** procedural tunnels, one hand-authored level, or a static level with randomized resource node placement. Directly competes for the same budget. A hand-built level with randomized nodes is the cheap option and is likely correct if procedural generation would displace multiplayer.

---

## 15. MVP definition

A single asteroid. One creature. Five minutes. If a player finishes a run having been scared twice and having decided at least once to leave loot behind, the MVP works.

**In:**
- Zero-G first-person movement through a tunnel system
- Restricted vision (whichever sense model wins)
- Minable nodes with noise consequences and physical chunk retrieval
- Shared tank: power, tether, crank
- One creature with patrol/investigate/hunt behavior
- Return-to-ship extraction and score tally
- Two-player co-op, fully playable solo

**Out (post-MVP):**
- Ship-flying / exterior loop
- Upgrades, meta-progression, currency
- Multiple asteroids or creature types
- More than two players as a design target
- Wall-crawling creature locomotion
- Gravity anomalies, mag boots

---

## 16. Open questions index

| # | Question | Blocks | Owner |
|---|---|---|---|
| 1 | Jam deadline: 2 or 3 weeks | All scoping | Jonathan |
| 2 | Local co-op vs. networked | Multiplayer architecture, one programmer's assignment | Jonathan + Michael |
| 3 | Which sense model is the hook | Art load, shader work, level readability | Steven (prototype) |
| 4 | Procedural vs. static level | Technical budget, art load | Team |
| 5 | Creature detection and behavior specifics | AI implementation | Jonathan (prototype), Sean (consult) |
| 6 | Does the creature wall-crawl | AI complexity vs. deformable geometry | Jonathan |
| 7 | Is hauling the tank fun or just annoying | The entire resource pillar | Unassigned — **needs an owner** |
| 8 | Sound design ownership | Pillar 2 | Dylan (asking Chris) |
| 9 | In-run difficulty escalation mechanism | Pacing | Steven |
| 10 | Working title | Everything cosmetic | — |

---

## 17. Change log

| Version | Date | Notes |
|---|---|---|
| 0.1 | Aug 1, 2026 | Initial draft from July 31 kickoff transcript |
