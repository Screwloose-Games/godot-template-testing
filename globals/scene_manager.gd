extends Node

# load(), not const preload(): several of these scenes carry scripts that reference this
# autoload back, and a preload chain resolved at parse time makes that a cyclic reference.
var main_level = load("res://levels/level_01/level_01.tscn")
var main_menu = load("res://common/ui/main_menu/main_menu.tscn")
var options_menu = load("res://common/ui/options_menu/options_menu.tscn")
var pause_menu = load("res://common/ui/pause_menu/pause_menu.tscn")
var circle_transition = load("res://common/ui/scene_transitions/circle_transition.tscn")
var fade_transition = load("res://common/ui/scene_transitions/fade_transition.tscn")
var credits = load("res://common/ui/screens/credits.tscn")
