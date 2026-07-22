extends Node2D


func _ready() -> void:
	GlobalSignalBus.level_started.emit()
