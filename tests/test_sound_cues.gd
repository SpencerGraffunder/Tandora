extends SceneTree

# Headless test for the pure sound-cue diff logic (issue #15).
# Run: godot --headless --path . --script tests/test_sound_cues.gd

func _init() -> void:
	var cues_script = load("res://scripts/SoundCues.gd")

	# Horizontal move -> "move"
	var prev = cues_script.snapshot(0, false, [], [{"piece_locs": [[3, 10], [4, 10], [4, 11], [5, 11]]}])
	var cur = cues_script.snapshot(0, false, [], [{"piece_locs": [[4, 10], [5, 10], [5, 11], [6, 11]]}])
	assert(_names(cues_script.detect(prev, cur)) == ["move"])

	# Vertical fall is silent (a board of falling pieces must not chatter)
	cur = cues_script.snapshot(0, false, [], [{"piece_locs": [[3, 11], [4, 11], [4, 12], [5, 12]]}])
	assert(_names(cues_script.detect(prev, cur)) == [])

	# Unchanged state -> no cues
	assert(_names(cues_script.detect(cur, cur)) == [])

	# Rotation (same cell count, not a translation) -> "rotate"
	cur = cues_script.snapshot(0, false, [], [{"piece_locs": [[4, 10], [4, 11], [4, 12], [5, 10]]}])
	assert(_names(cues_script.detect(prev, cur)) == ["rotate"])

	# Cell-count change -> "rotate"
	cur = cues_script.snapshot(0, false, [], [{"piece_locs": [[3, 10], [4, 10], [5, 10]]}])
	assert(_names(cues_script.detect(prev, cur)) == ["rotate"])

	# Piece disappears -> "lock"
	cur = cues_script.snapshot(0, false, [], [{"piece_locs": []}])
	assert(_names(cues_script.detect(prev, cur)) == ["lock"])

	# Piece spawns in silently
	prev = cur
	cur = cues_script.snapshot(0, false, [], [{"piece_locs": [[5, 2], [6, 2], [5, 3], [6, 3]]}])
	assert(_names(cues_script.detect(prev, cur)) == [])

	# New clearing rows -> "clear"; persistent rows do not retrigger
	prev = cues_script.snapshot(0, false, [], [{"piece_locs": []}])
	cur = cues_script.snapshot(0, false, [{"board_index": 19}], [{"piece_locs": []}])
	assert(_names(cues_script.detect(prev, cur)) == ["clear"])
	assert(_names(cues_script.detect(cur, cur)) == [])

	# Lock on the same tick as a clear: clear wins alone
	prev = cues_script.snapshot(0, false, [], [{"piece_locs": [[3, 10], [4, 10], [4, 11], [5, 11]]}])
	cur = cues_script.snapshot(0, false, [{"board_index": 19}], [{"piece_locs": []}])
	assert(_names(cues_script.detect(prev, cur)) == ["clear"])

	# Four simultaneous new rows -> "tetris"
	var four = []
	for r in range(16, 20):
		four.append({"board_index": r})
	cur = cues_script.snapshot(0, false, four, [{"piece_locs": []}])
	assert(_names(cues_script.detect(prev, cur)) == ["tetris"])

	# Clear sound carries its line count for pitch selection
	prev = cues_script.snapshot(0, false, [], [{"piece_locs": []}])
	cur = cues_script.snapshot(0, false, [{"board_index": 18}, {"board_index": 19}], [{"piece_locs": []}])
	var cues = cues_script.detect(prev, cur)
	assert(cues.size() == 1 and cues[0]["cue"] == "clear" and int(cues[0]["count"]) == 2)

	# Level up -> "levelup"
	prev = cues_script.snapshot(3, false, [], [{"piece_locs": []}])
	cur = cues_script.snapshot(4, false, [], [{"piece_locs": []}])
	assert(_names(cues_script.detect(prev, cur)) == ["levelup"])
	assert(_names(cues_script.detect(cur, prev)) == [])  # never on decrease

	# Game over reveal fires once on the rising edge
	prev = cues_script.snapshot(4, false, [], [{"piece_locs": []}])
	cur = cues_script.snapshot(4, true, [], [{"piece_locs": []}])
	assert(_names(cues_script.detect(prev, cur)) == ["gameover"])
	assert(_names(cues_script.detect(cur, cur)) == [])

	# Empty baseline (first snapshot / resync) is silent
	assert(cues_script.detect({}, cur) == [])
	assert(cues_script.detect(cur, {}) == [])

	# Multiplayer: cues are detected per piece
	prev = cues_script.snapshot(0, false, [],
		[{"piece_locs": [[1, 10]]}, {"piece_locs": [[8, 10]]}])
	cur = cues_script.snapshot(0, false, [],
		[{"piece_locs": [[2, 10]]}, {"piece_locs": [[8, 11]]}])
	assert(_names(cues_script.detect(prev, cur)) == ["move"])  # move yes, fall silent

	print("sound cues test passed")
	quit()

func _names(cues: Array) -> Array:
	var out = []
	for cue in cues:
		out.append(cue["cue"])
	return out
