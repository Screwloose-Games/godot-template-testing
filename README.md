# Godot Jam Template

A Screwloose Games starter template for game-jam projects in Godot 4.7 (GL Compatibility, web-first).

Out of the box you get: a main menu → level flow with scene transitions, an options menu with persisted settings, a pause menu, a global signal bus, a sound manager, and a full GitHub Actions pipeline (lint, asset validation, web build, itch.io publish).

## New-project checklist

1. **Create the repo** from this template (GitHub → *Use this template*), then clone it.
2. **Rename the game**: in `project.godot` set `config/name`; in `common/ui/main_menu/main_menu.tscn` change the `TitleLabel` text; update the title in `ATTRIBUTION.md` and this README.
3. **CI for itch.io publishing** (repo → Settings):
   - Variables: `ITCH_USER` (itch.io account), `ITCH_GAME` (itch.io project slug)
   - Secret: `BUTLER_CREDENTIALS` (butler API key)
   - Godot version is pinned via `GODOT_VERSION` in `.github/workflows/build-godot-game.yml`.
4. **Release flow**: push a tag like `v0.1.0` → `build-godot-game.yml` builds the **Web** export preset → `publish-to-itchio.yml` pushes it to itch.io (channel `web`). The Web preset name in `export_presets.cfg` must stay `"Web"`.
5. **Code owners**: uncomment and set the owner in `.github/CODEOWNERS` if you want required reviews.
6. **Pre-commit hooks**: `pip install pre-commit && pre-commit install` (runs `gdlint` + `gdformat --check`).
7. **Credits**: edit `ATTRIBUTION.md` — the credits screen auto-scrolls it.

## Project structure

```
common/
  audio/        Title music + UI SFX (buses: Master, SFX, Music, Ambient, Dialogue)
  fonts/        UI font
  themes/       Global UI theme (theme.tres)
  ui/
    main_menu/          Main menu (main scene)
    options_menu/       Volume sliders + windowed/fullscreen toggle
    pause_menu/         In-game pause overlay (Esc / P)
    scene_transitions/  Fade + circle transitions
    screens/            Credits (auto-scrolls ATTRIBUTION.md)
globals/        Autoload singletons
  global_signal_bus.gd        App-wide signals (add your game's signals here)
  scene_manager.gd            PackedScene registry (main_level, main_menu, ...)
  scene_transition_manager.gd change_scene_with_transition(scene, transition)
  game_settings.tscn          Loads/saves settings to user://settings.tres
  sound_manager/              UI/ambient/SFX players + signal-driven sound connectors
levels/
  level_01/     Placeholder first level (emits level_started; wire your game here)
tools/          Helper scripts (audio filename fixer, meeting transcript fetcher)
schemas/        JSON schema for GitHub issue form templates
```

## How things connect

- **Start game**: main menu → `SceneTransitionManager.change_scene_with_transition(SceneManager.main_level, SceneManager.fade_transition)`
- **Signals**: gameplay/UI events go through the `GlobalSignalBus` autoload; the sound manager plays SFX by listening to bus signals via `sound_effect.gd` connector nodes in `SoundManager.tscn` — no audio calls needed in gameplay code.
- **Audio settings**: options menu sliders set `AudioServer` bus volumes and persist via the `GameSettings` autoload (`user://settings.tres`); reapplied on startup.
- **Music**: `globals/sound_manager/music_player_looper.gd` plays an intro track once, then loops a main track.
- **Pause**: `pause` input action (Esc or P) toggles the pause menu instanced in the level.
- **Credits**: renders `ATTRIBUTION.md` — edit that file to update the credits screen.
- **New levels**: add a scene under `levels/`, register it in `globals/scene_manager.gd`.
- **Physics layers**: if you name layers in Project Settings, mirror them in a small `globals/physics_layers.gd` constants class so code never hardcodes layer numbers.

## CI workflows

| Workflow | When | What |
|---|---|---|
| `build-godot-game.yml` | `v*` tag | Headless web export (adds `coi-serviceworker.js` for itch.io) |
| `publish-to-itchio.yml` | after successful build | Pushes web build to itch.io via butler |
| `gdlint-on-pull-request.yml` | PR touching `.gd` | Lints changed GDScript |
| `check-gdscript-complexity.yml` | PR touching `.gd` | Cyclomatic-complexity report comment |
| `check-import-files.yml` | PR touching assets | Auto-commits missing/changed `.import` files |
| `validate-audio-files.yml` | PR touching audio | Filename convention, size, and WAV spec checks |
| `validate-gltf-files.yml` | PR touching `.gltf/.glb` | GLTF validation |
| `flag-fbx-files.yml` / `flag-mp3-files.yml` | PR adding `.fbx`/`.mp3` | Blocks disallowed formats with guidance |

Issue templates under `.github/ISSUE_TEMPLATE/` cover the asset-request workflow (SFX, ambient audio, models, textures, animations, implementation tasks, bug reports).

## Export

Renderer is GL Compatibility for web (itch.io) export. Presets exist for Web, Windows, macOS, and Linux; the release pipeline uses **Web**.
