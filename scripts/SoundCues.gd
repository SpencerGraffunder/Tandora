extends RefCounted
## Pure sound-cue detection (issue #15), kept side-effect free so it is
## testable headless (see tests/test_sound_cues.gd).
##
## The game is host-authoritative: every peer (the host included, it is in
## room.peers) receives the same sync packets in rpc_sync_state. Cues are
## therefore derived client-side by diffing successive state snapshots —
## no network protocol changes needed, and host and clients hear identical
## sounds.

## A snapshot is a Dictionary:
##   level: int
##   game_over_active: bool        true while the game-over reveal runs
##   clearing: Array[int]          board rows currently in the clear animation
##   pieces: Array[Array]          per player: sorted Array[[x, y], ...] of the
##                                 active piece's cells ([] when no active piece)

static func snapshot(level: int, game_over_active: bool, clearing_rows: Array, players_state: Array) -> Dictionary:
	var clearing = []
	for line in clearing_rows:
		if line is Dictionary and line.has("board_index"):
			clearing.append(int(line.board_index))
	var pieces = []
	for pd in players_state:
		var cells = []
		for loc in pd.piece_locs:
			cells.append([int(loc[0]), int(loc[1])])
		cells.sort_custom(func(a, b): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
		pieces.append(cells)
	return {
		"level": level,
		"game_over_active": game_over_active,
		"clearing": clearing,
		"pieces": pieces,
	}

## Returns an Array of cue Dictionaries ({"cue": name, "count": int?}).
## Pass an empty prev Dictionary to establish a silent baseline (first
## snapshot / after a resync) — detect() then returns no cues.
static func detect(prev: Dictionary, cur: Dictionary) -> Array:
	var cues = []
	if prev.is_empty() or cur.is_empty():
		return cues

	# --- line clears (appearance edge only: rows persist ~20 ticks) ------
	var new_rows = 0
	for idx in cur.clearing:
		if not prev.clearing.has(idx):
			new_rows += 1
	if new_rows > 0:
		if new_rows >= 4:
			cues.append({"cue": "tetris", "count": new_rows})
		else:
			cues.append({"cue": "clear", "count": new_rows})

	# --- per-player piece transitions ------------------------------------
	var player_count = min(prev.pieces.size(), cur.pieces.size())
	for i in range(player_count):
		var a = prev.pieces[i]
		var b = cur.pieces[i]
		if a.size() > 0 and b.size() == 0:
			# Locking coincides with a line clear on the same tick: the
			# clear sound already carries the moment (as in the original).
			if new_rows == 0:
				cues.append({"cue": "lock"})
		elif a.size() > 0 and b.size() > 0:
			if a.size() != b.size():
				# Same piece can't change cell count without rotating.
				cues.append({"cue": "rotate"})
				continue
			var dx = b[0][0] - a[0][0]
			var dy = b[0][1] - a[0][1]
			var translated = true
			for k in range(1, a.size()):
				if b[k][0] - a[k][0] != dx or b[k][1] - a[k][1] != dy:
					translated = false
					break
			if not translated:
				cues.append({"cue": "rotate"})
			elif dx != 0 and dy == 0:
				cues.append({"cue": "move"})
			# Vertical translation is a natural fall or soft drop: silent.
			# A shared board of falling pieces must never chatter.

	# --- level up ----------------------------------------------------------
	if cur.level > prev.level:
		cues.append({"cue": "levelup"})

	# --- game over (rising edge of the reveal animation) -------------------
	if cur.game_over_active and not prev.game_over_active:
		cues.append({"cue": "gameover"})

	return cues
