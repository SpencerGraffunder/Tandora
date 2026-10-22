extends Node
## Autoload (issue #15): sound-effect playback with a small voice pool and a
## master volume / mute persisted to user://. There is intentionally no UI
## yet — the options screen (issue #12) is meant to expose these setters.

const SOUND_DIR := "res://assets/sounds/"
const CUES := ["clear", "gameover", "levelup", "lock", "move", "pause", "resume", "rotate", "tetris"]
const POOL_SIZE := 12
const CFG_PATH := "user://audio.cfg"
const MUTE_DB := -80.0

var master_volume: float = 1.0  # linear 0..1, applied to the Master bus
var muted: bool = false

var _streams: Dictionary = {}
var _players: Array = []
var _last_start: Array = []  # per-voice start tick (ms) for voice stealing

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for cue in CUES:
		var stream: AudioStream = load(SOUND_DIR + cue + ".ogg")
		if stream == null:
			push_warning("SoundManager: missing sound asset '%s.ogg'" % cue)
		else:
			_streams[cue] = stream
	for i in range(POOL_SIZE):
		var player := AudioStreamPlayer.new()
		add_child(player)
		_players.append(player)
		_last_start.append(-1.0)
	_load_settings()
	_apply_master()

## Play one named cue ("move", "lock", "clear", ...).
func play(cue: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> void:
	if muted or not _streams.has(cue):
		return
	var index := _acquire_voice()
	var player: AudioStreamPlayer = _players[index]
	player.stream = _streams[cue]
	player.volume_db = volume_db
	player.pitch_scale = pitch_scale
	player.play()
	_last_start[index] = Time.get_ticks_msec()

## Map a cue Dictionary from SoundCues.detect() to playback.
func play_cue(cue: Dictionary) -> void:
	match cue.get("cue", ""):
		"clear":
			# 1/2/3 lines: same arpeggio pitched up (0/4/7 semitones).
			var steps := [0.0, 4.0, 7.0]
			var i := clampi(int(cue.get("count", 1)) - 1, 0, steps.size() - 1)
			play("clear", 0.0, pow(2.0, steps[i] / 12.0))
		"tetris", "lock", "move", "rotate", "levelup", "gameover", "pause", "resume":
			play(str(cue.get("cue", "")))
		_:
			push_warning("SoundManager: unknown cue '%s'" % str(cue.get("cue", "")))

func set_master_volume(value: float) -> void:
	master_volume = clampf(value, 0.0, 1.0)
	_apply_master()
	_save_settings()

func set_muted(value: bool) -> void:
	muted = value
	_apply_master()
	_save_settings()

func _apply_master() -> void:
	var bus := AudioServer.get_bus_index("Master")
	if muted or master_volume <= 0.0:
		AudioServer.set_bus_volume_db(bus, MUTE_DB)
	else:
		AudioServer.set_bus_volume_db(bus, linear_to_db(master_volume))

## Free voice, else steal the one that started playing longest ago.
func _acquire_voice() -> int:
	var oldest := 0
	var oldest_start := INF
	for i in range(_players.size()):
		var player: AudioStreamPlayer = _players[i]
		if not player.playing:
			return i
		if _last_start[i] < oldest_start:
			oldest_start = _last_start[i]
			oldest = i
	return oldest

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	master_volume = clampf(cfg.get_value("audio", "master_volume", 1.0), 0.0, 1.0)
	muted = bool(cfg.get_value("audio", "muted", false))

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "muted", muted)
	var err := cfg.save(CFG_PATH)
	if err != OK:
		push_warning("SoundManager: could not save %s (%s)" % [CFG_PATH, error_string(err)])
