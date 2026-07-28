---
name: generate-placeholder-audio
description: Generate, create or stub placeholder audio assets for this Godot game - silent or tone temp music, ambient beds, sound effects, SFX, vocal barks and voice-over lines as .ogg or .wav. Use when wiring an audio hook before the real asset exists, when a scene needs a stand-in sound, or to audit which placeholder audio still needs replacing before release.
---

# Generate placeholder audio

Silent (or optionally audible) stand-in audio so gameplay hooks can be wired and
playtested before the real assets exist. Every file is tagged as a placeholder so
`--audit` can find it again before release.

**Everything goes through one driver — do not hand-write `ffmpeg` commands:**

```
.claude/skills/generate-placeholder-audio/generate_placeholder_audio.py
```

Paths below are relative to the repo root. The driver locates the repo itself by
walking up to `project.godot`, so it works from any cwd.

## Why the driver and not raw ffmpeg

This repo fails PRs on off-spec audio via
`.github/workflows/validate-audio-files.yml` → `.github/scripts/validate-audio-files.py`.
The driver **imports `FILENAME_PATTERN` and `WAV_FILE_SPECIFICATIONS` from that
validator** rather than duplicating them, then runs the validator against its own
output before exiting. It also writes the Godot `.import` sidecar that
`check-import-files.yml` requires.

## Prerequisites

ffmpeg (which bundles ffprobe) on PATH. Verified with 6.0:

```bash
ffmpeg -version | head -1
ffprobe -version | head -1
```

No Python packages — stdlib only.

## Generate (agent path)

```
--kind    music | ambient | sfx | bark | dialog
--name    file stem, lowercase_with_underscores, no extension
--duration seconds
```

| kind | format | ch | default dir | cap |
|---|---|---|---|---|
| `music` | `.ogg` vorbis 192k | 2 | `common/audio/music` | 49 MB |
| `ambient` | `.ogg` vorbis 192k | 2 | `common/audio/ambient` | 49 MB |
| `sfx` | `.wav` pcm_s16le | 1 | `common/audio/sfx` | **10 s** |
| `bark` | `.wav` pcm_s16le | 1 | `common/audio/vo` | **10 s** (warns >3 s) |
| `dialog` | `.ogg` vorbis 192k | 1 | `common/audio/vo` | 49 MB |

All 44100 Hz, 16-bit. Commands actually run:

```bash
D=.claude/skills/generate-placeholder-audio/generate_placeholder_audio.py

# looping music bed
python $D --kind music --name gladdy_bgm_arena_theme_loop_v1 --duration 12 --ticket AUDIO-101

# sound effect, audible tone instead of silence
python $D --kind sfx --name sfx_sword_hit --duration 0.4 --ticket AUDIO-123 --tone

# vocal bark
python $D --kind bark --name gladdy_vo_gladiator_taunt_v1 --duration 2 --desc "gladiator taunt"

# voice-over dialog line
python $D --kind dialog --name gladdy_vo_caddy_intro_line_v1 --duration 6
```

Output (real):

```
wrote common\audio\sfx\sfx_sword_hit.wav  [pcm_s16le, 44100 Hz, 1 ch, 16-bit, 0.40s, 34.8 KiB]
wrote common\audio\sfx\sfx_sword_hit.wav.import

verifying against .github\scripts\validate-audio-files.py ...
all generated files pass CI audio validation.
```

Useful flags: `--dest <dir>` (override the directory, e.g. a character folder),
`--tone` (audible instead of silent), `--desc` (what the real asset will be),
`--dry-run` (print the ffmpeg command only), `--force`, `--no-verify`.

### Batch

TSV: `kind<TAB>name<TAB>duration[<TAB>ticket[<TAB>description]]`. `#` comments and
blank lines are skipped.

```bash
printf '# kind\tname\tduration\tticket\tdescription\n'\
'sfx\tsfx_shield_block\t0.5\tAUDIO-124\tshield block thud\n'\
'sfx\tsfx_coin_pickup\t0.3\tAUDIO-125\t\n'\
'ambient\tamb_colosseum_crowd_loop\t20\tAUDIO-126\tcrowd bed\n' > /tmp/pl.tsv

python $D --manifest /tmp/pl.tsv
```

### Audit — what still needs real audio

```bash
python $D --audit
```

```
5 placeholder asset(s) still need real audio:

  common/audio/ambient/amb_colosseum_crowd_loop.ogg      AUDIO-126
  common/audio/music/gladdy_bgm_arena_theme_loop_v1.ogg  AUDIO-101
  common/audio/sfx/sfx_coin_pickup.wav                   AUDIO-125
```

Real tracks are correctly excluded — detection is by metadata, not filename.
`--audit-root <dir>` narrows the scan (default `common/audio`).

## Verify

The driver self-verifies, but to check by hand:

```bash
python .github/scripts/validate-audio-files.py common/audio/sfx/sfx_sword_hit.wav
ffprobe -v error -show_entries stream=codec_name,sample_rate,channels,bits_per_sample -of csv=p=0 common/audio/sfx/sfx_sword_hit.wav
# -> pcm_s16le,44100,1,16
```

