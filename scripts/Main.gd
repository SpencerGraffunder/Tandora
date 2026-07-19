extends Control

const GameLogicScript = preload("res://scripts/GameLogic.gd")
const Enums = preload("res://scripts/Enums.gd")
const PieceScript = preload("res://scripts/Piece.gd")

@onready var game_board = $GameBoard
@onready var preview_p1 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP1
@onready var preview_p2 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP2
@onready var preview_p3 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP3
@onready var preview_p4 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP4
@onready var preview_p5 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP5
@onready var preview_p6 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP6
@onready var preview_p7 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP7
@onready var preview_p8 = $VBoxContainer/NextPieceContainer/NextPiecePreviewP8
@onready var score_label = $VBoxContainer/StatsContainer/ScoreLabel
@onready var level_label = $VBoxContainer/StatsContainer/LevelLabel
@onready var lines_label = $VBoxContainer/StatsContainer/LinesLabel
@onready var pause_overlay = $PauseOverlay
@onready var player1_area = $Player1Area

var local_player_number: int = 0
var local_player_count: int = 2
var previews: Array = []

# Track previous action states to detect press/release
var prev_move_left: bool = false
var prev_move_right: bool = false
var prev_move_down: bool = false

var _last_received_seq: int = -1
var _waiting_for_full_sync: bool = false
var game_over_animation_active: bool = false


func _ready():
	local_player_number = Network.starting_player_number
	local_player_count = Network.starting_player_count
	game_board.init_board(local_player_count)
	
	# Populate the previews array
	previews = [preview_p1, preview_p2, preview_p3, preview_p4, preview_p5, preview_p6, preview_p7, preview_p8]
	
	# Show only previews for active players and initialize them
	for i in range(previews.size()):
		if i < local_player_count:
			previews[i].visible = true
			previews[i].board_tile_size = game_board.tile_size
		else:
			previews[i].visible = false

	print_verbose("Main ready, connecting signals")
	Network.player_disconnected.connect(_on_player_disconnected)

	$Player1Area/VBoxContainer/TopButtonRow/PauseButton.button_down.connect(_on_pause_pressed)
	$Player1Area/VBoxContainer/TopButtonRow/RotateLeftButton.button_down.connect(func(): _on_button("CCW", true))
	$Player1Area/VBoxContainer/TopButtonRow/RotateRightButton.button_down.connect(func(): _on_button("CW", true))
	$Player1Area/VBoxContainer/BottomButtonRow/LeftButton.button_down.connect(func(): _on_button("LEFT", true))
	$Player1Area/VBoxContainer/BottomButtonRow/LeftButton.button_up.connect(func(): _on_button("LEFT", false))
	$Player1Area/VBoxContainer/BottomButtonRow/RightButton.button_down.connect(func(): _on_button("RIGHT", true))
	$Player1Area/VBoxContainer/BottomButtonRow/RightButton.button_up.connect(func(): _on_button("RIGHT", false))
	$Player1Area/VBoxContainer/BottomButtonRow/DownButton.button_down.connect(func(): _on_button("DOWN", true))
	$Player1Area/VBoxContainer/BottomButtonRow/DownButton.button_up.connect(func(): _on_button("DOWN", false))
	$PauseOverlay/PausePanel/VBoxContainer/ResumeButton.pressed.connect(_on_pause_pressed)
	$PauseOverlay/PausePanel/VBoxContainer/MainMenuButton.pressed.connect(_on_main_menu_pressed)
	
	# Conditionally show/hide touch buttons based on settings
	_update_touch_buttons()

