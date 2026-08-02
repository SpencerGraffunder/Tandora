extends Control

const Enums = preload("res://scripts/Enums.gd")

@onready var room_code_input = $VBoxContainer/HBoxContainer/RoomCodeLineEdit
@onready var create_button = $VBoxContainer/CreateButton
@onready var join_button = $VBoxContainer/HBoxContainer/JoinButton
@onready var status_label = $HBoxContainer/StatusLabel
@onready var room_panel = $RoomPanel
@onready var code_label = $RoomPanel/VBoxContainer/CodeLabel
@onready var level_spinbox = $RoomPanel/VBoxContainer/HBoxContainer2/StartingLevelSpinBox
@onready var local_players_spinbox = $RoomPanel/VBoxContainer/HBoxContainer3/LocalPlayersSpinBox
@onready var start_button = $RoomPanel/VBoxContainer/HBoxContainer/StartButton
@onready var leave_button = $RoomPanel/VBoxContainer/HBoxContainer/LeaveButton
@onready var keyboard_spacer = $VBoxContainer/KeyboardSpacer
@onready var room_status_label = $RoomPanel/VBoxContainer/StatusLabel
@onready var room_leaderboard_label = $RoomPanel/LeaderboardVBox/LeaderboardLabel
@onready var room_leaderboard_container = $RoomPanel/LeaderboardVBox/LeaderboardContainer
@onready var settings_button = $SettingsButton
@onready var settings_panel = $SettingsPanel
@onready var settings_close_button = $SettingsPanel/CloseButton
@onready var how_to_play_button = $HowToPlayButton
@onready var how_to_play_panel = $HowToPlayPanel
@onready var how_to_play_close_button = $HowToPlayPanel/CloseButton
@onready var touchscreen_toggle = $SettingsPanel/VBoxContainer/TouchscreenToggle
@onready var username_lineedit = $SettingsPanel/VBoxContainer/HBoxContainer4/UsernameLineEdit
@onready var username_warning_label = $RoomPanel/VBoxContainer/UsernameWarningLabel
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
var _updating_local_players := false

@onready var _main_vbox = $VBoxContainer
var _vbox_offset_top: float
var _vbox_offset_bottom: float

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
	# Local players: one connection can control 1-4 players (keyboard + joypads).
	local_players_spinbox.min_value = 1
	local_players_spinbox.max_value = 4
	local_players_spinbox.value = 1
	local_players_spinbox.value_changed.connect(_on_local_players_changed)
	room_code_input.text_submitted.connect(func(_text): _on_join_pressed())
	room_code_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	room_code_input.focus_entered.connect(func(): DisplayServer.virtual_keyboard_show(room_code_input.text))
	# On mobile web the virtual keyboard covers the input field.
	# Shift the VBoxContainer up when the input gets focus so the
	# user can see what they're typing, and restore when focus is lost.
	_vbox_offset_top = _main_vbox.offset_top
	_vbox_offset_bottom = _main_vbox.offset_bottom
	room_code_input.focus_entered.connect(_on_room_code_focus_gained)
	room_code_input.focus_exited.connect(_on_room_code_focus_lost)
	status_label.pressed.connect(_on_reconnect_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	settings_close_button.pressed.connect(_close_settings_panel)
	how_to_play_button.pressed.connect(_on_how_to_play_pressed)
	how_to_play_close_button.pressed.connect(_close_how_to_play_panel)
	touchscreen_toggle.toggled.connect(_on_touchscreen_toggled)
	username_lineedit.max_length = 16
	username_lineedit.text_changed.connect(_on_username_changed)
	username_lineedit.focus_exited.connect(_on_username_focus_exited)
	
	for tile in player_tiles:
		tile.visible = false

	Network.connection_succeeded.connect(_on_connected)
	Network.connection_failed.connect(_on_connection_failed)
	Network.room_created.connect(_on_room_created)
	Network.room_joined.connect(_on_room_joined)
	Network.room_updated.connect(_on_room_updated)
	Network.leaderboard_updated.connect(_on_leaderboard_updated)
	Network.local_players_updated.connect(_on_local_players_updated)
	Network.room_creator_changed.connect(_on_creator_changed)

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


# When the room-code input is focused on mobile web the virtual keyboard
# appears and covers the bottom half of the screen. Shift the whole
# VBoxContainer up so the input stays visible, then restore it on blur.
const KEYBOARD_PUSH_Y: float = 350.0

func _on_room_code_focus_gained() -> void:
	if OS.has_feature("web"):
		_main_vbox.offset_top = _vbox_offset_top - KEYBOARD_PUSH_Y
		# Keep the same container height so the layout doesn't reflow.
		_main_vbox.offset_bottom = _vbox_offset_bottom - KEYBOARD_PUSH_Y

func _on_room_code_focus_lost() -> void:
	if OS.has_feature("web"):
		_main_vbox.offset_top = _vbox_offset_top
		_main_vbox.offset_bottom = _vbox_offset_bottom

func _update_player_tiles(count: int) -> void:
	for i in range(player_tiles.size()):
		player_tiles[i].visible = i < count
	_update_room_leaderboard(count)

func _update_room_leaderboard(player_count: int) -> void:
	var resolved_count = max(1, min(8, player_count))
	var entries = Network.get_leaderboard(resolved_count, 5)
	_populate_leaderboard_rows(entries)
	Network.request_leaderboard(resolved_count, 5)

func _on_leaderboard_updated(_player_count: int, entries: Array) -> void:
	_populate_leaderboard_rows(entries)

func _populate_leaderboard_rows(entries: Array) -> void:
	for child in room_leaderboard_container.get_children():
		child.queue_free()
	if entries.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No scores yet"
		room_leaderboard_container.add_child(empty_label)
		return
	for i in range(entries.size()):
		room_leaderboard_container.add_child(_build_leaderboard_row(i, entries[i]))

func _build_leaderboard_row(rank: int, entry: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var rank_label = Label.new()
	rank_label.text = str(rank + 1) + "."
	rank_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var is_me = _entry_is_mine(entry)
	var name_label = Label.new()
	name_label.text = _entry_display_name(entry)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	if is_me:
		name_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.3))

	var score_label = Label.new()
	score_label.text = ("★ " if is_me else "") + str(int(entry.get("score", 0)))
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

