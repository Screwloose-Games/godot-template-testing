# Asset Naming Conventions — PascalCase Variant

**This is a thought experiment, not a rule.** It shows what this project's naming spec
would look like if it fully embraced Unreal Engine's style: uppercase type prefixes,
PascalCase asset names, and single-letter texture suffixes.

> The conventions actually in force are in [`file-naming-spec.md`](file-naming-spec.md),
> and the source of truth is [`documentation/pipeline/pipeline.yaml`](pipeline/pipeline.yaml).
> Nothing on this page is enforced. Nothing on this page matches a committed asset.
> Read [What this would cost](#what-this-would-cost) before taking it seriously.

Every reference below points at Godot 4 documentation — the naming style is Unreal's, the
engine is not.

## The shape

```
[AssetTypePrefix]_[AssetName]_[Descriptor]_[OptionalVariant]
```

- **AssetTypePrefix** — an uppercase abbreviation of the asset's type. See the table below.
- **AssetName** — the asset's name, in `PascalCase`. No underscores inside the name.
- **Descriptor** — extra context, where it means something. For a texture, which map it is.
- **OptionalVariant** — a two-digit number or a letter, only when there is more than one version.

```
SM_RainBarrel.gltf              ✅
SM_OfficeBuildingSmall.gltf     ✅
T_RainBarrel_N.png              ✅
T_RainBarrel_D_02.png           ✅
sm_rain_barrel.gltf             ❌  the current convention
SM_Rain_Barrel.gltf             ❌  underscores inside the name
SM_rainBarrel.gltf              ❌  camelCase
```

Folders follow the same rule: `Assets/3D/Structures/RainBarrel/`, not `assets/3d/structures/rain_barrel/`.

## Asset type prefixes

Unreal's table lists types Godot does not have — Blueprints, Material Instances, NDisplay
configurations, OCIO profiles, Level Sequences. Below is the equivalent table built from
the types this project actually uses, with the closest Unreal prefix for each.

| Asset | Godot type | Prefix | Example |
| --- | --- | --- | --- |
| Static mesh | [imported glTF scene](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/index.html) | `SM_` | `SM_RainBarrel.gltf` |
| Skeletal mesh | imported glTF with an armature | `SK_` | `SK_Wolf.gltf` |
| Texture | [imported image](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html) | `T_` | `T_RainBarrel_N.png` |
| Material | [StandardMaterial3D / ORMMaterial3D](https://docs.godotengine.org/en/stable/tutorials/3d/standard_material_3d.html) | `M_` | `M_RainBarrel.tres` |
| Physics material | [PhysicsMaterial](https://docs.godotengine.org/en/stable/classes/class_physicsmaterial.html) | `PM_` | `PM_Ice.tres` |
| Model container scene | inherited [PackedScene](https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html) | `SM_` / `SK_` | `SM_RainBarrel.tscn` |
| Prefab scene | PackedScene | `BP_` | `BP_RainBarrel.tscn` |
| Level scene | PackedScene | `L_` | `L_Main.tscn` |
| Test level | PackedScene | `TL_` | `TL_Main.tscn` |
| Sprite source | Aseprite source file | `SPR_` | `SPR_Spider.aseprite` |
| Sprite sheet | [SpriteFrames source image](https://docs.godotengine.org/en/stable/tutorials/2d/2d_sprite_animation.html) | `SS_` | `SS_Spider_Walk.png` |
| Animation library | [AnimationLibrary](https://docs.godotengine.org/en/stable/tutorials/animation/introduction.html) | `AS_` | `AS_Wolf_Run.tres` |
| Sound | [imported audio sample](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_audio_samples.html) | `A_` | `A_DoorOpen.wav` |
| Theme | [Theme](https://docs.godotengine.org/en/stable/tutorials/ui/gui_skinning.html) | `UI_` | `UI_Main.tres` |
| Data asset | any other [Resource](https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html) | `DA_` | `DA_GameSettings.tres` |
| Script | [GDScript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html) | *none* | `PlayerController.gd` |

Notes on the mapping:

- **`BP_` for prefabs** is the honest Unreal equivalent — a Blueprint is Unreal's
  reusable, self-contained object, and a Godot `PackedScene` fills the same role. It reads
  oddly in a Godot project, because there is no such thing as a Blueprint here.
- **`SM_` / `SK_` for the model container scene** keeps the mesh's full stem, so
  `SM_RainBarrel.gltf` and `SM_RainBarrel.tscn` still read as one unit. Unreal has no
  separate container asset, so there is no prefix to borrow.
- **`TL_` for test levels** is invented. Unreal's guide has no test-level convention; the
  current spec expresses this as a `test_` prefix on the level name.
- **Scripts take no prefix.** Unreal names source files after the class in PascalCase and
  puts the type marker on the class (`AActor`, `UObject`, `FVector`), not the filename. The
  Godot equivalent is naming the file after its `class_name` — so `PlayerController.gd`
  declares `class_name PlayerController`. Note this contradicts Godot's own
  [style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html),
  which specifies `snake_case` script filenames.
- **Generated files keep whatever name generated them.** A glTF's `.bin` buffer is
  referenced by URI from inside the `.gltf`, so it follows the mesh:
  `SM_RainBarrel.bin`. Import sidecars keep the full filename:
  `SM_RainBarrel.gltf.import`. Model specs likewise: `SM_RainBarrel.gltf.spec.yaml`.

## Texture suffixes

Unreal's scheme puts the map type in a short suffix rather than a spelled-out descriptor.

| Suffix | Map | Godot material slot |
| --- | --- | --- |
| `_D` | Diffuse / Albedo / Base Color | Albedo |
| `_N` | Normal | Normal Map — only the red and green channels are used |
| `_R` | Roughness | Roughness |
| `_M` | Metallic | Metallic |
| `_AO` | Ambient Occlusion | Ambient Occlusion |
| `_E` | Emissive | Emission |
| `_H` | Height / Bump | Height / parallax |
| `_A` | Alpha / Opacity | Albedo alpha |
| `_ORM` | Packed occlusion + roughness + metallic | `ORMMaterial3D` — AO in R, roughness in G, metallic in B |

See [StandardMaterial3D and ORMMaterial3D](https://docs.godotengine.org/en/stable/tutorials/3d/standard_material_3d.html).

> **`_M` is ambiguous in Unreal's own guide** — it is listed for both Metallic and Mask.
> Adopting the suffix scheme means picking one and documenting the choice. This variant
> assigns `_M` to Metallic and gives Mask no suffix, because this project has no masks.

The spelled-out descriptors in the current spec (`_basecolor`, `_normal`, `_orm`) are
longer but unambiguous, and they are what the exporter emits without a custom pattern.

## Where files live

| Path | What goes there |
| --- | --- |
| `Assets/3D/{Category}/{Object}/` | Everything for one 3D object: mesh, `.bin`, textures, `.import` sidecars, container scene, spec |
| `Prefabs/{Category}/` | Prefab scenes, using the same category names as `Assets/3D/` |
| `Levels/` | Shipping level scenes |
| `Test/Levels/` | Scratch levels. Not shipped |
| `Game/{GameObject}/` | 2D art. Optionally nested as `Game/{GameObject}/Animations/` |
| `addons/` | Third-party plugins — **must stay lowercase**, Godot hard-codes `res://addons/` |

One directory per object, so a re-export touches nothing else.

## What this would cost

The reason this is a separate file and not a proposal.

**Godot generates lowercase names.** Save a new scene or attach a new script and the
editor derives a `snake_case` filename from the node name. Every file Godot creates would
need renaming by hand, every time, by every contributor.

**Case sensitivity breaks exports.** Godot's
[project organization](https://docs.godotengine.org/en/stable/tutorials/best_practices/project_organization.html)
page recommends `snake_case` specifically because Linux filesystems are case-sensitive
while Windows and macOS are not. A path that resolves on a developer's Windows machine can
fail in the Linux and web export builds. This project ships to web.

**Some paths cannot change.** `res://addons/`, `project.godot`, `.godot/`, and
`export_presets.cfg` are fixed by the engine. `default_bus_layout.tres` is only the
default — the path is overridable via the `audio/buses/default_bus_layout` project
setting, though this project does not override it. Either way the tree ends up PascalCase
with lowercase islands in it.

**Every CI regex would need rewriting.** The patterns in `pipeline.yaml` and the constants
they mirror in `.github/scripts/` are all built on `^[a-z0-9]+(_[a-z0-9]+)*$`. Under this
variant they become roughly:

```
^[A-Z]{1,4}_[A-Z][A-Za-z0-9]*(_[A-Za-z0-9]+)*\.[a-z0-9]+$
```

That is a looser pattern — it can no longer tell a typo'd prefix from a legitimate one,
and it cannot distinguish `PascalCase` from `PASCALCASE`. The seven `code_mirrors` entries
in `pipeline.yaml` would each need updating in lockstep with their script constants, and
`PATH_CONVENTION_ROOT` would go from `game` to `Game`.

**Every committed asset would need renaming**, and every texture rename has to happen at
the exporter rather than in the filesystem, because the `.gltf` references its images by
URI. That is a re-export of every model, not a `git mv`.

**It does not fix the thing it looks like it fixes.** The prefix scheme is already in use
here — `sm_`, `sk_`, `t_`, `prefab_`, `level_`. The only difference this variant makes is
casing. The sorting and at-a-glance-identification benefits Unreal's guide argues for are
already delivered by the lowercase form.

## Reference

Godot 4 documentation:

- [Project organization](https://docs.godotengine.org/en/stable/tutorials/best_practices/project_organization.html) — folder layout and file casing
- [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html) — the naming table for scripts, classes, nodes
- [Import process](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/import_process.html) — `.import` sidecars and `.godot/imported/`
- [Importing 3D scenes](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/index.html)
- [Importing images](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html)
- [Importing audio samples](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_audio_samples.html)
- [Resources](https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html) — `.tres` vs `.res`
- [StandardMaterial3D and ORMMaterial3D](https://docs.godotengine.org/en/stable/tutorials/3d/standard_material_3d.html)
- [PhysicsMaterial](https://docs.godotengine.org/en/stable/classes/class_physicsmaterial.html)
- [2D sprite animation](https://docs.godotengine.org/en/stable/tutorials/2d/2d_sprite_animation.html)
- [Introduction to the animation features](https://docs.godotengine.org/en/stable/tutorials/animation/introduction.html)
- [Introduction to GUI skinning](https://docs.godotengine.org/en/stable/tutorials/ui/gui_skinning.html) — Theme resources

In this repo:

- [`documentation/file-naming-spec.md`](file-naming-spec.md) — the conventions actually in force
- [`documentation/pipeline/pipeline.yaml`](pipeline/pipeline.yaml) — the source of truth
- [`documentation/pipeline/PIPELINE.md`](pipeline/PIPELINE.md) — how to deliver an asset, end to end
