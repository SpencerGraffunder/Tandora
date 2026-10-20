extends Node
## Server-side account store and session manager (dedicated server only).
##
## "Endpoints" in this codebase are Godot multiplayer RPC routes on the
## existing WebSocket channel (see Network.gd):
##   client -> server: rpc_account_request(request_id, action, email, secret)
##   server -> client: rpc_account_response(request_id, ok, error, data)
## actions: "create" | "login" | "logout" | "validate"
## secret is the password (create/login) or the session token (logout/validate).
## The service answers by emitting `response_ready`; Network bridges it to
## the response RPC addressed to the requesting peer.
##
## Storage: two JSON files under the data dir (users.json, sessions.json),
## each wrapped in an envelope {"schema_version": N, ...}. Versioned
## upgrades live in _migrate_users / _migrate_sessions — see
## docs/migrations.md. The data dir defaults to /app/data in the container
## (the only persistent volume); see _resolve_data_dir.
##
## Security notes:
## - Passwords: PBKDF2-HMAC-SHA256, per-user 16-byte salt, iteration count
##   stored per hash (PasswordHasher). Plaintext never touched again after
##   creation and never logged (only the lowercased email is logged).
## - Login answers are the same error for unknown email and wrong password
##   (no user enumeration), and unknown emails still pay a full KDF against
##   a dummy hash (no timing enumeration).
## - Sessions: 256-bit tokens from /dev/urandom, 30-day sliding expiry,
##   capped per user. Tokens are never logged.
## - Brute force: 5 failed logins per connection => 60 s lockout.

signal response_ready(sender: int, request_id: int, ok: bool, error: String, data: Dictionary)

const SCHEMA_VERSION := 1
const SESSION_TTL_SECONDS := 30 * 24 * 3600  # 30 days, sliding
const MAX_SESSIONS_PER_USER := 10
const MAX_LOGIN_FAILURES := 5
const LOGIN_LOCKOUT_SECONDS := 60
const TOKEN_HEX_LEN := 64  # 32 random bytes, hex encoded
const _EMAIL_RE := "^[A-Za-z0-9._%+-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\\.[A-Za-z]{2,}$"
const _EMAIL_MAX_LEN := 254
const _EMAIL_LOCAL_MAX := 64

var data_dir: String = ""
var users_path: String = ""
var sessions_path: String = ""
var users: Array = []  # [{"id","email","email_key","display_name","password_hash","created_at","updated_at"}]
var sessions: Dictionary = {}  # token -> {"token","user_id","email_key","created_at","expires_at","last_validated_at"}
var _login_failures: Dictionary = {}  # peer_id -> {"fails": int, "locked_until": int(unix)}
var _dummy_hash: String = ""
var _initialized := false
var _email_regex: RegEx


func _ready():
	# Only the dedicated server (headless) owns the account store. Clients
	# (web/native) must not create local account files.
	if DisplayServer.get_name() == "headless":
		ensure_ready()


func _init_regex() -> void:
	if _email_regex == null:
		_email_regex = RegEx.new()
		_email_regex.compile(_EMAIL_RE)


## Idempotent init. Pass an explicit dir to override resolution (tests).
func ensure_ready(data_dir_override: String = "") -> void:
	if _initialized:
		return
	_init_regex()
	data_dir = _resolve_data_dir(data_dir_override)
	DirAccess.make_dir_recursive_absolute(data_dir)
	users_path = data_dir.path_join("users.json")
	sessions_path = data_dir.path_join("sessions.json")
	users = _load_users()
	sessions = _load_sessions()
	_initialized = true
	print("[SERVER] Accounts: data dir ", data_dir, " (", users.size(), " users, ", sessions.size(), " active sessions)")


func _resolve_data_dir(override_dir: String) -> String:
	if override_dir != "":
		return override_dir
	var args: Array = OS.get_cmdline_args()
	for arg in OS.get_cmdline_user_args():
		if not args.has(arg):
			args.append(arg)
	for arg in args:
		if arg.begins_with("--accounts_dir="):
			return arg.get_slice("=", 1)
	# /app is the mounted volume in the server container (user:// there is
	# ephemeral and wiped on every deploy — see docs/accounts-baseline.md).
	if DirAccess.dir_exists_absolute("/app"):
		return "/app/data"
	return "user://data"


