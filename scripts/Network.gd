extends Node

const PORT = 7777
var SERVER_ADDRESS: String
var USE_WSS: bool

var players: Dictionary = {}
var starting_level: int = 0
var final_score: int = 0
var final_level: int = 0
var is_dedicated_server: bool = false
var starting_player_number: int = 0
var starting_player_count: int = 2
var touchscreen_enabled: bool = true
var room_device_ids: Dictionary = {}
var leaderboard_dir: String = "user://leaderboards"
var leaderboard_limit: int = 25

signal player_connected(id)
signal player_disconnected(id)
signal connection_failed
signal connection_succeeded
signal room_created(code)
signal room_joined(player_count, code)
signal room_updated(player_count, starting_level)

func _ready():
	_set_server_address_and_protocol()
	DirAccess.make_dir_absolute(leaderboard_dir)
	if DisplayServer.get_name() == "headless":
		is_dedicated_server = true
		start_dedicated_server()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)

func _set_server_address_and_protocol():
	if OS.has_feature("local"):
		SERVER_ADDRESS = "127.0.0.1:%d" % PORT
		USE_WSS = false
		print_verbose("[DEBUG] Using LOCAL server address:", SERVER_ADDRESS, "USE_WSS:", USE_WSS)
	else:
		SERVER_ADDRESS = "tandoraserver.nuclearquads.com"
		#SERVER_ADDRESS = "50.55.36.42:%d" % PORT
		USE_WSS = true
		print_verbose("[DEBUG] Using REMOTE server address:", SERVER_ADDRESS, "USE_WSS:", USE_WSS)

@rpc("any_peer", "call_remote", "reliable")
func rpc_request_full_sync():
	if not is_dedicated_server:
		return
	var sender = multiplayer.get_remote_sender_id()
	print_verbose("[SERVER] rpc_request_full_sync: Peer ", sender, " requested full snapshot")
	RoomManager.send_full_snapshot_to_peer(sender)

func start_dedicated_server():
	var peer = WebSocketMultiplayerPeer.new()
	var error = peer.create_server(PORT)
	if error != OK:
		printerr("[SERVER] Failed to start WebSocket server on port ", PORT, ": error code ", error)
		return
	multiplayer.multiplayer_peer = peer
	print_verbose("[SERVER] WebSocket server started on port ", PORT)
	print("[SERVER] Ready to host at ws://0.0.0.0:", PORT)

func connect_to_server():
	var peer = WebSocketMultiplayerPeer.new()
	var protocol = "wss" if USE_WSS else "ws"
	var uri = "%s://%s" % [protocol, SERVER_ADDRESS]
	print_verbose("[CLIENT] Attempting to connect to server at:", uri, "(protocol:", protocol, ")")
	var error = peer.create_client(uri)
	if error != OK:
		printerr("[CLIENT] Failed to connect to WebSocket server at ", uri, ": error code ", error)
		return
	multiplayer.multiplayer_peer = peer
	print("[CLIENT] Connecting to WebSocket server at ", uri)

func get_player_number() -> int:
	if multiplayer.is_server():
		return 0
	var my_id = multiplayer.get_unique_id()
	if players.has(my_id):
		return players[my_id].player_number
	return -1

func _physics_process(_delta):
	if is_dedicated_server:
		RoomManager.tick(_delta)

func _on_peer_connected(id):
	print_verbose("[SERVER/CLIENT] Peer connected: ", id, " (is_dedicated_server=", is_dedicated_server, ")")
	if is_dedicated_server:
		players[id] = { "id": id }
	player_connected.emit(id)

func _on_peer_disconnected(id):
	print_verbose("[SERVER/CLIENT] Peer disconnected: ", id, " (is_dedicated_server=", is_dedicated_server, ")")
	if is_dedicated_server:
		RoomManager.leave_room(id)
	players.erase(id)
	player_disconnected.emit(id)

func _on_connected_to_server():
	print_verbose("[CLIENT] Connected to server!")
	print_verbose("[CLIENT] Multiplayer peer info:", multiplayer.multiplayer_peer)
	connection_succeeded.emit()

func _on_connection_failed():
	print_verbose("[CLIENT] Connection failed.")
	print_verbose("[CLIENT] Multiplayer peer info:", multiplayer.multiplayer_peer)
	connection_failed.emit()

