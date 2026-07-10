extends ColorRect

const Enums = preload("res://scripts/Enums.gd")
const PieceScript = preload("res://scripts/Piece.gd")

var cols: int
var tile_size: float
var board: Array = []
var tile_textures: Dictionary = {}
var offset: Vector2
var game_state = null

func set_state(new_state) -> void:
	game_state = new_state
	if tile_size == 0:
		cols = game_state.board_width
		tile_size = min(size.x / cols, size.y / Enums.VISIBLE_ROWS)
		offset = Vector2(
			(size.x - (tile_size * cols)) / 2,
			(size.y - (tile_size * Enums.VISIBLE_ROWS)) / 2
		)

func init_board(player_count: int):
	cols = (4 * player_count) + 6
	tile_size = min(size.x / cols, size.y / Enums.VISIBLE_ROWS)
	offset = Vector2(
		(size.x - (tile_size * cols)) / 2,
		(size.y - (tile_size * Enums.VISIBLE_ROWS)) / 2
	)
	board = []
	for r in range(Enums.TOTAL_ROWS):
		var row = []
		for c in range(cols):
			row.append(Enums.TileType.BLANK)
		board.append(row)
	queue_redraw()

func _ready():
	load_textures()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func load_textures():
	tile_textures[0] = load("res://assets/backgroundblock.bmp")
	for i in range(10):
		var image = load("res://assets/tile_%d.png" % i)
		if image != null:
			var tex = ImageTexture.create_from_image(image.get_image())
			tile_textures[i + 1] = tex

func get_tile_texture(player_or_tile_value: int, player_count: int):
	"""Get the appropriate texture for a tile or piece based on game mode.
	
	Args:
		player_or_tile_value: Player number (multiplayer) or tile_type (singleplayer)
		player_count: Number of players in the game
	
	Returns:
		The texture for the given value, or background texture if not found
	"""
	if player_count > 1:
		# Multiplayer: use player number offset by 2
		var texture_index = player_or_tile_value + 2
		return tile_textures.get(texture_index, tile_textures[0])
	else:
		# Singleplayer: use tile_type directly
		return tile_textures.get(player_or_tile_value + 2, tile_textures[0])

func _draw():
	if game_state == null:
		return
	for r in range(board.size()):
		for c in range(board[r].size()):
			var tile = board[r][c]
			var screen_row = r - 2
			if screen_row < 0:
				continue
			var tex = tile_textures[0]
			if tile != Enums.TileType.BLANK:
				tex = get_tile_texture(tile, game_state.players.size())
			var pos = Vector2(offset.x + c * tile_size, offset.y + screen_row * tile_size)
			if tex:
				draw_texture_rect(tex, Rect2(pos, Vector2(tile_size, tile_size)), false)

	for p in game_state.players:
		if p.active_piece != null:
			for loc in p.active_piece.locations:
				var screen_row = loc.y - 2
				if screen_row < 0:
					continue
				var color_value = p.player_number if game_state.players.size() > 1 else p.active_piece.tile_type
				var tex = get_tile_texture(color_value, game_state.players.size())
				var pos = Vector2(offset.x + loc.x * tile_size, offset.y + screen_row * tile_size)
				if tex:
					draw_texture_rect(tex, Rect2(pos, Vector2(tile_size, tile_size)), false)

func reset_board_to_blank() -> void:
	for r in range(board.size()):
		for c in range(board[r].size()):
			board[r][c] = Enums.TileType.BLANK

func set_cell(row: int, col: int, value: int) -> void:
	if row < board.size() and col < board[row].size():
		board[row][col] = value

func set_active_pieces(players_state: Array) -> void:
	# Store player active piece state for _draw
	# Replace game_state.players with this lightweight version
	if game_state == null:
		game_state = {}
	game_state["players"] = []
	for pd in players_state:
		var player_entry = { "player_number": pd.player_number, "active_piece": null }
		if pd.piece_locs.size() > 0 and pd.piece_type != -1:
			var piece = PieceScript.new(pd.piece_type, pd.piece_player, 0, players_state.size())
			for j in range(pd.piece_locs.size()):
				piece.locations[j] = Vector2i(pd.piece_locs[j][0], pd.piece_locs[j][1])
			player_entry["active_piece"] = piece
		game_state["players"].append(player_entry)
