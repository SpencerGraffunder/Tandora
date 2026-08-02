extends Control

@onready var score_value = $VBoxContainer/HBoxContainer/Score
@onready var level_value = $VBoxContainer/HBoxContainer2/Level
@onready var leaderboard_container = $VBoxContainer/LeaderboardContainer

func _ready():
	score_value.text = str(Network.final_score)
	level_value.text = str(Network.final_level)
	$VBoxContainer/MainMenuButton.pressed.connect(_on_main_menu_pressed)
	Network.leaderboard_updated.connect(_on_leaderboard_updated)
	_populate_leaderboard()

func _populate_leaderboard() -> void:
	for child in leaderboard_container.get_children():
		child.queue_free()
	var player_count = max(1, min(8, Network.starting_player_count))
	var entries = Network.get_leaderboard(player_count, 5)
	_populate_rows(entries)
	Network.request_leaderboard(player_count, 5)

func _on_leaderboard_updated(player_count: int, entries: Array) -> void:
	if player_count != max(1, min(8, Network.starting_player_count)):
		return
	_populate_rows(entries)

func _populate_rows(entries: Array) -> void:
	for child in leaderboard_container.get_children():
		child.queue_free()
	if entries.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No scores yet"
		leaderboard_container.add_child(empty_label)
		return
	for i in range(entries.size()):
		leaderboard_container.add_child(_build_leaderboard_row(i, entries[i]))

func _build_leaderboard_row(rank: int, entry: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var rank_label = Label.new()
	rank_label.text = str(rank + 1) + "."
	rank_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var is_me = _entry_is_mine(entry)
	var name_label = Label.new()
	name_label.text = ("★ " if is_me else "") + _entry_display_name(entry)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	if is_me:
		name_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.3))

	var score_label = Label.new()
	score_label.text = str(int(entry.get("score", 0)))
	score_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	row.add_child(rank_label)
	row.add_child(name_label)
	row.add_child(score_label)
	return row

func _entry_display_name(entry: Dictionary) -> String:
	var usernames = entry.get("usernames", [])
	if usernames is Array and usernames.size() > 0:
		return ", ".join(usernames)
	return "Anonymous"

func _entry_is_mine(entry: Dictionary) -> bool:
	var my_name = Network.username.strip_edges()
	if my_name == "":
		return false
	var usernames = entry.get("usernames", [])
	return usernames is Array and usernames.has(my_name)

func _on_main_menu_pressed():
	print("[CLIENT GameOver] _on_main_menu_pressed: Changing to Lobby scene")
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")
