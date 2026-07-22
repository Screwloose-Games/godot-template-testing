class_name SoundEffectConnector
extends Node

## Plays one sound when one signal fires, wired entirely from the scene — no per-sound
## script.
##
## Most gameplay signals are broader than the sound they should make: unit_swing covers
## the armed, unarmed and exhausted swings, unit_damage_resolved covers a fleshy hit and
## a clang the armor ate. Splitting those is what the three condition dictionaries below
## are for. A connector with no conditions plays on every emission, which is what the
## original UI connectors do and still do.

# extends: https://docs.godotengine.org/en/stable/classes/class_@globalscope.html#enum-globalscope-error
enum TryConnectError {
	INSTANCE_INVALID = 49,
	NO_SIGNAL_NAME = 50,
	NO_MATCHING_SIGNAL_NAME = 51,
}

## Sustained cues sit under the one-shots rather than beside them — the two loops in the
## game today are laboured breathing and a drag scrape, both explicitly "low in the mix".
const LOOP_VOLUME_DB: float = -14.0

@export var player_type: GSoundManager.SoundPlayerType
@export_enum(
	"GlobalSignalBus",
	"QuestManager",
	"EnvironmentManager",
	"StructureManager",
	"SceneTransitionManager"
)
var global_name: String
@export var start_signal_name: String
## Set this and the connector stops being a one-shot: it takes its own player and the
## sound runs until this signal arrives. Looping itself comes from the asset's import flag.
@export var stop_signal_name: String
@export var sound_effect: AudioStream

## What the signal has to be carrying for this sound to play, as `path: expected`. A path
## is the argument index, optionally followed by `:`-separated property reads — so `"2"`
## is the third argument and `"0:definition:type"` is that argument's item def's type.
## Every entry must match. Empty plays on every emission.
@export var arg_conditions: Dictionary = {}
## The same paths, inverted: any entry that *does* match suppresses the sound. This is how
## "armored, and not fully absorbed" is said without a comparison operator.
@export var arg_conditions_not: Dictionary = {}
## `path: class_name`, for splits that turn on an argument's type rather than its value —
## a WeaponDef and an ArmorDef reach unit_equipped through the same parameter.
@export var arg_class_conditions: Dictionary = {}

var try_connect_start_result: int = FAILED
var try_connect_stop_result: int = FAILED

## Non-null only for a connector with a stop signal; see _create_loop_player().
var _loop_player: AudioStreamPlayer

@onready var signal_node = get_tree().get_root().get_node(global_name)
@onready var sound_manager = get_parent()


func _ready() -> void:
	if stop_signal_name != "":
		_create_loop_player()
	try_connect_stop_signal()
	try_connect_start_signal()


func try_connect_start_signal() -> int:
	signal_node = get_tree().get_root().get_node(global_name)
	sound_manager = get_parent()

	if not is_instance_valid(signal_node):
		try_connect_start_result = TryConnectError.INSTANCE_INVALID
		return TryConnectError.INSTANCE_INVALID

	if start_signal_name == "":
		try_connect_start_result = TryConnectError.NO_SIGNAL_NAME
		return TryConnectError.NO_SIGNAL_NAME

	if not signal_node.has_signal(start_signal_name):
		try_connect_start_result = TryConnectError.NO_MATCHING_SIGNAL_NAME
		return TryConnectError.NO_MATCHING_SIGNAL_NAME

	try_connect_start_result = signal_node.connect(start_signal_name, _on_start)
	return try_connect_start_result


func try_connect_stop_signal() -> int:
	signal_node = get_tree().get_root().get_node(global_name)
	sound_manager = get_parent()

	if not is_instance_valid(signal_node):
		try_connect_stop_result = TryConnectError.INSTANCE_INVALID
		return TryConnectError.INSTANCE_INVALID

	if stop_signal_name == "":
		try_connect_stop_result = TryConnectError.NO_SIGNAL_NAME
		return TryConnectError.NO_SIGNAL_NAME

	if not signal_node.has_signal(stop_signal_name):
		try_connect_stop_result = TryConnectError.NO_MATCHING_SIGNAL_NAME
		return TryConnectError.NO_MATCHING_SIGNAL_NAME

	try_connect_stop_result = signal_node.connect(stop_signal_name, _on_stop)
	return try_connect_stop_result


# The optional arguments are how this connector binds a signal that carries a payload.
# Four covers every signal on the bus today; a signal with more cannot be wired here.
# Unlike the stop side, these values are read rather than discarded — they are exactly
# what the condition dictionaries test.
func _on_start(a = null, b = null, c = null, d = null) -> void:
	if not _passes([a, b, c, d]):
		return
	if _loop_player != null:
		_loop_player.play()
		return
	sound_manager.play_sound(sound_effect, player_type)


# Deliberately unconditional: a sustained sound that outlives its stop cue is a worse
# failure than one that stops a beat early.
func _on_stop(_a = null, _b = null, _c = null, _d = null) -> void:
	if _loop_player != null:
		_loop_player.stop()
		return
	sound_manager.stop_sound(player_type)


## A sustained cue owns its player. The SFX voices are handed out per one-shot, so a
## connector that has to stop what it started cannot use one — by the time the stop
## signal arrives that voice is as likely to be carrying somebody else's sound.
func _create_loop_player() -> void:
	_loop_player = AudioStreamPlayer.new()
	_loop_player.name = "LoopPlayer"
	_loop_player.bus = &"SFX"
	_loop_player.volume_db = LOOP_VOLUME_DB
	_loop_player.stream = sound_effect
	add_child(_loop_player)


func _passes(args: Array) -> bool:
	for path in arg_conditions:
		if _resolve(args, path) != arg_conditions[path]:
			return false
	for path in arg_conditions_not:
		if _resolve(args, path) == arg_conditions_not[path]:
			return false
	for path in arg_class_conditions:
		if _class_name_of(_resolve(args, path)) != arg_class_conditions[path]:
			return false
	return true


## Walks a `"0:definition:type"` path: the leading number picks a signal argument, each
## further step reads a property off whatever the last one produced. Returns null the
## moment a step has nothing to read, so a connector pointed at the wrong signal goes
## quiet instead of tearing down the frame.
func _resolve(args: Array, path: String) -> Variant:
	var steps: PackedStringArray = path.split(":")
	var index: int = steps[0].to_int()
	if index < 0 or index >= args.size():
		return null
	var value: Variant = args[index]
	for step_index in range(1, steps.size()):
		if not (value is Object) or not is_instance_valid(value):
			return null
		value = (value as Object).get(steps[step_index])
	return value


## The exact script class of a value, for the `is WeaponDef` / `is ArmorDef` style splits.
## Exact rather than inherited: every type these conditions name is a leaf.
func _class_name_of(value: Variant) -> String:
	if not (value is Object) or not is_instance_valid(value):
		return ""
	var script: Script = (value as Object).get_script() as Script
	if script == null:
		return (value as Object).get_class()
	return script.get_global_name()