func _physics_process(_delta):
	# Check pause action
	if Input.is_action_just_pressed("pause"):
		_on_pause_pressed()
		return
	
	# Check movement and rotation actions
	if Input.is_action_just_pressed("rotate_cw"):
		_on_button("CW", true)
	if Input.is_action_just_pressed("rotate_ccw"):
		_on_button("CCW", true)
	
	# Detect press/release transitions for continuous actions
	var curr_move_left = Input.is_action_pressed("move_left")
	var curr_move_right = Input.is_action_pressed("move_right")
	var curr_move_down = Input.is_action_pressed("move_down")
	
	# LEFT
	if curr_move_left and not prev_move_left:
		_on_button("LEFT", true)
	elif not curr_move_left and prev_move_left:
		_on_button("LEFT", false)
	
	# RIGHT
	if curr_move_right and not prev_move_right:
		_on_button("RIGHT", true)
	elif not curr_move_right and prev_move_right:
		_on_button("RIGHT", false)
	
	# DOWN
	if curr_move_down and not prev_move_down:
		_on_button("DOWN", true)
	elif not curr_move_down and prev_move_down:
		_on_button("DOWN", false)
	
	# Update previous states
	prev_move_left = curr_move_left
	prev_move_right = curr_move_right
	prev_move_down = curr_move_down


func _on_button(control: String, pressed: bool) -> void:
	Network.rpc_player_input.rpc_id(1, local_player_number, control, pressed)

@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_sync_state(data: PackedByteArray):
	var buf := StreamPeerBuffer.new()
	buf.data_array = data
	buf.seek(0)

	var header = buf.get_u8()

	if header == 0x00:
		# Full snapshot — always apply regardless of dirty state
		_apply_full_snapshot(buf)
		_waiting_for_full_sync = false
	elif header == 0x01:
		# Delta packet
		if _waiting_for_full_sync:
			# Dirty — discard until we get a full snapshot
			return
		var seq = buf.get_u16()
		# Check for gap: seq should be exactly last+1, wrapping at 65535
		var expected = (_last_received_seq + 1) & 0xFFFF
		if _last_received_seq != -1 and seq != expected:
			print_verbose("[CLIENT] Sequence gap detected: expected ", expected, " got ", seq, " — requesting full sync")
			_waiting_for_full_sync = true
			Network.rpc_request_full_sync.rpc_id(1)
			return
		_last_received_seq = seq
		_apply_delta(buf)

func _apply_full_snapshot(buf: StreamPeerBuffer) -> void:
	var score = buf.get_u32()
	var level = buf.get_u16()
	var lines = buf.get_u32()
	score_label.text = "Score: " + str(score)
	level_label.text = "Level: " + str(level)
	lines_label.text = "Lines: " + str(lines)

	var player_count = buf.get_u8()
	var players_state = []
	for i in range(player_count):
		players_state.append(_read_player_from_buffer(buf))

	var clearing_line_count = buf.get_u8()
	var clearing_rows = []
	for i in range(clearing_line_count):
		clearing_rows.append({
			"board_index": buf.get_u8(),
			"counter": buf.get_u8()
		})

	var game_over_progress_value = buf.get_u8()
	var game_over_progress = clampf(float(game_over_progress_value) / 255.0, 0.0, 1.0)
	if game_over_progress >= 1.0:
		game_over_animation_active = false
		game_board.set_game_over_animation_progress(1.0)
	else:
		game_over_animation_active = true
		game_board.set_game_over_animation_progress(game_over_progress)

	var cell_count = buf.get_u16()
	# Full snapshot: reset board to all BLANK first, then apply cells
	game_board.reset_board_to_blank()
	for i in range(cell_count):
		var packed = buf.get_u16()
		var row = (packed >> 11) & 0x1F
		var col = (packed >> 5) & 0x3F
		var value = ((packed >> 1) & 0xF) - 1  # decode: subtract 1, BLANK = -1
		game_board.set_cell(row, col, value)

	game_board.set_clearing_rows(clearing_rows)
	_apply_players_state(players_state)

