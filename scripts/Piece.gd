extends RefCounted

const Enums = preload("res://scripts/Enums.gd")

var piece_type: int
var tile_type: int
var rotation: int = 0
var locations: Array = [null, null, null, null]
var player_number: int

func _init(p_piece_type: int, p_player_number: int, spawn_column: int, player_count: int):
	piece_type = p_piece_type
	player_number = p_player_number

	match piece_type:
		Enums.PieceType.I:
			locations[0] = Vector2i(spawn_column - 2, 2)
			locations[1] = Vector2i(spawn_column - 1, 2)
			locations[2] = Vector2i(spawn_column,     2)
			locations[3] = Vector2i(spawn_column + 1, 2)
			tile_type = Enums.TileType.IOT
		Enums.PieceType.O:
			locations[0] = Vector2i(spawn_column - 1, 2)
			locations[1] = Vector2i(spawn_column,     2)
			locations[2] = Vector2i(spawn_column - 1, 3)
			locations[3] = Vector2i(spawn_column,     3)
			tile_type = Enums.TileType.IOT
		Enums.PieceType.T:
			locations[0] = Vector2i(spawn_column - 1, 2)
			locations[1] = Vector2i(spawn_column,     2)
			locations[2] = Vector2i(spawn_column + 1, 2)
			locations[3] = Vector2i(spawn_column,     3)
			tile_type = Enums.TileType.IOT
		Enums.PieceType.L:
			locations[0] = Vector2i(spawn_column - 1, 2)
			locations[1] = Vector2i(spawn_column,     2)
			locations[2] = Vector2i(spawn_column + 1, 2)
			locations[3] = Vector2i(spawn_column - 1, 3)
			tile_type = Enums.TileType.LZ
		Enums.PieceType.J:
			locations[0] = Vector2i(spawn_column - 1, 2)
			locations[1] = Vector2i(spawn_column,     2)
			locations[2] = Vector2i(spawn_column + 1, 2)
			locations[3] = Vector2i(spawn_column + 1, 3)
			tile_type = Enums.TileType.JS
		Enums.PieceType.Z:
			locations[0] = Vector2i(spawn_column - 1, 2)
			locations[1] = Vector2i(spawn_column,     2)
			locations[2] = Vector2i(spawn_column,     3)
			locations[3] = Vector2i(spawn_column + 1, 3)
			tile_type = Enums.TileType.LZ
		Enums.PieceType.S:
			locations[0] = Vector2i(spawn_column,     2)
			locations[1] = Vector2i(spawn_column + 1, 2)
			locations[2] = Vector2i(spawn_column - 1, 3)
			locations[3] = Vector2i(spawn_column,     3)
			tile_type = Enums.TileType.JS

	if player_count != 1:
		tile_type = player_number

func move(direction: int, locs: Array = []) -> void:
	if locs.is_empty():
		locs = locations
	match direction:
		Enums.Direction.DOWN:
			for i in range(locs.size()):
				locs[i] = Vector2i(locs[i].x, locs[i].y + 1)
		Enums.Direction.LEFT:
			for i in range(locs.size()):
				locs[i] = Vector2i(locs[i].x - 1, locs[i].y)
		Enums.Direction.RIGHT:
			for i in range(locs.size()):
				locs[i] = Vector2i(locs[i].x + 1, locs[i].y)

func can_move(board: Array, players: Array, direction) -> int:
	var test_locs = locations.duplicate()

	if direction != null:
		move(direction, test_locs)

	for loc in test_locs:
		if loc.y >= board.size() or loc.x < 0 or loc.x >= board[0].size():
			return Enums.MoveAllowance.CANT_BOARD
		if direction != null:
			if board[loc.y][loc.x] != Enums.TileType.BLANK:
				return Enums.MoveAllowance.CANT_BOARD
		for player in players:
			if player.active_piece != null:
				if player.active_piece.player_number != player_number:
					for other_loc in player.active_piece.locations:
						if other_loc == loc:
							return Enums.MoveAllowance.CANT_PIECE

	return Enums.MoveAllowance.CAN

func rotate(rotation_direction: int, locs: Array = [], rot = null) -> int:
	var save_rotation = false
	if locs.is_empty():
		locs = locations
	if rot == null:
		save_rotation = true
		rot = rotation

	var new_rotation = rot

	match piece_type:
		Enums.PieceType.O:
			pass
		Enums.PieceType.I, Enums.PieceType.S, Enums.PieceType.Z:
			var turn = -1
			var pivot: Vector2i
			if piece_type == Enums.PieceType.I:
				pivot = locs[2]
				turn = Enums.Rotation.CW if rot in [0, 180] else Enums.Rotation.CCW
			elif piece_type == Enums.PieceType.S:
				pivot = Vector2i(locs[0].x, locs[0].y)
				turn = Enums.Rotation.CCW if rot in [0, 180] else Enums.Rotation.CW
			elif piece_type == Enums.PieceType.Z:
				pivot = Vector2i(locs[1].x, locs[1].y)
				turn = Enums.Rotation.CCW if rot in [0, 180] else Enums.Rotation.CW
			if turn == Enums.Rotation.CW:
				for i in range(locs.size()):
					locs[i] = Vector2i((pivot.y - locs[i].y) + pivot.x, (locs[i].x - pivot.x) + pivot.y)
				new_rotation = (rot + 90) % 360
			elif turn == Enums.Rotation.CCW:
				for i in range(locs.size()):
					locs[i] = Vector2i((locs[i].y - pivot.y) + pivot.x, (pivot.x - locs[i].x) + pivot.y)
				new_rotation = (rot - 90) % 360
		Enums.PieceType.T, Enums.PieceType.L, Enums.PieceType.J:
			var pivot = Vector2i(locs[1].x, locs[1].y)
			if rotation_direction == Enums.Rotation.CW:
				for i in range(locs.size()):
					locs[i] = Vector2i((pivot.y - locs[i].y) + pivot.x, (locs[i].x - pivot.x) + pivot.y)
				new_rotation = (rot + 90) % 360
			elif rotation_direction == Enums.Rotation.CCW:
				for i in range(locs.size()):
					locs[i] = Vector2i((locs[i].y - pivot.y) + pivot.x, (pivot.x - locs[i].x) + pivot.y)
				new_rotation = (rot - 90) % 360

	if save_rotation:
		rotation = new_rotation
	return new_rotation

func can_rotate(board: Array, players: Array, rotation_direction: int) -> bool:
	var test_locs = locations.duplicate()
	var test_rotation = rotation

	rotate(rotation_direction, test_locs, test_rotation)

	for loc in test_locs:
		if loc.y >= board.size() or loc.x < 0 or loc.x >= board[0].size():
			return false
		if board[loc.y][loc.x] != Enums.TileType.BLANK:
			return false
		for player in players:
			if player.active_piece != null:
				if player.active_piece.player_number != player_number:
					for other_loc in player.active_piece.locations:
						if other_loc == loc:
							return false
	return true