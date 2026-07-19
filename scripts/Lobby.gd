extends Control

const Enums = preload("res://scripts/Enums.gd")

@onready var room_code_input = $VBoxContainer/HBoxContainer/RoomCodeLineEdit
@onready var create_button = $VBoxContainer/CreateButton
@onready var join_button = $VBoxContainer/HBoxContainer/JoinButton
@onready var status_label = $HBoxContainer/StatusLabel
@onready var room_panel = $RoomPanel
@onready var code_label = $RoomPanel/VBoxContainer/CodeLabel
@onready var level_spinbox = $RoomPanel/VBoxContainer/HBoxContainer2/StartingLevelSpinBox
@onready var start_button = $RoomPanel/VBoxContainer/HBoxContainer/StartButton
@onready var leave_button = $RoomPanel/VBoxContainer/HBoxContainer/LeaveButton
@onready var keyboard_spacer = $VBoxContainer/KeyboardSpacer
@onready var room_status_label = $RoomPanel/VBoxContainer/StatusLabel
@onready var room_leaderboard_label = $RoomPanel/VBoxContainer/LeaderboardLabel
@onready var room_leaderboard_container = $RoomPanel/VBoxContainer/LeaderboardContainer
@onready var settings_button = $SettingsButton
@onready var settings_panel = $SettingsPanel
@onready var settings_close_button = $SettingsPanel/CloseButton
@onready var how_to_play_button = $HowToPlayButton
@onready var how_to_play_panel = $HowToPlayPanel
@onready var how_to_play_close_button = $HowToPlayPanel/CloseButton
@onready var touchscreen_toggle = $SettingsPanel/VBoxContainer/TouchscreenToggle
@onready var version_label = $HBoxContainer/VersionLabel
@onready var player_tiles = [
	$RoomPanel/VBoxContainer/PlayerList/P1,
	$RoomPanel/VBoxContainer/PlayerList/P2,
	$RoomPanel/VBoxContainer/PlayerList/P3,
	$RoomPanel/VBoxContainer/PlayerList/P4,
	$RoomPanel/VBoxContainer/PlayerList/P5,
	$RoomPanel/VBoxContainer/PlayerList/P6,
	$RoomPanel/VBoxContainer/PlayerList/P7,
	$RoomPanel/VBoxContainer/PlayerList/P8
]

var is_creator: bool = false
var lost_connection := false
var device_id: String = ""
var touchscreen_enabled: bool = true