func _apply_delta(buf: StreamPeerBuffer) -> void:
	var score = buf.get_u32()
	var level = buf.get_u16()
	var lines = buf.get_u32()
	score_label.text = "Score: " + str(score)
	level_label.text = "Level: " + str(level)
	lines_label.text = "Lines: " + str(lines)

	var player_count = buf.get_u8()
	var players_state = []
	for i in range(player_count):
		players_state.append(_read_player_from_buffer(buf))

	var clearing_line_count = buf.get_u8()
	var clearing_rows = []
	for i in range(clearing_line_count):
		clearing_rows.append({
			"board_index": buf.get_u8(),
			"counter": buf.get_u8()
		})

	var game_over_progress_value = buf.get_u8()
	var game_over_progress = clampf(float(game_over_progress_value) / 255.0, 0.0, 1.0)
	if game_over_progress >= 1.0:
		game_over_animation_active = false
		game_board.set_game_over_animation_progress(1.0)
	else:
		game_over_animation_active = true
		game_board.set_game_over_animation_progress(game_over_progress)

	var cell_count = buf.get_u16()
	for i in range(cell_count):
		var packed = buf.get_u16()
		var row = (packed >> 11) & 0x1F
		var col = (packed >> 5) & 0x3F
		var value = ((packed >> 1) & 0xF) - 1  # decode: subtract 1, BLANK = -1
		game_board.set_cell(row, col, value)

	game_board.set_clearing_rows(clearing_rows)
	_apply_players_state(players_state)

func _read_player_from_buffer(buf: StreamPeerBuffer) -> Dictionary:
	var pd = {}
	pd.player_number = buf.get_u8()
	pd.piece_type = buf.get_u8()
	if pd.piece_type == 255:
		pd.piece_type = -1
	pd.piece_player = buf.get_u8()
	if pd.piece_player == 255:
		pd.piece_player = -1
	var piece_loc_count = buf.get_u8()
	pd.piece_locs = []
	for i in range(piece_loc_count):
		pd.piece_locs.append([buf.get_u8(), buf.get_u8()])  # col, row
	pd.next_type = buf.get_u8()
	if pd.next_type == 255:
		pd.next_type = -1
	var next_loc_count = buf.get_u8()
	pd.next_locs = []
	for i in range(next_loc_count):
		pd.next_locs.append([buf.get_u8(), buf.get_u8()])  # col, row
	return pd

func _apply_players_state(players_state: Array) -> void:
	for i in range(players_state.size()):
		var pd = players_state[i]
		if pd.next_locs.size() > 0:
			var dummy_piece = PieceScript.new(pd.next_type, pd.player_number, 0, local_player_count)
			for j in range(pd.next_locs.size()):
				dummy_piece.locations[j] = Vector2i(pd.next_locs[j][0], pd.next_locs[j][1])
			if i < previews.size():
				previews[i].set_piece(dummy_piece, i, local_player_count)
	game_board.set_active_pieces(players_state)
	game_board.queue_redraw()

func _on_pause_pressed():
	Network.rpc_player_input.rpc_id(1, local_player_number, "PAUSE", true)

func set_paused(p: bool) -> void:
	pause_overlay.visible = p
	$Player1Area/VBoxContainer/TopButtonRow/PauseButton.disabled = p
	$Player1Area/VBoxContainer/TopButtonRow/RotateLeftButton.disabled = p
	$Player1Area/VBoxContainer/TopButtonRow/RotateRightButton.disabled = p
	$Player1Area/VBoxContainer/BottomButtonRow/LeftButton.disabled = p
	$Player1Area/VBoxContainer/BottomButtonRow/DownButton.disabled = p
	$Player1Area/VBoxContainer/BottomButtonRow/RightButton.disabled = p

func _on_player_disconnected(_id):
	pass

func _on_main_menu_pressed():
	print_verbose("[CLIENT Main] _on_main_menu_pressed: Calling rpc_leave_game on server and returning to Lobby scene")
	Network.rpc_leave_game.rpc_id(1)
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")

@rpc("authority", "call_local", "reliable")
func trigger_game_over(score: int, level: int):
	print_verbose("[CLIENT Main] trigger_game_over: score=", score, " level=", level, " - finishing game-over animation")
	Network.final_score = score
	Network.final_level = level
	game_over_animation_active = false
	game_board.set_game_over_animation_progress(1.0)
	get_tree().change_scene_to_file("res://scenes/GameOver.tscn")

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		get_tree().quit()

func _update_touch_buttons():
	var show_touch_buttons = Network.touchscreen_enabled
	# Hide/show the entire touch button area
	player1_area.visible = show_touch_buttons