For many files use `--file-list`, never `$(cat list.txt)` — see the word-splitting
warning at the top of `validate-audio-files.py`.

## Godot import

The driver writes the `.import` sidecar itself, deliberately **omitting `uid=`,
`path=` and `dest_files=`** (inventing a `uid://` would create a bogus resource id).
Godot fills those in on the next scan and **preserves the `loop=true`** the driver set.
Trigger it with the `godot-ai` MCP without leaving the session:

```
filesystem_manage(op="scan")
audio_manage(op="list", params={"root": "res://common/audio"})
```

Confirmed round-trip: `loop=true` survived, and
`audio_manage(op="player_set_stream", ...)` returned `duration_seconds: 0.4` for the
generated WAV, then `op="play"` on the `SFX` bus produced `playing: true`.

If no editor is running, pass `--godot-import` (needs `godot` on PATH or `$GODOT_BIN`)
to run `godot --headless --import` instead.

## Gotchas

- **Ogg Vorbis comments live on the *stream*, not the format.**
  `ffprobe -show_entries format_tags` returns `{}` for a `.ogg` and looks like the
  metadata vanished. Use `stream_tags` (the driver reads both and merges).
- **WAV silently drops custom metadata keys.** RIFF INFO only carries
  `title`/`artist`/`comment`; `-metadata asset_role=...` on a `.wav` is discarded
  without warning. That is why the placeholder marker is embedded *inside the comment
  string* for WAV, and as real fields for Ogg.
- **CI requires WAV to be MONO.** The repo's existing `common/audio/sfx/ui/aud_ui_*.wav`
  are stereo and would fail the validator today. Don't copy their shape.
- **The CI filename regex rejects hyphens.** `common/audio/music/music_title_screen-loop.ogg`
  already fails it. Use `_loop`, never `-loop`.
- **`_loop` is a token, not a suffix.** The music guide's own example is
  `main_theme_loop_v4.ogg`, so an `endswith("_loop")` test misses it. The driver
  matches `(^|_)loop(_|$)` — this was a real bug found during verification.
- **Godot's Vorbis importer ignores `LOOP`/`LOOP_POINT` tags.** Looping comes from
  `loop=true` in the `.ogg.import` (and `edit/loop_mode` for WAV). The driver writes
  both: the tags for humans and external tools, the flag for the engine.
- **`edit/loop_mode` on the WAV importer is an enum index, not a bool.** The options are
  `Detect From WAV,Disabled,Forward,Ping-Pong,Backward`, so **`1` means Disabled** and
  looping is **`2`**. The driver wrote `1` for looping WAVs until this was caught by
  `AudioStreamWAV.loop_mode` coming back `LOOP_DISABLED` at runtime on a file whose
  `.import` clearly said the loop was on. `.ogg`'s `loop` really is a bool; only WAV is
  an index. If you have older placeholders, check them:
  `grep -l 'edit/loop_mode=1' common/audio/**/*.import`
- **ffmpeg's `sine` filter emits at amplitude 1/8 (≈ -18.1 dBFS), not full scale.**
  Already a safe audible level under the guides' -1 dBFS ceiling — don't add gain.
  Note `alimiter`'s auto-level will *quieten* it further (measured -29 dB); the driver
  doesn't use it.
- **Windows filenames are case-insensitive, Linux CI's are not.** Generating
  `ui_click.wav` next to the existing `UI_CLICK.wav` collides locally but would not on
  CI. The overwrite guard catches it either way.
- **The overwrite guard is metadata-based:** regenerating over your own placeholder is
  fine, but the driver refuses to flatten a real asset unless you pass `--force`.
- `--dest` outside the project skips the sidecar entirely — `res://` can't address it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `error: filename '...' fails the CI naming rule` | lowercase/digits/underscores only; drop hyphens, capitals, spaces, punctuation |
| `error: WAV placeholders are capped at 10s by CI` | use `--kind music` or `--kind ambient` (`.ogg`) for anything longer |
| `error: ... already exists and is NOT a placeholder` | you're about to overwrite real audio; rename, or `--force` if intentional |
| `warning: barks should be 3s or shorter` | advisory only (voice-over guide); the file is still written |
| `ffprobe` shows no tags on a `.ogg` | you queried `format_tags`; use `stream_tags` |
| `.import` has no `uid` | expected — run `filesystem_manage(op="scan")` or open the editor once |
| `note: no Godot binary found` | set `GODOT_BIN`, or drop `--godot-import` and let the editor scan |

## Spec sources

Screwloose documentation, `content/guides/audio/`: `how_to_contribute_music.md`,
`how_to_contribute_sound_effects.md`, `how_to_contribute_voice_over.md`,
`how_to_make_looping_audio_tracks.md`. Enforcement lives in
`.github/scripts/validate-audio-files.py` — change specs there, not in the driver.
