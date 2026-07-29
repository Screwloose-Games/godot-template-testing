# Godot Jam Template

A Godot 4.7 game-jam template: shared systems, an asset pipeline, and the CI that
enforces it. Web-first build using the GL Compatibility renderer, so frame and
texture budgets are tight.

## Orientation

| Path | What it is |
|---|---|
| `documentation/pipeline/pipeline.yaml` | **The authoritative pipeline.** Phases, steps, rules, naming conventions. |
| `documentation/pipeline/PIPELINE.md` | **Generated** from the above. Do not hand-edit. |
| `.github/scripts/validate-*.py` | The pass/fail gates. Also run by pre-commit and by Claude Code hooks. |
| `tools/gltf-validator/` | The 3D model checks, importable without Docker. |
| `tools/blender-vehicle/` | Procedural vehicle toolkit + the retrospective that produced it. |
| `.claude/rules/` | Path-scoped rules that load when you touch matching files. |
| `assets/3d/`, `game/` | 3D assets and 2D art. Deliberately different roots. |
| `examples/` | Self-contained "is this loop fun?" prototypes. Exempt from shared conventions on purpose — do not tidy them into line. |

## Generated files

Several files are generated and validated for drift, so editing them by hand gets
reverted or fails CI:

- `documentation/pipeline/PIPELINE.md` ← `tools/pipeline/render_pipeline.py`
- The `<!-- pipeline:subtasks -->` blocks in `.github/ISSUE_TEMPLATE/*.yaml`
  ← `tools/pipeline/render_issue_templates.py`

Change `pipeline.yaml`, then re-render. `validate-pipeline-doc.py` fails CI when
the doc drifts from the constants in the validators.

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
