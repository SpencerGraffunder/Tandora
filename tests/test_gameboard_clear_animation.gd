extends SceneTree

func _init() -> void:
	var board_script = load("res://scripts/GameBoard.gd")
	var board = board_script.new()
	board.board = [[0], [0]]
	board.set_clearing_rows([{"board_index": 5, "counter": 20}])
	var alpha = board.get_row_fade_alpha(5)
	assert(alpha > 0.0)
	var revealed = board.get_revealed_row_count(0.5)
	assert(revealed == 1)
	print("clear animation test passed")
	quit()
