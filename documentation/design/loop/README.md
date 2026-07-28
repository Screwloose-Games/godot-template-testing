# Gameplay Loop Documentation Format

A generalized, machine-validatable way to document a game's gameplay loops. Author in YAML, validate against a JSON Schema plus a semantic pass.

## The model

Four entity types, chosen so the same shape fits an auto-battler, a shooter, or a city builder:

- **Resource** — anything that *flows*: currencies, stats, materials, XP, unlocks, even `information` and `time`. Declared once, referenced everywhere by id. Making resources first-class (rather than free text inside steps) is what lets you analyze the economy programmatically.
- **Loop** — a repeatable cycle of activity at one **tier**: `core` (seconds), `session` (a run), `meta` (across runs). Tiers are the standard core/mid/meta framing; keeping them an enum lets you validate and sort loops by scale.
- **Step** — an ordered beat inside a loop: a player `action`, what it `consumes`/`produces` (resource refs), the `feedback` the player perceives, and `next` (the edges to other steps). Steps + `next` make each loop a directed graph, so branches and cycles are explicit rather than implied by prose.
- **Feed / Exit** — how loops connect. `feeds` says "this loop hands resources to that loop" (the core→session→meta chain); `exit` says "control leaves here." This is what turns a pile of loops into a system.

### Default closure
`next` is optional. If omitted, a step flows to the next in array order, and the **final step flows back to the first** — so the common "act → reward → repeat" cycle needs no wiring. Specify `next` only to branch or break the default.

## Why two validation layers

JSON Schema is excellent at *shape* — types, enums, required fields, id patterns — but it structurally cannot check that a reference resolves to something defined elsewhere in the same document, or reason about a graph. So validation is split:

1. **Shape** (`gameplay-loops.schema.json`, JSON Schema draft 2020-12) — every field, enum, and `snake_case` id pattern.
2. **Semantic** (`validate-loops.ts`) — the invariants below.

### Semantic invariants
Errors (block):
- Resource / loop / step ids are unique (ids unique within their scope).
- Every `consumes` / `produces` / `feeds.via` resource ref resolves to a declared resource.
- Every `next` target is a step in the same loop.
- Every `exit.to` and `feeds.loop` resolves to a declared loop (or `null` for `exit.to`).

Warnings (review):
- A step is unreachable from the loop entry.
- A loop's step graph contains no cycle — i.e. it doesn't actually loop.
- A resource is produced but never consumed anywhere, or vice versa (dangling economy — often legitimate across loops, hence a warning).

## Usage

```bash
npm i ajv yaml tsx
npx tsx validate-loops.ts example-roguelite.loops.yaml
# exit 0 = valid (warnings ok), 1 = errors
```

## Files
- `gameplay-loops.schema.json` — the format definition (shape).
- `validate-loops.ts` — schema check + semantic invariants; drop the checks into Vitest to gate docs in CI.
- `example-roguelite.loops.yaml` — a worked example showing the core→session→meta trio.

## Extending
Add resource `type`s or loop `tier`s by editing the enums in the schema; the semantic validator needs no changes for that. If you want per-genre required fields, layer a second, stricter schema that `$ref`s this one rather than forking it.
