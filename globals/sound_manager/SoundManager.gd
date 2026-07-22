class_name GSoundManager
extends AudioStreamPlayer

## Owns the game's shared audio players.
##
## UI, AMBIENT and WEATHER are one player each: those are single sustained or
## non-overlapping cues, and a new one is meant to replace whatever the last one was.
## SFX is not like that — combat fires several one-shots on the same frame — so it is a
## pool of interchangeable voices instead of a single player. See play_sound().

enum SoundPlayerType {
	UI,
	AMBIENT,
	WEATHER,
	SFX,
}

## How many SFX one-shots can sound at once. A single game event can easily spend
## several voices (an impact, a weapon layer, a damage layer) and multiple actors can
## fire on the same frame, so the floor here is much higher than it looks.
const SFX_VOICE_COUNT: int = 16
## Matches the UI player. The generated placeholders sit around -18 dBFS, so this is
## headroom for real assets rather than a level tuned to the tones.
const SFX_VOICE_VOLUME_DB: float = -10.0

## Built in _ready() rather than authored in SoundManager.tscn: sixteen identical
## players are noise in the scene, and nothing outside this script addresses one by name.
var _sfx_voices: Array[AudioStreamPlayer] = []
## Where the next hand-out starts looking. Advancing it even on a hit keeps successive
## one-shots spread across the pool instead of piling onto voice 0.
var _next_sfx_voice: int = 0

@onready var ui_sound_player: AudioStreamPlayer = %UiSoundPlayer
@onready var weather_sound_player: AudioStreamPlayer = %WeatherSoundPlayer
@onready var ambient_sound_player: AudioStreamPlayer = %AmbientSoundPlayer


func _ready() -> void:
	for i in SFX_VOICE_COUNT:
		var voice := AudioStreamPlayer.new()
		voice.name = "SfxVoice%d" % i
		voice.bus = &"SFX"
		voice.volume_db = SFX_VOICE_VOLUME_DB
		add_child(voice)
		_sfx_voices.append(voice)


## The single player behind a player type, or null for SFX — that type is a pool, and no
## one voice in it is "the" SFX player. Callers that just want a sound to come out should
## use play_sound(), which handles both shapes.
func get_sound_player(player_type: SoundPlayerType):
	match player_type:
		SoundPlayerType.UI:
			return ui_sound_player
		SoundPlayerType.WEATHER:
			return weather_sound_player
		SoundPlayerType.AMBIENT:
			return ambient_sound_player
		_:
			return null


## Returns the player the sound went to, so a caller that needs to follow it — stop it
## early, fade it — can. Null means nothing played.
func play_sound(sound: AudioStream, player_type: SoundPlayerType) -> AudioStreamPlayer:
	if sound == null:
		return null
	if player_type == SoundPlayerType.SFX:
		return _play_on_free_voice(sound)
	var player: AudioStreamPlayer = get_sound_player(player_type)
	if player == null:
		return null
	player.stream = sound
	player.play()
	return player


## Silences a single-player type. Deliberately does nothing for SFX: the pool has no one
## sound to stop, and a sustained cue that has to be stoppable owns its own player
## instead — see SoundEffectConnector.
func stop_sound(player_type: SoundPlayerType) -> void:
	var player: AudioStreamPlayer = get_sound_player(player_type)
	if player == null:
		return
	player.stop()


## Hands out the first voice that is not already sounding, so overlapping one-shots layer
## instead of cutting each other off. With every voice busy it takes the one the cursor
## landed on and steals it: clipping the oldest sound reads better than dropping the
## newest, which is the one the player just caused.
func _play_on_free_voice(sound: AudioStream) -> AudioStreamPlayer:
	if _sfx_voices.is_empty():
		return null
	var count: int = _sfx_voices.size()
	var voice: AudioStreamPlayer = _sfx_voices[_next_sfx_voice]
	for offset in count:
		var candidate: AudioStreamPlayer = _sfx_voices[(_next_sfx_voice + offset) % count]
		if not candidate.playing:
			voice = candidate
			_next_sfx_voice = (_next_sfx_voice + offset) % count
			break
	_next_sfx_voice = (_next_sfx_voice + 1) % count
	voice.stream = sound
	voice.play()
	return voice