func _on_create_pressed():
	is_creator = true
	Network.rpc_create_room.rpc_id(1, int(level_spinbox.value), int(local_players_spinbox.value), device_id, Network.username)

func _on_join_pressed():
	var code = room_code_input.text.strip_edges().to_lower()
	is_creator = false
	Network.rpc_join_room.rpc_id(1, code, int(local_players_spinbox.value), device_id, Network.username)

func _on_start_pressed():
	Network.rpc_start_game.rpc_id(1)

func _on_level_changed(value: float):
	if is_creator:
		Network.rpc_update_level.rpc_id(1, int(value))

# Fires when the user changes the Local Players spinbox while in a room.
func _on_local_players_changed(value: float):
	if _updating_local_players:
		return
	var count = clampi(int(value), 1, 4)
	if count != int(value):
		_updating_local_players = true
		local_players_spinbox.value = count
		_updating_local_players = false
	Network.rpc_update_local_players.rpc_id(1, count)

# Server echoes the clamped local player count back so the UI stays in sync.
func _on_local_players_updated(count: int):
	_updating_local_players = true
	local_players_spinbox.value = count
	_updating_local_players = false

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
	_update_username_warning()

func _on_room_created(code: String):
	var my_local_count = int(local_players_spinbox.value)
	_update_player_tiles(my_local_count)
	code_label.text = code.to_upper()
	local_players_spinbox.editable = true
	_update_creator_ui()
	room_status_label.text = "Players: " + str(my_local_count)
	_show_room_panel()
	_update_username_warning()

func _on_room_joined(player_count: int, code: String):
	code_label.text = code.to_upper()
	local_players_spinbox.editable = true
	_update_creator_ui()
	_show_room_panel()
	room_status_label.text = "Players: " + str(player_count)
	_update_player_tiles(player_count)
	_update_room_leaderboard(player_count)
	_update_username_warning()

# Reflects whether this client is the room host: only the host can edit the
# starting level and start the game.
func _update_creator_ui() -> void:
	level_spinbox.editable = is_creator
	start_button.visible = is_creator

# Leadership can transfer if the original host leaves the lobby. Update our
# host state and UI accordingly.
func _on_creator_changed(creator_id: int) -> void:
	is_creator = creator_id == multiplayer.get_unique_id()
	_update_creator_ui()
	_update_username_warning()

func _on_leave_pressed():
	print_verbose("[CLIENT Lobby] _on_leave_pressed: Leaving room")
	Network.rpc_leave_room.rpc_id(1)
	_hide_room_panel()

func _on_settings_pressed():
	settings_panel.visible = true

func _close_settings_panel():
	settings_panel.visible = false
	_update_username_warning()

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
		Network.username = config.get_value("profile", "username", "")
		username_lineedit.text = Network.username

func _save_settings() -> void:
	var config = ConfigFile.new()
	var err = config.load("user://tandora.cfg")
	if err != OK:
		pass  # file doesn't exist yet, that's fine
	config.set_value("input", "touchscreen", touchscreen_enabled)
	config.set_value("profile", "username", Network.username)
	config.save("user://tandora.cfg")

func _on_username_changed(text: String) -> void:
	Network.username = text
	_save_settings()
	_update_username_warning()

# Trim whitespace when the username field loses focus so we store a clean name.
func _on_username_focus_exited() -> void:
	var trimmed = username_lineedit.text.strip_edges()
	if trimmed != Network.username:
		username_lineedit.text = trimmed
		Network.username = trimmed
		_save_settings()
	_update_username_warning()

# The host gets a warning if they have no username, since their score won't be
# recorded on the leaderboard.
func _update_username_warning() -> void:
	username_warning_label.visible = room_panel.visible and is_creator and Network.username.strip_edges() == ""
