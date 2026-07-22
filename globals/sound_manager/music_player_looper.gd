class_name MusicPlayerLooper
extends Node

signal intro_started
signal loop_started
signal stopped

@export var intro_player: AudioStreamPlayer
@export var loop_player: AudioStreamPlayer
@export var autoplay_on_ready: bool = true

func _ready() -> void:
    _resolve_players()
    if not _has_players():
        return

    if autoplay_on_ready:
        play_music()

func play_music() -> void:
    if not _has_player_streams():
        return

    _stop_music(false)

    intro_player.play()
    intro_started.emit()
    loop_player.stream.loop = true

    var intro_length := intro_player.stream.get_length()
    get_tree().create_timer(intro_length).timeout.connect(
        func() -> void: _switch_stream_to_loop()
    )

func stop_music() -> void:
    _stop_music(true)

func _switch_stream_to_loop() -> void:
    if not _has_player_streams():
        return

    loop_player.play()
    loop_started.emit()

func _stop_music(emit_stopped_signal: bool) -> void:
    if intro_player != null:
        intro_player.stop()

    if loop_player != null:
        loop_player.stop()

    if emit_stopped_signal:
        stopped.emit()

func _resolve_players() -> void:
    if intro_player == null:
        intro_player = get_node_or_null("IntroPlayer") as AudioStreamPlayer

    if loop_player == null:
        loop_player = get_node_or_null("LoopPlayer") as AudioStreamPlayer


func _has_players() -> bool:
    if intro_player == null:
        return false

    if loop_player == null:
        return false

    return true

func _has_player_streams() -> bool:
    if intro_player == null:
        return false

    if intro_player.stream == null:
        return false

    if loop_player == null:
        return false

    if loop_player.stream == null:
        return false

    return true
