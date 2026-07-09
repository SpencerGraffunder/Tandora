extends Control

const Enums = preload("res://scripts/Enums.gd")

@onready var room_code_input = $VBoxContainer/HBoxContainer/RoomCodeLineEdit
@onready var create_button = $VBoxContainer/CreateButton
@onready var join_button = $VBoxContainer/HBoxContainer/JoinButton
@onready var status_label = $StatusLabel
@onready var room_panel = $RoomPanel
@onready var code_label = $RoomPanel/VBoxContainer/CodeLabel
@onready var level_spinbox = $RoomPanel/VBoxContainer/HBoxContainer2/StartingLevelSpinBox
@onready var start_button = $RoomPanel/VBoxContainer/HBoxContainer/StartButton
@onready var leave_button = $RoomPanel/VBoxContainer/HBoxContainer/LeaveButton
@onready var keyboard_spacer = $VBoxContainer/KeyboardSpacer
@onready var room_status_label = $RoomPanel/VBoxContainer/StatusLabel
@onready var reconnect_button = $ReconnectButton
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

func _ready():
	if Network.is_dedicated_server:
		return

	room_panel.visible = false
	reconnect_button.visible = false
	create_button.pressed.connect(_on_create_pressed)
	join_button.pressed.connect(_on_join_pressed)
	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	level_spinbox.value_changed.connect(_on_level_changed)
	room_code_input.text_submitted.connect(func(_text): _on_join_pressed())
	room_code_input.gui_input.connect(_on_room_code_input_gui_input)
	reconnect_button.pressed.connect(_on_reconnect_pressed)
	
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

func _on_room_code_input_gui_input(event):
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		if event.pressed:
			room_code_input.grab_focus()

func _on_app_resume():
	if lost_connection:
		Network.connect_to_server()
		status_label.text = "Reconnecting..."

func _on_connection_failed():
	status_label.text = "Connection failed."
	lost_connection = true
	reconnect_button.visible = true

func _on_connected():
	status_label.text = "Connected to server"
	lost_connection = false
	reconnect_button.visible = false
	create_button.disabled = false
	join_button.disabled = false

func _on_reconnect_pressed():
	Network.connect_to_server()
	status_label.text = "Reconnecting..."

func _process(_delta):
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		var keyboard_height = DisplayServer.virtual_keyboard_get_height()/2.0
		keyboard_spacer.custom_minimum_size.y = keyboard_height

func _update_player_tiles(count: int) -> void:
	for i in range(player_tiles.size()):
		player_tiles[i].visible = i < count

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

func _on_leave_pressed():
	print_verbose("[CLIENT Lobby] _on_leave_pressed: Leaving room")
	_hide_room_panel()

func _on_room_updated(player_count: int, level: int):
	print_verbose("[CLIENT Lobby] _on_room_updated: new player_count=", player_count, " level=", level)
	_update_player_tiles(player_count)
	room_status_label.text = "Players: " + str(player_count)
	level_spinbox.value = level

func _on_game_starting(_player_number: int, _player_count: int, _level: int):
	print_verbose("[CLIENT Lobby] _on_game_starting: player_number=", _player_number, " player_count=", _player_count, " level=", _level)
	get_tree().change_scene_to_file("res://scenes/Main.tscn")