# ---- request routing ----

func handle_request(sender: int, request_id: int, action: String, email: String, secret: String) -> void:
	ensure_ready()
	var result: Dictionary
	var now := int(Time.get_unix_time_from_system())
	match action:
		"create":
			result = create_account(email, secret)
		"login":
			if _is_locked_out(sender, now):
				result = _err("RATE_LIMITED")
				print("[SERVER] Accounts: login locked out for peer ", sender)
			else:
				result = login(email, secret)
				if result["ok"]:
					_login_failures.erase(sender)
				elif result["error"] == "INVALID_CREDENTIALS":
					_register_failure(sender, now)
		"logout":
			result = logout(secret)
		"validate":
			result = validate_session(secret)
		_:
			result = _err("UNKNOWN_ACTION")
	response_ready.emit(sender, request_id, result["ok"], result["error"], result["data"])


func peer_left(sender: int) -> void:
	_login_failures.erase(sender)


# ---- operations (each returns {"ok": bool, "error": String, "data": Dictionary}) ----

func create_account(email: String, password: String) -> Dictionary:
	email = email.strip_edges()
	var email_key := email.to_lower()
	if not _valid_email(email, email_key):
		return _err("INVALID_EMAIL")
	if not PasswordHasher.is_valid_password(password):
		return _err("WEAK_PASSWORD")
	for u in users:
		if u["email_key"] == email_key:
			print("[SERVER] Accounts: rejected duplicate email ", email_key)
			return _err("EMAIL_TAKEN")
	var now_iso := _now_iso()
	var display_name := email_key.get_slice("@", 0).left(16)
	var user = {
		"id": _new_id("usr"),
		"email": email,
		"email_key": email_key,
		"display_name": display_name,
		"password_hash": PasswordHasher.hash(password),
		"created_at": now_iso,
		"updated_at": now_iso,
	}
	users.append(user)
	_save_users()
	print("[SERVER] Accounts: created account ", email_key)
	return _ok({"user_id": user["id"], "email": email_key})


func login(email: String, password: String) -> Dictionary:
	email = email.strip_edges()
	var email_key := email.to_lower()
	var user: Variant = _find_user(email_key)
	# Unknown emails verify against a dummy hash so response timing does not
	# reveal which emails are registered.
	var hash_to_check: String
	if user != null:
		hash_to_check = user["password_hash"]
	else:
		hash_to_check = _dummy_password_hash()
	if not PasswordHasher.verify(password, hash_to_check) or user == null:
		print("[SERVER] Accounts: login failed for ", email_key)
		return _err("INVALID_CREDENTIALS")
	var token := SecureRandom.new().random_bytes(TOKEN_HEX_LEN / 2).hex_encode()
	var now := int(Time.get_unix_time_from_system())
	_evict_oldest_sessions(user["id"])
	sessions[token] = {
		"token": token,
		"user_id": user["id"],
		"email_key": email_key,
		"created_at": now,
		"expires_at": now + SESSION_TTL_SECONDS,
		"last_validated_at": now,
	}
	_save_sessions()
	print("[SERVER] Accounts: login ok for ", email_key)
	return _ok({
		"user_id": user["id"],
		"email": email_key,
		"token": token,
		"expires_at": now + SESSION_TTL_SECONDS,
	})


func logout(token: String) -> Dictionary:
	if sessions.has(token):
		sessions.erase(token)
		_save_sessions()
		print("[SERVER] Accounts: session revoked")
	return _ok({})


func validate_session(token: String) -> Dictionary:
	if token.length() != TOKEN_HEX_LEN or not _is_hex(token):
		return _err("INVALID_SESSION")
	var s: Variant = sessions.get(token)
	if s == null:
		return _err("INVALID_SESSION")
	var now := int(Time.get_unix_time_from_system())
	if int(s["expires_at"]) <= now:
		sessions.erase(token)
		_save_sessions()
		print("[SERVER] Accounts: session expired")
		return _err("INVALID_SESSION")
	var user: Variant = _find_user_by_id(s["user_id"])
	if user == null:
		sessions.erase(token)
		_save_sessions()
		return _err("INVALID_SESSION")
	# Sliding expiry.
	s["expires_at"] = now + SESSION_TTL_SECONDS
	s["last_validated_at"] = now
	_save_sessions()
	return _ok({"user_id": user["id"], "email": user["email_key"]})


