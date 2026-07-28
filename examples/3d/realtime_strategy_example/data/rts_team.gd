class_name RtsTeam
extends RefCounted

## Team identity: the enum everything else keys off, plus the colour and physics-layer bits
## belonging to each side.
##
## The colours are deliberately loud. With primitive placeholder art the team tint is the
## only thing telling a player what they are looking at, so readability beats taste here.

enum Id {
	NEUTRAL,
	PLAYER,
	ENEMY,
}

const NEUTRAL_COLOR: Color = Color(0.62, 0.61, 0.57)
const PLAYER_COLOR: Color = Color(0.18, 0.62, 1.0)
const ENEMY_COLOR: Color = Color(1.0, 0.33, 0.26)


static func color_of(team: int) -> Color:
	match team:
		Id.PLAYER:
			return PLAYER_COLOR
		Id.ENEMY:
			return ENEMY_COLOR
		_:
			return NEUTRAL_COLOR


static func display_name(team: int) -> String:
	match team:
		Id.PLAYER:
			return "Player"
		Id.ENEMY:
			return "Enemy"
		_:
			return "Neutral"


static func opponent_of(team: int) -> int:
	match team:
		Id.PLAYER:
			return Id.ENEMY
		Id.ENEMY:
			return Id.PLAYER
		_:
			return Id.NEUTRAL


static func unit_layer(team: int) -> int:
	return RtsLayers.UNIT_ENEMY if team == Id.ENEMY else RtsLayers.UNIT_PLAYER


static func building_layer(team: int) -> int:
	return RtsLayers.BUILDING_ENEMY if team == Id.ENEMY else RtsLayers.BUILDING_PLAYER


## The layer bits holding everything this team wants to shoot at.
static func hostile_mask(team: int) -> int:
	if team == Id.ENEMY:
		return RtsLayers.UNIT_PLAYER | RtsLayers.BUILDING_PLAYER
	return RtsLayers.UNIT_ENEMY | RtsLayers.BUILDING_ENEMY
