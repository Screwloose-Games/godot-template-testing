# Godot Jam Template

A Godot 4.7 game-jam template: shared systems, an asset pipeline, and the CI that
enforces it. Web-first build using the GL Compatibility renderer, so frame and
texture budgets are tight.

## Orientation

| Path | What it is |
|---|---|
| `documentation/pipeline/pipeline.yaml` | **The authoritative pipeline.** Phases, steps, rules, naming conventions. |
| `documentation/pipeline/PIPELINE.md` | **Generated** from the above. Do not hand-edit. |
| `documentation/pipeline/backlog/` | **Hand-authored input.** Issues to open, one file per issue template. Edit freely — nothing regenerates these. |
| `tools/pipeline/pipeline.py` | **The pipeline CLI.** Board reports, issue creation and bulk filing, and every generated doc. `--help` lists it. |
| `.github/scripts/validate-*.py` | The pass/fail gates. Also run by pre-commit and by Claude Code hooks. |
| `tools/gltf-validator/` | The 3D model checks, importable without Docker. |
| `tools/blender-vehicle/` | Procedural vehicle toolkit + the retrospective that produced it. |
| `.claude/rules/` | Path-scoped rules that load when you touch matching files. |
| `assets/art/3d/`, `assets/art/2d/` | 3D assets and 2D art, siblings under `assets/art/`. |
| `examples/` | Self-contained "is this loop fun?" prototypes. Exempt from shared conventions on purpose — do not tidy them into line. |

## Generated files

Several files are generated and validated for drift, so editing them by hand gets
reverted or fails CI:

- `documentation/pipeline/PIPELINE.md` ← `pipeline.py render pipeline`
- The `<!-- pipeline:subtasks -->` blocks in `.github/ISSUE_TEMPLATE/*.yaml`
  ← `pipeline.py render issue-templates --write`
- `documentation/pipeline/images/` ← `pipeline.py extract images`
- `documentation/pipeline/asset_list.tsv` ← `pipeline.py asset list --write`
  (from the GitHub project board, not from `pipeline.yaml`; TSV has no comment
  syntax, so the file cannot say this itself. `--check` needs `read:project`
  and the network, so it is a local command and never a PR gate.)

(All under `tools/pipeline/`.) Change `pipeline.yaml`, then re-render. `validate-pipeline-doc.py` fails CI when
the doc drifts from the constants in the validators.

## Hand-authored input

`documentation/pipeline/backlog/*.yaml` is the one place under
`documentation/pipeline/` that runs the other way. Nothing generates these and
nothing overwrites them:

```
pipeline.py backlog new --template create_model   # scaffold one
pipeline.py backlog file                          # dry run: validate every entry
pipeline.py backlog file --apply                  # open the issues
```

`--apply` writes `issue: <number>` back into each entry it files, and an entry
that has one is skipped — so re-running the command is both safe and the way to
resume after a failure. Not a CI gate: even a dry run reads organization fields
over the network.

Two different YAML documents live here, so the names matter. `pipeline.yaml` is
**the pipeline document** — one file, authoritative. `backlog/*.yaml` are
**backlog files** — a queue of issues to open. Never call either one "the yaml".

## Before committing

Run the gate for whatever you touched — the same commands CI runs:

```
python .github/scripts/validate-model-files.py <model>    # 3D
python .github/scripts/validate-aseprite-files.py <file>  # 2D
python .github/scripts/validate-audio-files.py <file>     # audio
gdformat <file> && gdlint <file>                          # GDScript
```

`pre-commit install` wires these up so a commit fails before CI does.

## Conventions worth knowing up front

- **Naming:** `[prefix]_[asset_name]_[descriptor]_[variant]`, lowercase with
  underscores. `sm_` static mesh, `sk_` skeletal, `t_` texture,
  `prefab_`/`level_` scenes. No hyphens, no `.fbx`, ever.
- **Facing:** models are built facing +Y in Blender, which exports to −Z — Godot's
  `Vector3.FORWARD`. This is deliberately *not* the glTF spec's +Z-front
  convention; matching the engine matters more than matching viewers.
- **Units:** metres, 1 Blender unit = 1 m.
- **GDScript declaration order is linted** (`class_name` above `extends`). See
  `.claude/rules/gdscript-style.md`.
- **Commit `.import` sidecars** alongside every asset. Godot hides them in its own
  dock; check the OS file explorer.

## Working here

Prefer changing the rule over changing the file that broke it. Most conventions in
this repo are enforced by a script, and the script and the doc are kept in sync on
purpose — so if a rule is wrong, fix it in `pipeline.yaml` and re-render rather
than working around it in one asset.
