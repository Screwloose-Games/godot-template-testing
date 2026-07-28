class_name WolfAnimator
extends Node3D

## Owns the wolf's visual model and its entire animation graph.
##
## Everything below this node is PRIVATE: the 180-degree ModelPivot, the imported
## GLB, the AnimationTree and its whole `parameters/...` namespace. Callers say
## what the wolf is DOING -- "moving at 3.42 m/s on the ground", "airborne for
## 0.75 s" -- and this node decides what plays.
##
## That boundary is mechanical, not just a convention. These nodes are owned by
## wolf_animator.tscn, and unique-name lookup resolves against a node's owner
## rather than walking the tree, so `wolf.get_node_or_null("%AnimationTree")`
## returns null. A caller holding THIS node can still reach in, which is what lets
## the rig verifiers do their job -- but it has to be deliberate and it greps.
##
## Why the vocabulary has to live in exactly one place: AnimationTree.set() on a
## parameter path that does not exist does nothing and reports nothing. When two
## files spell the same path independently, renaming a state machine node fixes
## one and silently breaks the other.
##
## AnimationTree.root_motion_track is set purely to SUPPRESS the forward slide
## baked into every gait clip: designating a track as root motion stops the mixer
## writing it to the node (so "wolf_rig/grey_wolf" stays at its rest transform)
## and accumulates it for retrieval instead. We use the suppression and ignore the
## accumulation -- see measured_speed().
##
## This node must stay UNROTATED and UNSCALED relative to its host. Root motion is
## measured in this node's frame and read as the body's frame; see
## _warn_if_transformed() and "Component boundaries" in CLAUDE.md.

## The gait carrying the most weight has changed. Informational only -- the blend
## is driven continuously by speed, never by this.
signal gait_changed(gait_name: StringName)

## Native length of the "jump" clip, used to time-scale it to real airtime.
const JUMP_CLIP_LENGTH: float = 0.75
## Slowest walk-cycle playback rate before crossfading toward idle instead of
## slowing the cycle down further. Sets the "creep" threshold.
##
## Public because the headless sweeps drive WolfGaitLadder.ground_animation_params()
## with the same value. Three private copies of 0.35 is how a calibration test
## quietly stops testing what the game actually does.
const GAIT_RATE_MIN: float = 0.35

const _STATE_GROUND: StringName = &"Ground"
const _STATE_AIRBORNE: StringName = &"Airborne"

const _PARAM_PLAYBACK: StringName = &"parameters/playback"
const _PARAM_BLEND_POSITION: StringName = &"parameters/Ground/GaitSpace/blend_position"
const _PARAM_GAIT_RATE: StringName = &"parameters/Ground/GaitRate/scale"
const _PARAM_IDLE_MIX: StringName = &"parameters/Ground/IdleMove/blend_amount"
const _PARAM_AIR_RATE: StringName = &"parameters/Airborne/AirRate/scale"

var _playback: AnimationNodeStateMachinePlayback = null
var _root_motion_basis: Basis = Basis.IDENTITY
## The node designated as root_motion_track, and the local position it must hold
## while the mixer suppresses that track. Cached so the slide readout never has to
## hand the path out.
var _animated: Node3D = null
var _animated_rest: Vector3 = Vector3.ZERO
var _dominant_gait: StringName = &""

@onready var _tree: AnimationTree = %AnimationTree


func _ready() -> void:
	# Keep editor scrubbing from dirtying the scene file in version control.
	# This script is deliberately NOT @tool, so the branch is inert today --
	# `active = false` in the .tscn is what actually holds in the editor. Kept as
	# the guard that starts mattering the moment anyone adds @tool.
	if Engine.is_editor_hint():
		_tree.active = false
		return

	_tree.active = true
	_playback = _tree.get(_PARAM_PLAYBACK) as AnimationNodeStateMachinePlayback
	if _playback == null:
		push_error("WolfAnimator: '%s' did not yield an " % _PARAM_PLAYBACK
				+ "AnimationNodeStateMachinePlayback. The animator is inert.")
		return

	_warn_if_transformed()
	_cache_root_motion()
	enter_ground()


