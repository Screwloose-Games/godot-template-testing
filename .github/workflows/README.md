# CI workflows

Every workflow in this directory, what it enforces, and what it needs configured.
Consolidated from the game-dev CI scattered across several projects; `J:\game-jam-references`
was the newest source for most files.

## Configuration

### Repository variables (Settings → Secrets and variables → Actions → Variables)

| Variable | Used by | Default if unset | Notes |
|---|---|---|---|
| `GODOT_VERSION` | build, check-import-files, publish | `4.7.1` | Bumps the engine everywhere at once. Must be a tag that exists on [`barichello/godot-ci`](https://hub.docker.com/r/barichello/godot-ci/tags). |
| `ITCH_USER` | publish-to-itchio | — | itch.io account name. Publishing fails without it. |
| `ITCH_GAME` | publish-to-itchio | — | itch.io project slug. |

The `|| '4.7.1'` fallback is load-bearing. A bare `${{ vars.GODOT_VERSION }}` in a fork that
never set the variable resolves to an empty string, producing the image tag
`barichello/godot-ci:` and a pull failure that reads like a network problem.

### Secrets

| Secret | Used by | Notes |
|---|---|---|
| `BUTLER_CREDENTIALS` | publish-to-itchio | itch.io butler API key. |
| `GITHUB_TOKEN` | most | Provided automatically; no setup needed. |

## Workflows

### Asset validation

| Workflow | Trigger | Enforces | Blocks? |
|---|---|---|---|
| `validate-aseprite-files.yml` | PR touching `**.aseprite`, `**.ase`, `**.png`; manual | Filename convention, canvas/image ≤ 1024px, unique lowercase tag names, `.import` sidecar present, `assets/art/2d/` path layout | Yes |
| `validate-audio-files.yml` | PR touching `**.wav`, `**.ogg`, `**.mp3`; manual | 44.1kHz / 16-bit / mono WAV, ≤ 10s, ≤ 49MB, filename convention | Yes |
| `validate-gltf-files.yml` | PR touching `**.gltf`, `**.glb`, `**.spec.yaml`; manual | Referenced files exist on disk, filename convention under `assets/art/3d/`, spec validates against its schema, no leftover node transforms, and the model checked against a sibling `<model>.gltf.spec.yaml` — bounds, poly budget, up axis, expected textures and animations. Also renders ortho previews. | Yes |
| `flag-fbx-files.yml` | PR touching `**.fbx`; manual | Rejects FBX outright, comments with per-DCC glTF export links | Yes |
| `flag-mp3-files.yml` | PR touching `**.mp3`; manual | Rejects MP3 — its padding breaks seamless loops | Yes |
| `check-import-files.yml` | PR touching any of 22 asset extensions | Every asset has a current Godot `.import` sidecar. Same-repo PRs get the sidecars committed back automatically; fork PRs get them as an artifact and fail. | Yes |

`check-import-files.yml` has no `workflow_dispatch` on purpose — it reads `github.event.pull_request`
to find the head branch, so a manual run has nothing to check out.

**The checks run locally, and the gate is not the container.** Everything a model is judged
on is computed from the glTF JSON by `.github/scripts/validate-model-files.py` — no Docker,
no rendering, about a second per model:

```bash
python .github/scripts/validate-model-files.py --all                 # every model in the repo
python .github/scripts/validate-model-files.py path/to/sm_thing.gltf # one model
```

The same command is the CI gate, a `pre-commit` hook, and a blocking Claude Code
`PostToolUse` hook, so a failure never arrives as a surprise from CI. The container still
renders the nine ortho previews for the PR comment, but it no longer decides anything —
and it deliberately still runs when the gate fails, so an artist sees the picture *and* the
reason. There used to be a gate here that read `validate_gltf.py`'s `success` output; that
flag means "the file loaded and rendered", so a model that FAILed every key in its spec
turned the job green.

The `<model>.gltf.spec.yaml` format is documented in
[`schemas/model-spec.schema.json`](../../schemas/model-spec.schema.json), and that schema is
now **enforced** rather than merely documentary. Because it sets `additionalProperties:
false`, a misspelled key is a hard error — a spec saying `poly_budget` instead of
`poly_count_budget` used to be ignored in silence while the budget it asked for went
unchecked. A model with no spec file still passes silently, so adding a spec is how a model
gains acceptance criteria; run the command above on a model with no spec to read its real
width, height, depth and triangle count off the output and write them down.

**Bounds and triangle counts come from the accessor metadata**, not from decoded geometry.
glTF 2.0 requires `min`/`max` on every POSITION accessor, so
`tools/gltf-validator/gltf_measure.py` transforms each primitive's declared AABB by its
node's world matrix and unions the results. That is an AABB of transformed AABBs, so a
*rotated* node yields a superset of the exact bounds — but `unapplied_transforms` already
fails any model carrying a rotation, so on everything that passes the other checks the two
are identical rather than merely close. Triangles are counted **per instance**: a crate
referenced by twenty nodes is twenty crates' worth of budget.

`facing_direction` and `up_direction` are measured from the glTF node graph by
`tools/gltf-validator/gltf_axes.py`, which catches an export that skipped or botched the
Blender→glTF axis conversion. Both are covered by `test_gltf_axes.py` and
`test_validate_gltf_spec.py`, which the workflow runs before pulling the validator image —
they need only numpy and pyyaml, so they run outside the Docker image. To see what the
models already in the repo measure without failing anything, run
`python tools/gltf-validator/check_facing.py`.

`unapplied_transforms` is measured by `tools/gltf-validator/gltf_transforms.py` and fails a
model whose node chain still carries a rotation or a scale — the artist exported without
`Object > Apply` in Blender, or the export skipped the Y-up conversion. Both show up as the
same rotation on the same node, so the check reports beside the axis checks rather than
overriding them, and names the likelier cause. A node offset from the origin is reported but
never fails, because an object origin is a deliberate authoring choice. A spec that means to
describe a rotated node sets `allow_unapplied_transforms: true` to opt out. Covered by
`test_gltf_transforms.py`, including `test-fixtures/unapplied_rotation_90z.gltf` — a real
Blender export kept verbatim because it is the case that motivated the check.

### Documentation

| Workflow | Trigger | Enforces | Blocks? |
|---|---|---|---|
| `validate-pipeline-doc.yml` | PR touching `documentation/pipeline/**`, `tools/pipeline/**`, `schemas/asset-pipeline.schema.json`, `.github/ISSUE_TEMPLATE/**`, or the aseprite/audio validators; manual | The asset pipeline document validates against its schema, its cross-references resolve, its screenshots still match the source diagram, `PIPELINE.md` is freshly rendered, and the conventions it declares still match the constants hardcoded in the validator scripts | Yes |

That last clause is the useful one: `documentation/pipeline/pipeline.yaml` declares a
`code_mirrors` list naming each constant it quotes (`FILENAME_PATTERN`,
`MAX_TEXTURE_DIMENSION`, `WAV_FILE_SPECIFICATIONS`, ...). The validator imports them and
fails if they have drifted, so a convention cannot be changed in a script without the
documentation being updated in the same PR. See
[`documentation/pipeline/README.md`](../../documentation/pipeline/README.md).

### Lint

| Workflow | Trigger | Enforces | Blocks? |
|---|---|---|---|
| `gdlint-on-pull-request.yml` | PR touching `**/*.gd`; manual | `gdtoolkit` lint on changed files only | Yes |
| `check-gdscript-complexity.yml` | PR touching `**/*.gd`; manual | Posts a cyclomatic-complexity report | No — informational |

### Build and publish

| Workflow | Trigger | Does | Blocks? |
|---|---|---|---|
| `build-godot-game.yml` | Push of a `v*` tag; manual | Exports Web, Linux, Windows and macOS in the `barichello/godot-ci` container, then creates a GitHub Release with all four zips attached | n/a |
| `publish-to-itchio.yml` | Successful completion of *Build Godot Game* | Pushes the web build to itch.io via butler | n/a |
| `build-and-push-gltf-validator.yml` | Push to `main` touching `tools/gltf-validator/**`; manual | Builds and pushes the glTF validator image to `ghcr.io/<owner>/gltf-validator` | n/a |

A manual `build-godot-game.yml` run has no tag to read, so it publishes a **draft** release named
`manual-<short-sha>`. Only a real `v*` tag produces a published release.

macOS builds are **unsigned** — Gatekeeper blocks them on first launch and users need to
right-click → Open. Signing needs six Apple secrets and was deliberately left out.

## Things worth knowing

**Validators have no `branches:` filter.** A validator restricted to PRs into `main` silently skips
PRs into a jam or feature branch, which is when the feedback matters most.

**`validate-gltf-files.yml` needs an orphan `assets` branch** to store rendered previews. It creates
one automatically on first run if missing, using `git commit-tree` plumbing so the working tree is
never disturbed.

**Two Aseprite rules ship disabled.** `ENFORCE_TAGS_REQUIRED` and `ENFORCE_ONE_SHOT_REPEAT` in
`.github/scripts/validate-aseprite-files.py` encode what
`.github/ISSUE_TEMPLATE/create_aseprite_animations.yaml` asks for — one file per game object with
every animation as a tag, one-shots at `repeat: 1`. The art actually committed in these projects does
not follow that: the gladiator animations are one file *per animation* with no tags at all, and
`spider_enemy.aseprite` tags `idle` and `climb` at `repeat: 0` because they loop, with no `_loop`
suffix. Both rules are correct against the written convention and wrong against the real files, so
they are off. Turn them on once the art and the convention agree — otherwise every art PR fails.

**The validators are dependency-free by design.** `validate-audio-files.py` uses stdlib `wave`;
`validate-aseprite-files.py` parses the `.aseprite` binary layout and PNG `IHDR` chunk with `struct`.
Aseprite itself is not installable in CI — it ships as a paid binary or a source build — so the
parser reads the documented format directly. Neither script needs `pip install`.

`validate-model-files.py` is the deliberate exception: the axis and bounds maths needs `numpy`,
specs are YAML, and the schema check needs `jsonschema`. The `pre-commit` hook installs all three
into its own isolated venv, so contributors still need nothing on their PATH. Its *module scope*
is stdlib-only, though — `validate-pipeline-doc.py` imports the file to compare its constants
against `pipeline.yaml`, and that workflow does not install numpy, so the heavy imports live
inside `main()`.

**Hooks.** `pre-commit install` (once per clone) makes the model check and `gdlint`/`gdformat`
run on staged files. `.claude/settings.json` adds a blocking `PostToolUse` hook so Claude Code
gets the same feedback the moment it writes a `.gltf`, `.glb` or `.spec.yaml`. Neither is a
substitute for CI — a hook can be skipped with `--no-verify` and a fresh clone has none
installed, so no rule lives only in a hook.

### Running the checks locally

```bash
python .github/scripts/test_validate_audio_files.py
python .github/scripts/test_validate_aseprite_files.py
python .github/scripts/test_validate_model_files.py

# The model checks (numpy + pyyaml + jsonschema, no Docker)
python tools/gltf-validator/test_gltf_axes.py
python tools/gltf-validator/test_gltf_transforms.py
python tools/gltf-validator/test_gltf_document.py
python tools/gltf-validator/test_gltf_measure.py
python tools/gltf-validator/test_model_spec.py
python tools/gltf-validator/test_validate_gltf_spec.py

# Validate specific files
python .github/scripts/validate-aseprite-files.py assets/art/2d/spider/spider.aseprite

# Reproduce the exact CI path from a saved changed-files payload
python .github/scripts/validate-aseprite-files.py --changed-files-json payload.json

# Full workflow run under act (needs Docker + act)
bash .github/scripts/act-test-audio-validation.sh
```

### Pinning third-party actions

`Scony/godot-gdscript-toolkit` and `josephbmanley/butler-publish-itchio-action` are still on
`@master`. The butler one receives `BUTLER_CREDENTIALS`, so an upstream compromise would leak the
itch.io key. `tj-actions/changed-files` is on `@v46`; that action was compromised through v45 in
March 2025, so a floating tag is a real risk rather than a theoretical one.

Resolve each to an immutable commit SHA:

```bash
gh api repos/Scony/godot-gdscript-toolkit/commits/master --jq .sha
gh api repos/josephbmanley/butler-publish-itchio-action/commits/master --jq .sha
gh api repos/tj-actions/changed-files/commits/v46 --jq .sha
```

Then replace `@master` / `@v46` with `@<sha> # <tag>`. These were left unpinned rather than pinned to
a guessed SHA — a wrong digest fails the workflow with an unhelpful error.

## Not included

`rig-pipeline-tests.yml` from `J:\game-jam-references` is the most sophisticated workflow in the
collection but depends on the `addons/rig_pipeline` addon and specific model fixtures, so it cannot
run in a fresh jam repo. Three patterns in it are worth copying when a project needs them:

- **Negative gates** — assert a probe exits *non-zero* on inputs it should reject, so a validation
  gate that has quietly stopped gating fails the build instead of passing everything.
- **Golden-file regression** — `git diff --quiet` against a committed manifest catches silent output
  drift.
- **Deliberately uncached import** — a from-scratch `godot --import` proves the committed `.import`
  sidecars are actually complete, which a warm cache hides.
