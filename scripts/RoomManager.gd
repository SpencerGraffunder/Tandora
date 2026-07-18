extends Node

const GameLogicScript = preload("res://scripts/GameLogic.gd")
const Enums = preload("res://scripts/Enums.gd")
const ROOM_TIMEOUT = 900  # 15 minutes in seconds
const CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
const FULL_SYNC_HEADER: int = 0x00
const DELTA_HEADER: int = 0x01

var rooms: Dictionary = {}  # code -> Room
var peer_to_room: Dictionary = {}  # peer_id -> room_code

class Room:
	var code: String
	var peers: Array = []  # peer ids
	var logic: Object = null
	var started: bool = false
	var creator: int = 0
	var starting_level: int = 0
	var idle_timer: float = 0.0
	var last_sent_board: Array = []   # flat copy of board after last send
	var last_sent_seq: int = 0        # sequence number of last sent delta packet
	var has_sent_initial_snapshot: bool = false

	func _init(p_code: String, p_creator: int):
		code = p_code
		creator = p_creator
		peers.append(p_creator)

func generate_code() -> String:
	var code_length = 3
	if OS.has_feature("local"):
		code_length = 1
	while true:
		var code = ""
		for i in range(code_length):
			code += String.chr(randi() % 26 + 97)
		if not rooms.has(code):
			return code
	return ""

func create_room(creator_id: int, starting_level: int) -> String:
	var code = generate_code()
	var room = Room.new(code, creator_id)
	room.starting_level = starting_level
	rooms[code] = room
	peer_to_room[creator_id] = code
	print_verbose("[SERVER RoomManager] create_room: Room created: ", code, " by peer ", creator_id, " at level ", starting_level)
	return code

func join_room(peer_id: int, code: String) -> bool:
	code = code.to_lower()
	if not rooms.has(code):
		print_verbose("[SERVER RoomManager] join_room: Room ", code, " not found")
		return false
	var room = rooms[code]
	if room.started:
		print_verbose("[SERVER RoomManager] join_room: Room ", code, " already started")
		return false
	if room.peers.size() >= 8:
		print_verbose("[SERVER RoomManager] join_room: Room ", code, " is full")
		return false
	if not room.peers.has(peer_id):
		room.peers.append(peer_id)
	peer_to_room[peer_id] = code
	print_verbose("[SERVER RoomManager] join_room: Peer ", peer_id, " joined room ", code, " (now ", room.peers.size(), " peers)")
	return true

func reassign_peer(code: String, old_peer_id: int, new_peer_id: int) -> void:
	if not rooms.has(code):
		print_verbose("[SERVER RoomManager] reassign_peer: Room ", code, " not found")
		return
	var room = rooms[code]
	if old_peer_id == new_peer_id:
		print_verbose("[SERVER RoomManager] reassign_peer: old_peer_id and new_peer_id are the same (", old_peer_id, ")")
		return
	if not room.peers.has(old_peer_id):
		print_verbose("[SERVER RoomManager] reassign_peer: old_peer_id ", old_peer_id, " not in room ", code)
		return
	room.peers.erase(old_peer_id)
	if not room.peers.has(new_peer_id):
		room.peers.append(new_peer_id)
	peer_to_room.erase(old_peer_id)
	peer_to_room[new_peer_id] = code
	print_verbose("[SERVER RoomManager] reassign_peer: Reassigned ", old_peer_id, " to ", new_peer_id, " in room ", code)

func leave_room(peer_id: int) -> void:
	print_verbose("[SERVER RoomManager] leave_room: Peer ", peer_id, " leaving")
	if not peer_to_room.has(peer_id):
		print_verbose("[SERVER RoomManager] leave_room: Peer not in any room")
		return
	var code = peer_to_room[peer_id]
	peer_to_room.erase(peer_id)
	if not rooms.has(code):
		print_verbose("[SERVER RoomManager] leave_room: Room ", code, " not found")
		return
	var room = rooms[code]
	room.peers.erase(peer_id)
	print_verbose("[SERVER RoomManager] leave_room: Room ", code, " now has ", room.peers.size(), " peers")
	if room.peers.is_empty():
		print_verbose("[SERVER RoomManager] leave_room: Room is now empty, dissolving")
		dissolve_room(code)
	else:
		print_verbose("[SERVER RoomManager] leave_room: Room still has players, keeping it alive")

func dissolve_room(code: String) -> void:
	if not rooms.has(code):
		print_verbose("[SERVER RoomManager] dissolve_room: Room ", code, " not found")
		return
	var room = rooms[code]
	print_verbose("[SERVER RoomManager] dissolve_room: Dissolving room ", code, " with peers: ", room.peers)
	for peer_id in room.peers:
		peer_to_room.erase(peer_id)
	rooms.erase(code)
	print_verbose("[SERVER RoomManager] dissolve_room: Room ", code, " dissolved")

