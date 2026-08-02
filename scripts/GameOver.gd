extends Control

const LeaderboardUI = preload("res://scripts/LeaderboardUI.gd")

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
		leaderboard_container.add_child(LeaderboardUI.build_row(i, entries[i]))

func _on_main_menu_pressed():
	print("[CLIENT GameOver] _on_main_menu_pressed: Changing to Lobby scene")
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")