func _ready():
	if Network.is_dedicated_server:
		return

	_load_settings()
	Network.touchscreen_enabled = touchscreen_enabled

	# Set version label from autoload
	version_label.text = "v" + Version.commit

	room_panel.visible = false
	settings_panel.visible = false
	how_to_play_panel.visible = false
	status_label.disabled = true
	create_button.pressed.connect(_on_create_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	level_spinbox.value_changed.connect(_on_level_changed)
	room_code_input.text_submitted.connect(func(_text): _on_join_pressed())
	room_code_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	room_code_input.focus_entered.connect(func(): DisplayServer.virtual_keyboard_show(room_code_input.text))
	status_label.pressed.connect(_on_reconnect_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	settings_close_button.pressed.connect(_close_settings_panel)
	how_to_play_button.pressed.connect(_on_how_to_play_pressed)
	how_to_play_close_button.pressed.connect(_close_how_to_play_panel)
	touchscreen_toggle.toggled.connect(_on_touchscreen_toggled)
	
	for tile in player_tiles:
		tile.visible = false

	Network.connection_succeeded.connect(_on_connected)
	Network.connection_failed.connect(_on_connection_failed)
	Network.room_created.connect(_on_room_created)
	Network.room_joined.connect(_on_room_joined)
	Network.room_updated.connect(_on_room_updated)

	# Cache device ID (cast as Node since compiler doesn't recognize autoload)
	device_id = get_node("/root/DeviceID").get_device_id()

	# Listen for app focus (resume) events
	get_window().connect("focus_entered", Callable(self, "_on_app_resume"))

	# Connect to server
	Network.connect_to_server()
	status_label.text = "Connecting to server"

func _on_app_resume():
	if lost_connection:
		status_label.disabled = true
		Network.connect_to_server()
		status_label.text = "Reconnecting..."

func _on_connection_failed():
	status_label.text = "Connection failed. Tap to retry"
	lost_connection = true
	status_label.disabled = false

func _on_connected():
	status_label.text = "Connected to server"
	lost_connection = false
	status_label.disabled = true
	create_button.disabled = false
	join_button.disabled = false

func _on_reconnect_pressed():
	if lost_connection:
		status_label.disabled = true
		Network.connect_to_server()
		status_label.text = "Reconnecting..."

func _process(_delta):
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		var keyboard_height = DisplayServer.virtual_keyboard_get_height()/2.0
		keyboard_spacer.custom_minimum_size.y = keyboard_height

func _update_player_tiles(count: int) -> void:
	for i in range(player_tiles.size()):
		player_tiles[i].visible = i < count
	_update_room_leaderboard(count)

func _update_room_leaderboard(player_count: int) -> void:
	for child in room_leaderboard_container.get_children():
		child.queue_free()
	var entries = Network.get_leaderboard(max(1, min(8, player_count)), 5)
	if entries.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No scores yet"
		room_leaderboard_container.add_child(empty_label)
		return
	for i in range(entries.size()):
		var entry = entries[i]
		var row = HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		var rank_label = Label.new()
		rank_label.text = str(i + 1) + "."
		rank_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var score_label = Label.new()
		score_label.text = str(int(entry.get("score", 0)))
		score_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var players_label = Label.new()
		players_label.text = str(entry.get("player_numbers", []))
		players_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(rank_label)
		row.add_child(score_label)
		row.add_child(players_label)
		room_leaderboard_container.add_child(row)

func _on_create_pressed():
	is_creator = true
	Network.rpc_create_room.rpc_id(1, int(level_spinbox.value), device_id)

func _on_join_pressed():
	var code = room_code_input.text.strip_edges().to_lower()
	is_creator = false
	Network.rpc_join_room.rpc_id(1, code, device_id)

func _on_start_pressed():
	Network.rpc_start_game.rpc_id(1)

func _on_level_changed(value: float):
	if is_creator:
		Network.rpc_update_level.rpc_id(1, int(value))

func _show_room_panel():
	room_panel.visible = true
	create_button.visible = false
	join_button.visible = false
	room_code_input.visible = false
	room_status_label.visible = false
	_update_room_leaderboard(max(1, min(8, room_status_label.text.to_int() if room_status_label.text.is_valid_int() else 1)))

func _hide_room_panel():
	room_panel.visible = false
	create_button.visible = true
	join_button.visible = true
	room_code_input.visible = true
	room_status_label.visible = true

func _on_room_created(code: String):
	_update_player_tiles(1)
	code_label.text = code.to_upper()
	level_spinbox.editable = true
	start_button.visible = true
	_show_room_panel()

func _on_room_joined(player_count: int, code: String):
	code_label.text = code.to_upper()
	level_spinbox.editable = false
	start_button.visible = false
	_show_room_panel()
	room_status_label.text = "Players: " + str(player_count)
	_update_room_leaderboard(player_count)

func _on_leave_pressed():
	print_verbose("[CLIENT Lobby] _on_leave_pressed: Leaving room")
	_hide_room_panel()

func _on_settings_pressed():
	settings_panel.visible = true

func _close_settings_panel():
	settings_panel.visible = false

func _on_how_to_play_pressed():
	how_to_play_panel.visible = true

func _close_how_to_play_panel():
	how_to_play_panel.visible = false

func _on_room_updated(player_count: int, level: int):
	print_verbose("[CLIENT Lobby] _on_room_updated: new player_count=", player_count, " level=", level)
	_update_player_tiles(player_count)
	room_status_label.text = "Players: " + str(player_count)
	level_spinbox.value = level
	_update_room_leaderboard(player_count)

func _on_touchscreen_toggled(toggled_on: bool) -> void:
	touchscreen_enabled = toggled_on
	Network.touchscreen_enabled = toggled_on
	_save_settings()

func _load_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://tandora.cfg")
	if err == OK:
		touchscreen_enabled = config.get_value("input", "touchscreen", true)
		touchscreen_toggle.button_pressed = touchscreen_enabled

func _save_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://tandora.cfg")
	if err != OK:
		pass  # file doesn't exist yet, that's fine
	config.set_value("input", "touchscreen", touchscreen_enabled)
	config.save("user://tandora.cfg")
