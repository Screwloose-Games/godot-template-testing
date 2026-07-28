@tool
class_name Credits
extends Control

## Auto-scrolling credits roll rendered from a Markdown file.
##
## Markdown is a NON-RESOURCE file. It reaches an exported build only when the
## export preset lists `*.md` under "Filters to export non-resource files/folders"
## (`include_filter` in export_presets.cfg). CI asserts this; see README.md.

signal end_reached

## Shown when the Markdown file cannot be read. Deliberately visible: a silent
## failure here used to leave stale placeholder text on screen, which made a
## broken export look like a working one.
const MISSING_FILE_TEXT := "# Credits\n\nCredits file could not be loaded."
const MISSING_FILE_ERROR := (
	"Credits: %s is not present in this build. Add *.md to the export preset's "
	+ '"Filters to export non-resource files/folders" (include_filter).'
)

@export_file("*.md") var attribution_file_path: String = "res://ATTRIBUTION.md"
@export var h1_font_size: int
@export var h2_font_size: int
@export var h3_font_size: int
@export var h4_font_size: int
@export var current_speed: float = 1.0
@export var enabled: bool = true

var scroll_paused: bool = false

var _current_scroll_position: float = 0.0


func _ready():
	set_file_path(attribution_file_path)
	set_header_and_footer()


func _input(event: InputEvent) -> void:
	if (
		(event is InputEventKey and event.pressed)
		or (event is InputEventMouseButton and event.pressed)
	):
		SceneTransitionManager.change_scene_with_transition(
			SceneManager.main_menu, SceneManager.fade_transition
		)
		GlobalSignalBus.title_screen_started.emit()


func load_file(file_path: String) -> String:
	if not FileAccess.file_exists(file_path):
		push_error(MISSING_FILE_ERROR % file_path)
		return ""
	# get_file_as_string() returns an empty String on failure, never null.
	var file_string := FileAccess.get_file_as_string(file_path)
	if file_string.is_empty():
		push_error(
			"Credits: could not read %s (error %d)." % [file_path, FileAccess.get_open_error()]
		)
		return ""
	return file_string


func regex_replace_urls(credits: String):
	var regex = RegEx.new()
	var match_string: String = "\\[([^\\]]*)\\]\\(([^\\)]*)\\)"
	var replace_string: String = "[url=$2]$1[/url]"
	regex.compile(match_string)
	return regex.sub(credits, replace_string, true)


func regex_replace_titles(credits: String):
	var iter = 0
	var heading_font_sizes: Array[int] = [h1_font_size, h2_font_size, h3_font_size, h4_font_size]
	for heading_font_size in heading_font_sizes:
		iter += 1
		var regex = RegEx.new()
		var match_string: String = "([^#]|^)#{%d}\\s([^\n]*)" % iter
		var replace_string: String = "$1[font_size=%d]$2[/font_size]" % [heading_font_size]
		regex.compile(match_string)
		credits = regex.sub(credits, replace_string, true)
	return credits


func _markdown_to_bbcode(markdown: String) -> String:
	var text := markdown
	# Drop the document title line ("# Game Title") -- the roll has its own heading.
	# find() returns -1 for a single-line file, which must not wipe the whole text.
	var first_newline := text.find("\n")
	if first_newline != -1:
		text = text.substr(first_newline + 1)
	text = regex_replace_urls(text)
	text = regex_replace_titles(text)
	return text


func _update_text_from_file() -> void:
	var markdown := load_file(attribution_file_path)
	if markdown.is_empty():
		markdown = MISSING_FILE_TEXT
	%CreditsLabel.text = "[center]%s[/center]" % _markdown_to_bbcode(markdown)


func set_file_path(file_path: String):
	attribution_file_path = file_path
	_update_text_from_file()


func set_header_and_footer():
	# A web canvas can report 0x0 before the browser has laid the iframe out.
	# Writing 0 into the spacers makes is_end_reached() true on the first frame,
	# which latches scroll_paused and freezes the roll for good.
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_current_scroll_position = $ScrollContainer.scroll_vertical
	%HeaderSpace.custom_minimum_size.y = size.y
	%FooterSpace.custom_minimum_size.y = size.y
	%CreditsLabel.custom_minimum_size.x = size.x


func reset():
	scroll_paused = false
	$ScrollContainer.scroll_vertical = 0
	set_header_and_footer()


func _end_reached():
	scroll_paused = true
	end_reached.emit()


func is_end_reached() -> bool:
	var credits_height: float = %CreditsLabel.size.y
	var header_height: float = %HeaderSpace.size.y
	if credits_height <= 0.0 or header_height <= 0.0:
		# Layout has not settled yet (first frame, or an unsized web canvas).
		return false
	# `>` could never be satisfied: scroll_vertical maxes out at exactly this sum.
	return $ScrollContainer.scroll_vertical >= credits_height + header_height


func _check_end_reached():
	if not is_end_reached():
		return
	_end_reached()


func _scroll_container(amount: float) -> void:
	if not visible or not enabled or scroll_paused:
		return
	_current_scroll_position += amount
	$ScrollContainer.scroll_vertical = round(_current_scroll_position)
	_check_end_reached()


func _process(_delta):
	if Engine.is_editor_hint():
		return
	var input_axis = Input.get_axis("ui_up", "ui_down")
	if input_axis != 0:
		_scroll_container(10 * input_axis)
	else:
		_scroll_container(current_speed)


func _on_scroll_container_gui_input(event):
	# Capture the mouse scroll wheel input event
	if event is InputEventMouseButton:
		scroll_paused = true
		_start_scroll_timer()
	_check_end_reached()


func _on_scroll_container_scroll_started():
	# Capture the touch input event
	scroll_paused = true
	_start_scroll_timer()


func _start_scroll_timer():
	$ScrollResetTimer.start()


func _on_CreditsLabel_meta_clicked(meta: String):
	if meta.begins_with("https://"):
		OS.shell_open(meta)


func _on_scroll_reset_timer_timeout():
	set_header_and_footer()
	scroll_paused = false


func _on_scroll_container_resized():
	set_header_and_footer()