# ---- rate limiting (per connected peer) ----

func _is_locked_out(sender: int, now: int) -> bool:
	var entry: Variant = _login_failures.get(sender)
	if entry == null:
		return false
	return int(entry["locked_until"]) > now


func _register_failure(sender: int, now: int) -> void:
	var fails := 0
	var locked_until := 0
	var entry: Variant = _login_failures.get(sender)
	if entry != null:
		fails = int(entry["fails"])
		locked_until = int(entry["locked_until"])
	fails += 1
	if fails >= MAX_LOGIN_FAILURES:
		locked_until = now + LOGIN_LOCKOUT_SECONDS
		_login_failures[sender] = {"fails": 0, "locked_until": locked_until}
	else:
		_login_failures[sender] = {"fails": fails, "locked_until": 0}


# ---- lookups & helpers ----

func _find_user(email_key: String):
	for u in users:
		if u["email_key"] == email_key:
			return u
	return null


func _find_user_by_id(user_id: String):
	for u in users:
		if u["id"] == user_id:
			return u
	return null


func _valid_email(email: String, email_key: String) -> bool:
	if email.length() == 0 or email.length() > _EMAIL_MAX_LEN:
		return false
	var at := email.rfind("@")
	if at <= 0 or at >= email.length() - 1:
		return false
	if at > _EMAIL_LOCAL_MAX:
		return false
	# Exactly one '@': the key check catches a second one in the domain.
	if email_key.count("@") != 1:
		return false
	return _email_regex.search(email) != null


func _evict_oldest_sessions(user_id: String) -> void:
	var owned: Array = []
	for token in sessions.keys():
		if sessions[token]["user_id"] == user_id:
			owned.append(sessions[token])
	if owned.size() < MAX_SESSIONS_PER_USER:
		return
	owned.sort_custom(func(a, b):
		return int(a["created_at"]) < int(b["created_at"])
	)
	var excess := owned.size() - MAX_SESSIONS_PER_USER + 1  # +1: the new session is added after
	for i in range(min(excess, owned.size())):
		sessions.erase(owned[i]["token"])


func _dummy_password_hash() -> String:
	if _dummy_hash == "":
		# Lazily computed so it never slows server startup; ~1.5 s once.
		_dummy_hash = PasswordHasher.hash("tandora-timing-dummy-0")
	return _dummy_hash


func _new_id(prefix: String) -> String:
	return prefix + "_" + SecureRandom.new().random_bytes(12).hex_encode()


func _now_iso() -> String:
	# "YYYY-MM-DDTHH:MM:SSZ" in UTC (use_space=false gives the 'T' separator;
	# the dict is already UTC, and 'Z' makes that explicit per ISO 8601).
	return Time.get_datetime_string_from_datetime_dict(Time.get_datetime_dict_from_system(true), false) + "Z"


