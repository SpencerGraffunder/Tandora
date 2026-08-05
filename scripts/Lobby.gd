extends Control

const Enums = preload("res://scripts/Enums.gd")
const LeaderboardUI = preload("res://scripts/LeaderboardUI.gd")

# How long to wait for the server to answer a Create/Join Room request before
# telling the user the server didn't respond (see _start_request_timeout).
const REQUEST_TIMEOUT_SECONDS: float = 10.0

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
var _room_player_count: int = 1
var _pending_request := false
var _pending_request_action := ""
var _pending_request_timer: SceneTreeTimer = null

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
	# On mobile web the virtual keyboard covers the input field.
	# Shift the VBoxContainer up when the input gets focus so the
	# user can see what they're typing, and restore when focus is lost.
	# Only do this on devices that actually have a soft keyboard —
	# desktop browsers have a hardware keyboard and must not be affected.
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
	_clear_request_timeout()
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
	if _has_soft_keyboard() and DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		var keyboard_height = DisplayServer.virtual_keyboard_get_height()/2.0
		keyboard_spacer.custom_minimum_size.y = keyboard_height


# True on devices that actually have a soft keyboard (phones/tablets). Used to
# decide whether to pop the virtual keyboard and shift the menu up when the
# room-code box is focused — anything with a hardware keyboard (desktop
# browsers, and desktop OSes even when a touchscreen is present) should do
# neither: popping the OS touch keyboard there overlays the game and steals
# clicks, which is the "buttons highlight but don't do anything" symptom.
func _has_soft_keyboard() -> bool:
	if OS.has_feature("android") or OS.has_feature("ios"):
		return true
	if OS.has_feature("web"):
		if not DisplayServer.is_touchscreen_available():
			return false
		# Touchscreen laptops also report is_touchscreen_available() == true,
		# so check the primary pointer type (coarse = touch-primary device,
		# i.e. an actual phone/tablet). Fall back to the touchscreen check for
		# browsers without matchMedia support.
		var coarse_pointer = JavaScriptBridge.eval(
			"window.matchMedia && window.matchMedia('(pointer: coarse)').matches", true)
		if coarse_pointer != null:
			return bool(coarse_pointer)
		return true
	return false


# When the room-code input is focused on mobile web the virtual keyboard
# appears and covers the bottom half of the screen. Shift the whole
# VBoxContainer up so the input stays visible, then restore it on blur.
# On devices without a soft keyboard (desktop browsers) this is skipped
# entirely and the experimental web virtual keyboard is never shown, since it
# would steal focus and cover part of the page for no reason.
const KEYBOARD_PUSH_Y: float = 350.0

func _on_room_code_focus_gained() -> void:
	if not _has_soft_keyboard():
		return
	DisplayServer.virtual_keyboard_show(room_code_input.text)
	if OS.has_feature("web"):
		_main_vbox.offset_top = _vbox_offset_top - KEYBOARD_PUSH_Y
		# Keep the same container height so the layout doesn't reflow.
		_main_vbox.offset_bottom = _vbox_offset_bottom - KEYBOARD_PUSH_Y

func _on_room_code_focus_lost() -> void:
	if not _has_soft_keyboard():
		return
	if OS.has_feature("web"):
		_main_vbox.offset_top = _vbox_offset_top
		_main_vbox.offset_bottom = _vbox_offset_bottom

func _update_player_tiles(count: int) -> void:
	_room_player_count = count
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
		room_leaderboard_container.add_child(LeaderboardUI.build_row(i, entries[i]))

func _on_create_pressed():
	is_creator = true
	Network.rpc_create_room.rpc_id(1, int(level_spinbox.value), int(local_players_spinbox.value), device_id, Network.username)
	_start_request_timeout("Create Room")

func _on_join_pressed():
	var code = room_code_input.text.strip_edges().to_lower()
	is_creator = false
	Network.rpc_join_room.rpc_id(1, code, int(local_players_spinbox.value), device_id, Network.username)
	_start_request_timeout("Join Room")

# Create/Join send an RPC to the game server and normally get an answer in
# under a second. If the server accepts the connection but doesn't answer the
# RPC (e.g. it's running an older build whose RPC signatures no longer match,
# so Godot drops the call silently), the click appears to do nothing. Surface
# that instead of leaving the user with a dead button.
func _start_request_timeout(action: String) -> void:
	_pending_request = true
	_pending_request_action = action
	if _pending_request_timer != null and _pending_request_timer.timeout.is_connected(_on_request_timeout):
		_pending_request_timer.timeout.disconnect(_on_request_timeout)
	_pending_request_timer = get_tree().create_timer(REQUEST_TIMEOUT_SECONDS)
	_pending_request_timer.timeout.connect(_on_request_timeout)

func _on_request_timeout() -> void:
	if not _pending_request:
		return
	_pending_request = false
	status_label.text = _pending_request_action + " didn't get a response from the server. It may be running an old version - please update the server, then try again."

func _clear_request_timeout() -> void:
	_pending_request = false

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
	_update_room_leaderboard(_room_player_count)

func _hide_room_panel():
	room_panel.visible = false
	create_button.visible = true
	join_button.visible = true
	room_code_input.visible = true
	room_status_label.visible = true
	_update_username_warning()

func _on_room_created(code: String):
	_clear_request_timeout()
	var my_local_count = int(local_players_spinbox.value)
	_update_player_tiles(my_local_count)
	code_label.text = code.to_upper()
	local_players_spinbox.editable = true
	_update_creator_ui()
	room_status_label.text = "Players: " + str(my_local_count)
	_show_room_panel()
	_update_username_warning()

func _on_room_joined(player_count: int, code: String):
	_clear_request_timeout()
	code_label.text = code.to_upper()
	local_players_spinbox.editable = true
	_update_creator_ui()
	room_status_label.text = "Players: " + str(player_count)
	_update_player_tiles(player_count)
	_show_room_panel()
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
