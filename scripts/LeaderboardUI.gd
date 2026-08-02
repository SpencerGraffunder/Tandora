extends RefCounted
## Shared leaderboard row rendering, used by both the Lobby and Game Over
## scenes so the layout stays consistent in one place.

static func build_row(rank: int, entry: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var rank_label = Label.new()
	rank_label.text = str(rank + 1) + "."
	rank_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var is_me = is_mine(entry)
	var name_label = Label.new()
	name_label.text = display_name(entry)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	if is_me:
		name_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.3))

	var score_label = Label.new()
	score_label.text = ("★ " if is_me else "") + str(int(entry.get("score", 0)))
	score_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	row.add_child(rank_label)
	row.add_child(name_label)
	row.add_child(score_label)
	return row

static func display_name(entry: Dictionary) -> String:
	var usernames = entry.get("usernames", [])
	if usernames is Array and usernames.size() > 0:
		return ", ".join(usernames)
	return "Anonymous"

static func is_mine(entry: Dictionary) -> bool:
	var my_name = Network.username.strip_edges()
	if my_name == "":
		return false
	var usernames = entry.get("usernames", [])
	return usernames is Array and usernames.has(my_name)