func start_room(code: String) -> bool:
	if not rooms.has(code):
		return false
	var room = rooms[code]
	if room.started:
		return false
	room.logic = GameLogicScript.new()
	room.logic.reset(room.peers.size(), room.starting_level)
	room.logic.game_over_triggered.connect(func(): _on_game_over(code))
	room.started = true
	# Initialize last_sent_board to all BLANK so first tick diffs as fully changed
	var board_width = (4 * room.peers.size()) + 6
	room.last_sent_board = []
	for r in range(Enums.TOTAL_ROWS):
		var row = []
		for c in range(board_width):
			row.append(Enums.TileType.BLANK)
		room.last_sent_board.append(row)
	room.last_sent_seq = 0
	print_verbose("Room started: ", code, " with ", room.peers.size(), " players")
	return true

func get_room_for_peer(peer_id: int) -> Room:
	if not peer_to_room.has(peer_id):
		print_verbose("[SERVER RoomManager] get_room_for_peer: peer_id ", peer_id, " not in peer_to_room. peer_to_room=", peer_to_room)
		return null
	var code = peer_to_room[peer_id]
	if not rooms.has(code):
		print_verbose("[SERVER RoomManager] get_room_for_peer: code ", code, " not in rooms. rooms=", rooms.keys())
		return null
	return rooms[code]

func tick(delta: float) -> void:
	for code in rooms.keys():
		var room = rooms[code]
		if room.started and room.logic != null:
			room.logic.tick()
			_sync_room_state(code)
		else:
			room.idle_timer += delta
			if room.idle_timer >= ROOM_TIMEOUT:
				print_verbose("Room timed out: ", code)
				dissolve_room(code)

func _sync_room_state(code: String) -> void:
	if not rooms.has(code):
		return
	var room = rooms[code]
	var board = room.logic.state.board
	
	if not room.has_sent_initial_snapshot:
		var players_data_compat = _serialize_players(room)
		var score_data_compat = {
			"score": room.logic.state.score,
			"level": room.logic.state.current_level,
			"lines_cleared": room.logic.lines_cleared
		}
		var packet_compat = _serialize_full_snapshot(room, players_data_compat, score_data_compat)
		# Update last_sent_board
		for r in range(board.size()):
			for c in range(board[r].size()):
				room.last_sent_board[r][c] = board[r][c]
		for peer_id in room.peers:
			Network.rpc_sync_state.rpc_id(peer_id, packet_compat)
		room.has_sent_initial_snapshot = true
		return

	# Build changed cells list by diffing against last_sent_board
	var changed_cells: Array = []  # each entry: [row, col, value]
	for r in range(board.size()):
		for c in range(board[r].size()):
			var current_val = board[r][c]
			var last_val = room.last_sent_board[r][c] if room.last_sent_board.size() > r else Enums.TileType.BLANK
			if current_val != last_val:
				changed_cells.append([r, c, current_val])

	# Serialize player piece state (always included, small)
	var players_data = _serialize_players(room)

	# Serialize score data
	var score_data = {
		"score": room.logic.state.score,
		"level": room.logic.state.current_level,
		"lines_cleared": room.logic.lines_cleared
	}

	var packet: PackedByteArray
	var full_cell_count = board.size() * board[0].size()

	if changed_cells.size() >= full_cell_count:
		# Delta is at least as big as full board — send full snapshot
		packet = _serialize_full_snapshot(room, players_data, score_data)
	else:
		room.last_sent_seq = (room.last_sent_seq + 1) & 0xFFFF
		packet = _serialize_delta(room, changed_cells, players_data, score_data)

	# Update last_sent_board to current state
	for r in range(board.size()):
		for c in range(board[r].size()):
			room.last_sent_board[r][c] = board[r][c]

	for peer_id in room.peers:
		Network.rpc_sync_state.rpc_id(peer_id, packet)

# Sends a full snapshot to a single peer (for resync requests)
func send_full_snapshot_to_peer(peer_id: int) -> void:
	var room = get_room_for_peer(peer_id)
	if room == null or not room.started:
		return
	var players_data = _serialize_players(room)
	var score_data = {
		"score": room.logic.state.score,
		"level": room.logic.state.current_level,
		"lines_cleared": room.logic.lines_cleared
	}
	var packet = _serialize_full_snapshot(room, players_data, score_data)
	Network.rpc_sync_state.rpc_id(peer_id, packet)

func _serialize_players(room) -> Array:
	var players_data = []
	for p in room.logic.state.players:
		var piece_locs = []
		var piece_type = -1
		var piece_player = -1
		if p.active_piece != null:
			for loc in p.active_piece.locations:
				piece_locs.append([loc.x, loc.y])
			piece_type = p.active_piece.piece_type
			piece_player = p.active_piece.player_number
		var next_locs = []
		var next_type = -1
		if p.next_piece != null:
			for loc in p.next_piece.locations:
				next_locs.append([loc.x, loc.y])
			next_type = p.next_piece.piece_type
		players_data.append({
			"player_number": p.player_number,
			"piece_locs": piece_locs,
			"piece_type": piece_type,
			"piece_player": piece_player,
			"next_locs": next_locs,
			"next_type": next_type
		})
	return players_data

