extends Control

@onready var start_button: Button = %StartButton
@onready var options_button: Button = %OptionsButton
@onready var credits_button: Button = %CreditsButton
@onready var quit_button: Button = %QuitButton
@onready var main_panel: Control = %MainPanel
@onready var options_menu: OptionsMenu = %OptionsMenu


func _ready() -> void:
	start_button.pressed.connect(_on_start_pressed)
	options_button.pressed.connect(_on_options_pressed)
	credits_button.pressed.connect(_on_credits_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	options_menu.back_pressed.connect(_on_options_back_pressed)
	options_menu.visible = false

	if OS.has_feature("web"):
		quit_button.visible = false


func _on_start_pressed():
	SceneTransitionManager.change_scene_with_transition(
		SceneManager.main_level, SceneManager.fade_transition
	)


func _on_credits_pressed():
	GlobalSignalBus.credits_screen_started.emit()
	SceneTransitionManager.change_scene_with_transition(
		SceneManager.credits, SceneManager.fade_transition
	)


func _on_options_pressed():
	main_panel.visible = false
	options_menu.visible = true


func _on_options_back_pressed():
	options_menu.visible = false
	main_panel.visible = true


func _on_quit_pressed():
	get_tree().quit()