# --- Driving -----------------------------------------------------------------


## Poses the wolf for travelling over the ground at `speed` m/s. Call once per
## physics frame while grounded. Allocation-free.
##
## The band logic itself lives in WolfGaitLadder.ground_animation_params() so that
## the headless calibration sweep exercises the same code path this does.
func update_ground(speed: float) -> void:
	if _playback == null:
		return
	var params: Vector3 = WolfGaitLadder.ground_animation_params(speed, GAIT_RATE_MIN)
	_tree.set(_PARAM_IDLE_MIX, params.x)
	_tree.set(_PARAM_GAIT_RATE, params.y)
	_tree.set(_PARAM_BLEND_POSITION, params.z)

	var gait: StringName = WolfGaitLadder.dominant_gait_name(speed)
	if gait != _dominant_gait:
		_dominant_gait = gait
		gait_changed.emit(gait)


## The wolf is on the ground. Seeds the gait ladder at its slowest values and
## travels to the ground state. Also the resting state, called from _ready().
func enter_ground() -> void:
	if _playback == null:
		return
	_tree.set(_PARAM_GAIT_RATE, 1.0)
	_tree.set(_PARAM_AIR_RATE, 1.0)
	_tree.set(_PARAM_IDLE_MIX, 0.0)
	_tree.set(_PARAM_BLEND_POSITION, WolfGaitLadder.slowest_speed())
	_playback.travel(_STATE_GROUND)


## The wolf has left the ground on a ballistic arc lasting `airtime` seconds. The
## fixed-length air clip is time-scaled to fit, so takeoff, apex and touchdown
## line up with the real trajectory without slicing the clip into three states.
func enter_air(airtime: float) -> void:
	_enter_air_at_rate(clampf(JUMP_CLIP_LENGTH / maxf(airtime, 0.05), 0.5, 2.0))


## The wolf has left the ground with UNKNOWN airtime -- walked off a ledge, or an
## unbounded fall. The air clip plays at its native rate.
##
## Named rather than folded into enter_air() with a sentinel: a jump has a known
## ballistic airtime and a ledge walk-off does not, and that is a difference in
## kind, not a magnitude worth encoding as 0.0.
func enter_fall() -> void:
	_enter_air_at_rate(1.0)


# --- Readouts ----------------------------------------------------------------


## Speed the ANIMATION is producing, in this node's local space. Not used to drive
## movement -- this is the foot-slip readout and the calibration hook.
func measured_speed(delta: float) -> float:
	if delta <= 0.0:
		return 0.0
	var local: Vector3 = measured_motion()
	return Vector3(local.x, 0.0, local.z).length() / delta


## The same quantity as a vector, before the horizontal magnitude is taken.
##
## Reading it DRAINS the mixer's accumulator, so call it at most once per step.
## The calibration sweep integrates this over many frames, which cancels the
## once-per-cycle loop-wrap spike that summing magnitudes would not.
func measured_motion() -> Vector3:
	return _root_motion_basis * _tree.get_root_motion_position()


## How far the root-motion node has drifted from the rest transform it held when
## the tree started, in metres.
##
## This should stay at zero forever, because designating a track as root motion
## stops the mixer writing it to the node. Anything above ~0.01 m means the baked
## forward slide is leaking through and the wolf will visibly creep and snap back
## once per gait cycle.
func root_motion_slide() -> float:
	if _animated == null:
		return 0.0
	return (_animated.position - _animated_rest).length()


## The correction measured_motion() applies. Diagnostic: it must NOT be identity,
## because the 180-degree ModelPivot has to show up in it. An identity basis means
## the pivot was not found and every measured direction is reversed.
func root_motion_basis() -> Basis:
	return _root_motion_basis