func _is_hex(s: String) -> bool:
	for i in range(s.length()):
		var c := s[i]
		if (c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F"):
			continue
		return false
	return true


func _ok(data: Dictionary) -> Dictionary:
	return {"ok": true, "error": "", "data": data}


func _err(code: String) -> Dictionary:
	return {"ok": false, "error": code, "data": {}}


# ---- persistence & migrations ----

func _load_users() -> Array:
	var parsed: Variant = _read_json(users_path)
	if parsed == null:
		return []
	var migrated := _migrate_users(parsed)
	# Persist the (possibly migrated) file so each schema runs once.
	_write_json_atomic(users_path, {"schema_version": SCHEMA_VERSION, "users": migrated})
	return migrated


func _load_sessions() -> Dictionary:
	var parsed: Variant = _read_json(sessions_path)
	if parsed == null:
		return {}
	var migrated := _migrate_sessions(parsed)
	_write_json_atomic(sessions_path, {"schema_version": SCHEMA_VERSION, "sessions": migrated})
	return migrated


## v0 (legacy): bare JSON array of user objects, no envelope.
## v1: {"schema_version": 1, "users": [...]}.
func _migrate_users(parsed) -> Array:
	var raw = parsed
	if parsed is Dictionary:
		var v := int(parsed.get("schema_version", 0))
		if v > SCHEMA_VERSION:
			push_warning("[SERVER] Accounts: users.json schema v%d is newer than supported v%d — loading as-is" % [v, SCHEMA_VERSION])
		elif v < SCHEMA_VERSION:
			push_warning("[SERVER] Accounts: migrating users.json from v%d to v%d" % [v, SCHEMA_VERSION])
		raw = parsed.get("users", [])
	elif not (parsed is Array):
		push_error("[SERVER] Accounts: users.json has unrecognized format — starting empty (backup kept at users.json.bak)")
		_backup_file(users_path)
		return []
	return _normalize_user_list(raw)


func _migrate_sessions(parsed) -> Dictionary:
	var raw = parsed
	if parsed is Dictionary:
		var v := int(parsed.get("schema_version", 0))
		if v > SCHEMA_VERSION:
			push_warning("[SERVER] Accounts: sessions.json schema v%d is newer than supported v%d — loading as-is" % [v, SCHEMA_VERSION])
		elif v < SCHEMA_VERSION:
			push_warning("[SERVER] Accounts: migrating sessions.json from v%d to v%d" % [v, SCHEMA_VERSION])
		raw = parsed.get("sessions", {})
	elif not (parsed is Dictionary):
		push_error("[SERVER] Accounts: sessions.json has unrecognized format — starting empty")
		_backup_file(sessions_path)
		return {}
	var out: Dictionary = {}
	if raw is Dictionary:
		for token in raw.keys():
			var s = raw[token]
			if s is Dictionary and s.has("user_id") and s.has("expires_at"):
				out[token] = {
					"token": token,
					"user_id": str(s["user_id"]),
					"email_key": str(s.get("email_key", "")),
					"created_at": int(s.get("created_at", 0)),
					"expires_at": int(s["expires_at"]),
					"last_validated_at": int(s.get("last_validated_at", int(s.get("created_at", 0)))),
				}
	return out


## Normalizes each legacy user entry to the v1 shape (fills ids/timestamps,
## drops entries that cannot be salvaged).
func _normalize_user_list(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var email_key := str(entry.get("email_key", entry.get("email", ""))).to_lower()
		var password_hash := str(entry.get("password_hash", ""))
		if email_key == "" or password_hash == "":
			continue
		var user_id := str(entry.get("id", ""))
		if user_id == "":
			user_id = _new_id("usr")
		var now_iso := _now_iso()
		out.append({
			"id": user_id,
			"email": str(entry.get("email", email_key)),
			"email_key": email_key,
			"display_name": str(entry.get("display_name", email_key.get_slice("@", 0).left(16))),
			"password_hash": password_hash,
			"created_at": str(entry.get("created_at", now_iso)),
			"updated_at": str(entry.get("updated_at", now_iso)),
		})
	return out


func _save_users() -> void:
	_write_json_atomic(users_path, {"schema_version": SCHEMA_VERSION, "users": users})


func _save_sessions() -> void:
	_write_json_atomic(sessions_path, {"schema_version": SCHEMA_VERSION, "sessions": sessions})


func _backup_file(path: String) -> void:
	var bak := path + ".bak"
	# Godot 4 DirAccess: copy_absolute(from, to) — there is no copy_file().
	if DirAccess.copy_absolute(path, bak) != OK:
		push_error("[SERVER] Accounts: backup copy failed for ", path, " (err ", DirAccess.get_open_error(), ")")
		return
	print("[SERVER] Accounts: backed up unreadable file to ", bak)


func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[SERVER] Accounts: cannot open ", path, " (err ", FileAccess.get_open_error(), ")")
		return null
	var text := f.get_as_text()
	f.close()
	if text.strip_edges() == "":
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_error("[SERVER] Accounts: invalid JSON in ", path)
		return null
	return parsed


## Write to <path>.tmp then rename over <path> so a crash mid-write can
## never leave a truncated credential file.
func _write_json_atomic(path: String, data) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[SERVER] Accounts: cannot write ", tmp, " (err ", FileAccess.get_open_error(), ")")
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	# Godot 4 DirAccess: rename_absolute(from, to) — there is no rename_file().
	if DirAccess.rename_absolute(tmp, path) != OK:
		push_error("[SERVER] Accounts: rename failed for ", tmp, " (err ", DirAccess.get_open_error(), ")")
		DirAccess.remove_absolute(tmp)