func save_leaderboard_entry(player_count: int, score: int, level: int, player_numbers: Array, username: String = "", timestamp: String = "") -> void:
	if player_count < 1 or player_count > 8:
		return
	var path = "%s/%d.json" % [leaderboard_dir, player_count]
	var entries: Array = []
	if FileAccess.file_exists(path):
		var file = FileAccess.open(path, FileAccess.READ)
		if file != null:
			var text = file.get_as_text()
			file.close()
			if text != "":
				var parsed = JSON.parse_string(text)
				if parsed is Array:
					entries = parsed
	var entry = {
		"score": int(score),
		"level": int(level),
		"timestamp": timestamp if timestamp != "" else Time.get_datetime_string_from_system(false, false),
		"usernames": [username] if username != "" else [],
		"player_numbers": player_numbers
	}
	entries.append(entry)
	entries.sort_custom(func(a, b):
		return a["score"] > b["score"]
	)
	if entries.size() > leaderboard_limit:
		entries.resize(leaderboard_limit)
	var file_out = FileAccess.open(path, FileAccess.WRITE)
	if file_out != null:
		file_out.store_string(JSON.stringify(entries, "  "))
		file_out.close()

func get_leaderboard(player_count: int, limit: int = 5) -> Array:
	if player_count < 1 or player_count > 8:
		return []
	var path = "%s/%d.json" % [leaderboard_dir, player_count]
	if not FileAccess.file_exists(path):
		return []
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var text = file.get_as_text()
	file.close()
	if text == "":
		return []
	var parsed = JSON.parse_string(text)
	if parsed is Array:
		var limited: Array = []
		for i in range(min(parsed.size(), limit)):
			limited.append(parsed[i])
		return limited
	return []

# ---- CLIENT -> SERVER RPCs ----

@rpc("any_peer", "call_remote", "reliable")
func rpc_create_room(level: int, device_id: String = ""): # device_id is optional for backward compatibility
	if not is_dedicated_server:
		return
	var sender = multiplayer.get_remote_sender_id()
	print_verbose("[SERVER] rpc_create_room: Peer ", sender, " creating room with level ", level, " device_id=", device_id)
	var code = RoomManager.create_room(sender, level)
	# Store device_id for reconnect logic
	if not room_device_ids.has(code):
		room_device_ids[code] = {}
	room_device_ids[code][device_id] = sender
	print_verbose("[SERVER] rpc_create_room: Created room code: ", code)
	rpc_room_created.rpc_id(sender, code)

@rpc("any_peer", "call_remote", "reliable")
func rpc_join_room(code: String, device_id: String = ""): # device_id is optional for backward compatibility
	if not is_dedicated_server:
		return
	var sender = multiplayer.get_remote_sender_id()
	print_verbose("[SERVER] rpc_join_room: Peer ", sender, " trying to join room ", code, " device_id=", device_id)
	# Reconnect logic: if device_id matches a previous player, reassign
	if room_device_ids.has(code) and room_device_ids[code].has(device_id):
		var old_sender = room_device_ids[code][device_id]
		print_verbose("[SERVER] rpc_join_room: Reconnecting device_id=", device_id, " old_sender=", old_sender, " new_sender=", sender)
		RoomManager.reassign_peer(code, old_sender, sender)
		room_device_ids[code][device_id] = sender
	else:
		if not room_device_ids.has(code):
			room_device_ids[code] = {}
		room_device_ids[code][device_id] = sender
		RoomManager.join_room(sender, code)
	var success = RoomManager.peer_to_room.has(sender)
	print_verbose("[SERVER] rpc_join_room: join_room returned ", success, " for sender=", sender, " code=", code)
	print_verbose("[SERVER] peer_to_room after join: ", RoomManager.peer_to_room)
	if success:
		var room = RoomManager.get_room_for_peer(sender)
		if room == null:
			print_verbose("[SERVER] ERROR: get_room_for_peer returned null for sender=", sender, " code=", code)
		else:
			print_verbose("[SERVER] rpc_join_room: Success - joining peer and notifying room with ", room.peers.size(), " peers")
			rpc_room_joined.rpc_id(sender, room.peers.size(), room.code)
			# notify all peers in room of updated count
			for peer_id in room.peers:
				print_verbose("[SERVER] rpc_join_room: Notifying peer ", peer_id, " of room update")
				rpc_room_updated.rpc_id(peer_id, room.peers.size(), room.starting_level)
	else:
		print_verbose("[SERVER] rpc_join_room: Failed - sending join_failed to peer ", sender)
		rpc_join_failed.rpc_id(sender)

@rpc("any_peer", "call_remote", "reliable")
func rpc_update_level(level: int):
	if not is_dedicated_server:
		return
	var sender = multiplayer.get_remote_sender_id()
	var room = RoomManager.get_room_for_peer(sender)
	if room == null or room.creator != sender:
		return
	room.starting_level = level
	for peer_id in room.peers:
		rpc_room_updated.rpc_id(peer_id, room.peers.size(), room.starting_level)