# Packet format (full snapshot):
# [0x00]                    1 byte  header
# [score]                   4 bytes int32
# [level]                   2 bytes uint16
# [lines_cleared]           4 bytes int32
# [player_count]            1 byte
# [per player: see _write_player_to_buffer]
# [cell_count]              2 bytes uint16 — number of non-BLANK cells
# [per cell: uint16]        2 bytes each, see _pack_cell
func _serialize_full_snapshot(room, players_data: Array, score_data: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(FULL_SYNC_HEADER)
	buf.put_u32(score_data.score)
	buf.put_u16(score_data.level)
	buf.put_u32(score_data.lines_cleared)
	buf.put_u8(players_data.size())
	for pd in players_data:
		_write_player_to_buffer(buf, pd)

	# Write all non-BLANK cells
	var board = room.logic.state.board
	var non_blank: Array = []
	for r in range(board.size()):
		for c in range(board[r].size()):
			if board[r][c] != Enums.TileType.BLANK:
				non_blank.append([r, c, board[r][c]])
	buf.put_u16(non_blank.size())
	for cell in non_blank:
		buf.put_u16(_pack_cell(cell[0], cell[1], cell[2]))

	return buf.data_array

# Packet format (delta):
# [0x01]                    1 byte  header
# [seq]                     2 bytes uint16
# [score]                   4 bytes int32
# [level]                   2 bytes uint16
# [lines_cleared]           4 bytes int32
# [player_count]            1 byte
# [per player: see _write_player_to_buffer]
# [cell_count]              2 bytes uint16 — number of changed cells
# [per cell: uint16]        2 bytes each, see _pack_cell
func _serialize_delta(room, changed_cells: Array, players_data: Array, score_data: Dictionary) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u8(DELTA_HEADER)
	buf.put_u16(room.last_sent_seq)
	buf.put_u32(score_data.score)
	buf.put_u16(score_data.level)
	buf.put_u32(score_data.lines_cleared)
	buf.put_u8(players_data.size())
	for pd in players_data:
		_write_player_to_buffer(buf, pd)
	buf.put_u16(changed_cells.size())
	for cell in changed_cells:
		buf.put_u16(_pack_cell(cell[0], cell[1], cell[2]))
	return buf.data_array

# Per-player layout:
# [player_number]           1 byte
# [piece_type]              1 byte (255 = no piece)
# [piece_player]            1 byte (255 = no piece)
# [piece_loc_count]         1 byte
# [per loc: col, row]       2 bytes each (1 byte col, 1 byte row)
# [next_type]               1 byte (255 = no next)
# [next_loc_count]          1 byte
# [per loc: col, row]       2 bytes each
func _write_player_to_buffer(buf: StreamPeerBuffer, pd: Dictionary) -> void:
	buf.put_u8(pd.player_number)
	buf.put_u8(pd.piece_type if pd.piece_type != -1 else 255)
	buf.put_u8(pd.piece_player if pd.piece_player != -1 else 255)
	buf.put_u8(pd.piece_locs.size())
	for loc in pd.piece_locs:
		buf.put_u8(loc[0])  # col
		buf.put_u8(loc[1])  # row
	buf.put_u8(pd.next_type if pd.next_type != -1 else 255)
	buf.put_u8(pd.next_locs.size())
	for loc in pd.next_locs:
		buf.put_u8(loc[0])  # col
		buf.put_u8(loc[1])  # row

# Cell packing: 16 bits
# [row: 5 bits][col: 6 bits][value+1: 4 bits][unused: 1 bit]
# value is stored as value+1 so BLANK(-1) becomes 0, types 0-8 become 1-9
func _pack_cell(row: int, col: int, value: int) -> int:
	var encoded_value = value + 1  # BLANK(-1)->0, types 0-8 -> 1-9
	return ((row & 0x1F) << 11) | ((col & 0x3F) << 5) | ((encoded_value & 0xF) << 1)

func _on_game_over(code: String) -> void:
	if not rooms.has(code):
		print_verbose("[SERVER RoomManager] _on_game_over: Room ", code, " not found")
		return
	var room = rooms[code]
	var player_numbers: Array = []
	for i in range(room.peers.size()):
		player_numbers.append(i)
	var timestamp = Time.get_datetime_string_from_system(false, false)
	Network.save_leaderboard_entry(room.peers.size(), room.logic.state.score, room.logic.state.current_level, player_numbers, "", timestamp)
	print_verbose("[SERVER RoomManager] _on_game_over: Sending game over to ", room.peers.size(), " peers in room ", code)
	for peer_id in room.peers:
		print_verbose("[SERVER RoomManager] _on_game_over: Sending rpc_game_over to peer ", peer_id)
		Network.rpc_game_over.rpc_id(peer_id, room.logic.state.score, room.logic.state.current_level)
	dissolve_room(code)