func is_ground_state_active() -> bool:
	return _playback != null and _playback.get_current_node() == _STATE_GROUND


func is_air_state_active() -> bool:
	return _playback != null and _playback.get_current_node() == _STATE_AIRBORNE


## One-line dump for assertion failure messages. Produced HERE so that callers
## never have to name a state, a track or a parameter path just to report a fault.
func debug_report() -> String:
	var state: StringName = &"<inert>"
	if _playback != null:
		state = _playback.get_current_node()
	return "state=%s track='%s' slide=%.6f m basis.z=%s" % [
			state, _tree.root_motion_track, root_motion_slide(),
			str(_root_motion_basis.z)]


# --- Headless / deterministic control ----------------------------------------


## Switches the mixer between advancing itself on the physics tick and advancing
## only when advance() is called. Manual makes a headless sweep deterministic and
## independent of frame timing.
func set_manual_advance(enabled: bool) -> void:
	_tree.callback_mode_process = (
			AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL if enabled
			else AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS)


## Steps the mixer by `delta` seconds. Only meaningful under set_manual_advance().
func advance(delta: float) -> void:
	_tree.advance(delta)


# --- Internals ---------------------------------------------------------------


func _enter_air_at_rate(rate: float) -> void:
	if _playback == null:
		return
	_tree.set(_PARAM_AIR_RATE, rate)
	_playback.travel(_STATE_AIRBORNE)


## Root motion is measured in THIS node's frame and every caller reads it as the
## parent body's frame. That holds only while this node is untransformed relative
## to its parent. A yaw would be harmless -- the readout takes a horizontal
## magnitude -- but a pitch, roll or scale tips baked forward motion onto Y, which
## the readout zeroes, so foot slip would be silently under-reported.
##
## Checks the LOCAL transform, not global_transform: the whole wolf yaws
## constantly at runtime and that is not what this is about.
func _warn_if_transformed() -> void:
	if transform.is_equal_approx(Transform3D.IDENTITY):
		return
	push_warning("WolfAnimator: local transform is not identity (%s). " % str(transform)
			+ "measured_speed() is no longer in the parent body's frame. Put model "
			+ "offsets on %ModelPivot instead.")


## Resolves the root motion node once and caches both its rest position and the
## basis that maps its parent space into this node's space.
##
## get_root_motion_position() reports a delta in the ANIMATED NODE'S PARENT SPACE
## with no basis applied. The widely copied one-liner
##     velocity = transform.basis * get_root_motion_position() / delta
## silently assumes that space equals this node's space. With ModelPivot rotated
## 180 degrees it does not: the raw delta arrives as +Z, which is backwards. Cache
## the correction once instead of hardcoding a sign flip.
##
## The rest position is captured here, before anything advances the mixer -- the
## scene ships with `active = false` and _ready() has only just turned it on. If
## an advance ever preceded this, a real slide would be baked into the baseline
## and root_motion_slide() would report zero forever.
func _cache_root_motion() -> void:
	_root_motion_basis = Basis.IDENTITY

	if _tree.root_motion_track.is_empty():
		push_warning("WolfAnimator: root_motion_track is empty -- the forward slide "
				+ "baked into every gait clip will NOT be cancelled.")
		return

	var mixer_root: Node = _tree.get_node_or_null(_tree.root_node)
	if mixer_root == null:
		push_warning("WolfAnimator: AnimationTree.root_node ('%s') does not resolve."
				% _tree.root_node)
		return

	var animated: Node3D = mixer_root.get_node_or_null(_tree.root_motion_track) as Node3D
	if animated == null:
		push_warning("WolfAnimator: root_motion_track '%s' does not resolve to a Node3D."
				% _tree.root_motion_track)
		return

	_animated = animated
	_animated_rest = animated.position

	var parent: Node3D = animated.get_parent_node_3d()
	if parent == null:
		return
	# Parent space of the animated node -> this node's local space.
	_root_motion_basis = global_transform.basis.inverse() * parent.global_transform.basis