@rpc("any_peer", "call_remote", "reliable")
func rpc_start_game():
	if not is_dedicated_server:
		return
	var sender = multiplayer.get_remote_sender_id()
	print_verbose("[SERVER] rpc_start_game: Peer ", sender, " starting game")
	var room = RoomManager.get_room_for_peer(sender)
	if room == null or room.creator != sender:
		print_verbose("[SERVER] rpc_start_game: FAILED - room null or not creator")
		return
	var success = RoomManager.start_room(room.code)
	if success:
		print_verbose("[SERVER] rpc_start_game: Starting game for ", room.peers.size(), " peers")
		for i in range(room.peers.size()):
			print_verbose("[SERVER] rpc_start_game: Sending rpc_game_starting to peer ", room.peers[i], " with player number ", i)
			rpc_game_starting.rpc_id(room.peers[i], i, room.peers.size(), room.starting_level)

@rpc("any_peer", "call_remote", "reliable")
func rpc_player_input(player_number: int, control: String, pressed: bool):
	if not is_dedicated_server:
		return
	var sender = multiplayer.get_remote_sender_id()
	var room = RoomManager.get_room_for_peer(sender)
	if room == null or not room.started:
		return
	if control == "PAUSE":
		room.logic.paused = !room.logic.paused
		for peer_id in room.peers:
			rpc_set_paused.rpc_id(peer_id, room.logic.paused)
		return
	room.logic.do_input(player_number, control, pressed)

@rpc("authority", "call_remote", "reliable")
func rpc_set_paused(paused: bool):
	var main = get_tree().current_scene
	if main == null or not main.has_method("set_paused"):
		return
	main.set_paused(paused)

@rpc("any_peer", "call_remote", "reliable")
func rpc_leave_game():
	if not is_dedicated_server:
		print_verbose("[SERVER] rpc_leave_game called but not server, returning")
		return
	var sender = multiplayer.get_remote_sender_id()
	print_verbose("[SERVER] rpc_leave_game: Peer ", sender, " is leaving game")
	var room = RoomManager.get_room_for_peer(sender)
	print_verbose("[SERVER] rpc_leave_game: Room found: ", room != null, " Room code: ", room.code if room != null else "NONE")
	if room != null:
		print_verbose("[SERVER] rpc_leave_game: Room had ", room.peers.size(), " peers")
		RoomManager.leave_room(sender)
		print_verbose("[SERVER] rpc_leave_game: After leaving, room has ", room.peers.size(), " peers")

# ---- SERVER -> CLIENT RPCs ----

@rpc("authority", "call_remote", "reliable")
func rpc_room_created(code: String):
	print_verbose("[CLIENT] rpc_room_created: Room created with code: ", code)
	room_created.emit(code)

@rpc("authority", "call_remote", "reliable")
func rpc_room_joined(player_count: int, code: String):
	print_verbose("[CLIENT] rpc_room_joined: Joined room ", code, " with ", player_count, " players")
	room_joined.emit(player_count, code)

@rpc("authority", "call_remote", "reliable")
func rpc_room_updated(player_count: int, level: int):
	print_verbose("[CLIENT] rpc_room_updated: Room updated - ", player_count, " players, level ", level)
	room_updated.emit(player_count, level)

@rpc("authority", "call_remote", "reliable")
func rpc_join_failed():
	connection_failed.emit()

@rpc("authority", "call_remote", "reliable")
func rpc_game_starting(player_number: int, player_count: int, level: int):
	print_verbose("[CLIENT] rpc_game_starting: I am player ", player_number, " of ", player_count, " at level ", level)
	players[multiplayer.get_unique_id()] = { "player_number": player_number }
	starting_level = level
	starting_player_number = player_number
	starting_player_count = player_count
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

@rpc("authority", "call_remote", "unreliable_ordered")
func rpc_sync_state(data: PackedByteArray):
	var main = get_tree().current_scene
	if main == null or not main.has_method("rpc_sync_state"):
		return
	main.rpc_sync_state(data)

@rpc("authority", "call_remote", "reliable")
func rpc_game_over(score: int, level: int):
	print_verbose("[CLIENT] rpc_game_over received with score: ", score, " level: ", level)
	final_score = score
	final_level = level
	var main = get_tree().current_scene
	if main.has_method("trigger_game_over"):
		main.trigger_game_over(score, level)
