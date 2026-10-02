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
	name_label.text = _render_safe(display_name(entry))
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

## Render a name safely for display. The leaderboard name is the host's
## username, round-tripped over RPC -> server -> JSON -> RPC. On the mobile
## web client the default font has no glyph for control / format / private-use
## characters, so they show up as a "tofu" box. Strip those (and any unpaired
## surrogate) while keeping readable non-ASCII such as accented letters, so
## legitimate names still read. Falls back to "Anonymous" if nothing usable
## is left.
static func _render_safe(raw: String) -> String:
	var out := ""
	for i in range(raw.length()):
		var cp: int = raw.unicode_at(i)
		if cp < 0x20:
			continue  # C0 control
		if cp >= 0x7F and cp <= 0x9F:
			continue  # DEL + C1 control
		if cp >= 0x200B and cp <= 0x200F:
			continue  # zero-width spaces / directional marks
		if cp >= 0x202A and cp <= 0x202E:
			continue  # bidi controls
		if cp >= 0x2060 and cp <= 0x206F:
			continue  # invisible operators
		if cp == 0xFEFF or cp == 0x00AD:
			continue  # BOM / soft hyphen
		if cp >= 0xE000 and cp <= 0xF8FF:
			continue  # private use area (renders as tofu)
		if cp >= 0xD800 and cp <= 0xDFFF:
			continue  # unpaired surrogate (guard)
		if cp == 0xFFFE or cp == 0xFFFF:
			continue  # non-characters
		out += raw[i]
	var result := out.strip_edges()
	return result if result != "" else "Anonymous"
