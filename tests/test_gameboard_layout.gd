extends SceneTree

# Headless layout test for issue #12: with the touchscreen controls hidden,
# the GameBoard rect grows and its tiles must re-scale to the larger rect
# (centered, scaled by min(w/cols, h/ROWS)) and notify dependents.

func _approx(a: float, b: float) -> bool:
	return absf(a - b) < 0.001

func _init() -> void:
	var board_script = load("res://scripts/GameBoard.gd")

	# --- 1-player board, phone-portrait viewport 390x844 ---
	var board = board_script.new()
	var emissions: Array = []
	board.tile_size_changed.connect(func(ts: float) -> void: emissions.append(ts))

	# Touch ON: GameBoard occupies anchors 0.1..0.6 => height fraction 0.5.
	board.size = Vector2(390, 844 * 0.5)
	board.init_board(1)
	var cols = 10
	var tile_on = board.tile_size
	assert(_approx(tile_on, minf(390.0 / cols, (844.0 * 0.5) / 20.0)))
	assert(emissions.size() == 1)

	# Touch OFF: anchors 0.1..1.0 => height fraction 0.9. Tiles must grow.
	board.size = Vector2(390, 844 * 0.9)
	assert(board._layout_tiles())
	var tile_off = board.tile_size
	assert(tile_off > tile_on)
	assert(_approx(tile_off, minf(390.0 / cols, (844.0 * 0.9) / 20.0)))
	assert(emissions.size() == 2)
	# Grid stays centered inside the larger rect.
	assert(_approx(board.offset.x, (390.0 - tile_off * cols) / 2.0))
	assert(_approx(board.offset.y, (844.0 * 0.9 - tile_off * 20.0) / 2.0))

	# Re-laying out with an unchanged rect is a no-op (no duplicate emit).
	assert(not board._layout_tiles())
	assert(emissions.size() == 2)

	# --- Landscape: wide rect, tile size ends up height-limited but still
	#     strictly larger than the touch-on strip; grid is width-centered. ---
	var wide = board_script.new()
	wide.size = Vector2(844, 390 * 0.5)
	wide.init_board(1)
	var wide_on = wide.tile_size
	wide.size = Vector2(844, 390 * 0.9)
	assert(wide._layout_tiles())
	assert(wide.tile_size > wide_on)
	assert(_approx(wide.tile_size, (390.0 * 0.9) / 20.0)) # height-limited
	assert(wide.offset.x > 0.0) # centered, margins left/right

	# --- Multiplayer column count still respected after a resize ---
	var mp = board_script.new()
	mp.size = Vector2(844, 390 * 0.5)
	mp.init_board(2) # 14 cols
	mp.size = Vector2(844, 390 * 0.9)
	mp._layout_tiles()
	assert(_approx(mp.tile_size, minf(844.0 / 14.0, (390.0 * 0.9) / 20.0)))

	print("gameboard layout test passed")
	board.free()
	wide.free()
	mp.free()
	quit()
