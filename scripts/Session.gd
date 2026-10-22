extends Node
## Client-side account session manager (the UI task's half of the accounts
## feature — the server half is scripts/AccountService.gd; protocol contract
## in docs/accounts.md).
##
## What this node owns:
## - The current session (token + user identity) and its persistence in
##   user://session.json (atomic writes, schema_version envelope).
## - The account RPC calls used by the UI: create / login / logout /
##   validate, matched request/response on Network.account_response.
##
## Security notes:
## - The token is a bearer credential; it is the ONLY thing stored on the
##   client. No password is ever kept on the client after it is sent.
## - The token is never logged (same invariant as the server store).
## - user:// is the browser's IndexedDB on web exports and the per-user
##   app-data dir natively; there is no stronger cross-platform option in
##   Godot. The server treats the token as the sole proof of login and
##   enforces it on protected game actions (room create/join).
## - A restored session is optimistic (is_logged_in = true) until
##   validate() confirms it with the server; the Lobby triggers that on
##   every successful connection.

signal session_changed

const SESSION_FILE := "user://session.json"
const SCHEMA_VERSION := 1
const TOKEN_HEX_LEN := 64  # must match AccountService.TOKEN_HEX_LEN
const RPC_TIMEOUT_SECONDS := 15.0
# Server errors that mean "can't reach the server" — inconclusive for the
# validity of a stored session (validate() must NOT clear the session on
# these, or a slow first connection would nuke a good login).
const INCONCLUSIVE_ERRORS := ["NOT_CONNECTED", "TIMEOUT"]

var user_id: String = ""
var user_email: String = ""
var session_token: String = ""
var expires_at: int = 0  # unix seconds, informational (server slides it)
var is_logged_in: bool = false

var _request_seq: int = 0
var _pending: Dictionary = {}  # request_id -> _Reply


class _Reply:
	signal wake
	var done: bool = false
	var result: Dictionary = {"ok": false, "error": "", "data": {}}


func _ready() -> void:
	# Autoload order: Network comes first, so the signal exists.
	Network.account_response.connect(_on_account_response)
	restore_from_disk()


# ---- RPC plumbing (request/response over the Network account RPCs) ----

func _on_account_response(request_id: int, ok: bool, error: String, data: Dictionary) -> void:
	var reply: _Reply = _pending.get(request_id)
	if reply == null or reply.done:
		return
	reply.done = true
	reply.result = {"ok": ok, "error": error, "data": data}
	_pending.erase(request_id)
	reply.wake.emit()


func _on_reply_timeout(request_id: int) -> void:
	var reply: _Reply = _pending.get(request_id)
	if reply == null or reply.done:
		return
	reply.done = true
	reply.result = {"ok": false, "error": "TIMEOUT", "data": {}}
	_pending.erase(request_id)
	reply.wake.emit()


func _can_send() -> bool:
	if Network.multiplayer.multiplayer_peer == null:
		return false
	# Godot 4.7: SceneMultiplayer exposes get_peers(), not has_peer().
	return Network.multiplayer.get_peers().has(1)


## One account RPC round-trip. Returns {"ok", "error", "data"}; errors are
## the server codes from docs/accounts.md plus NOT_CONNECTED / TIMEOUT.
func _rpc(action: String, email: String, secret: String, timeout_seconds: float = RPC_TIMEOUT_SECONDS) -> Dictionary:
	if not _can_send():
		return {"ok": false, "error": "NOT_CONNECTED", "data": {}}
	_request_seq += 1
	var request_id := _request_seq
	var reply := _Reply.new()
	_pending[request_id] = reply
	var timer := get_tree().create_timer(timeout_seconds)
	timer.timeout.connect(_on_reply_timeout.bind(request_id))
	Network.rpc_account_request.rpc_id(1, request_id, action, email, secret)
	await reply.wake
	return reply.result


# ---- public operations (all awaitable) ----

func has_saved_session() -> bool:
	return session_token != ""


func create_account(email: String, password: String) -> Dictionary:
	return await _rpc("create", email.strip_edges(), password)


func login(email: String, password: String) -> Dictionary:
	var r: Dictionary = await _rpc("login", email.strip_edges(), password)
	if r["ok"]:
		session_token = str(r["data"].get("token", ""))
		user_id = str(r["data"].get("user_id", ""))
		user_email = str(r["data"].get("email", email.strip_edges().to_lower()))
		expires_at = int(r["data"].get("expires_at", 0))
		is_logged_in = session_token != ""
		_save_to_disk()
		session_changed.emit()
	return r


func logout() -> Dictionary:
	if session_token == "":
		return {"ok": true, "error": "", "data": {}}
	var r: Dictionary = await _rpc("logout", "", session_token)
	# Local logout is local: clear even if the server was unreachable
	# (the server-side session then lives out its 30-day sliding TTL).
	_clear_session()
	return r


## Confirms the stored session with the server (also slides its expiry).
## Clears the session only on a definitive server rejection; network
## failures are inconclusive and keep the session as-is.
func validate() -> Dictionary:
	if session_token == "":
		return {"ok": false, "error": "INVALID_SESSION", "data": {}}
	var r: Dictionary = await _rpc("validate", "", session_token)
	if r["ok"]:
		user_id = str(r["data"].get("user_id", user_id))
		user_email = str(r["data"].get("email", user_email))
		is_logged_in = true
		_save_to_disk()
		session_changed.emit()
	elif not INCONCLUSIVE_ERRORS.has(r["error"]):
		_clear_session()
	return r


# ---- state & persistence ----

func _clear_session() -> void:
	session_token = ""
	user_id = ""
	user_email = ""
	expires_at = 0
	is_logged_in = false
	_delete_from_disk()
	session_changed.emit()


func restore_from_disk() -> void:
	if not FileAccess.file_exists(SESSION_FILE):
		return
	var file: FileAccess = FileAccess.open(SESSION_FILE, FileAccess.READ)
	if file == null:
		_delete_from_disk()
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary) or int(parsed.get("schema_version", 0)) != SCHEMA_VERSION:
		_delete_from_disk()
		return
	var saved_token := str(parsed.get("token", ""))
	# Malformed token on disk — drop it rather than trust it.
	if saved_token.length() != TOKEN_HEX_LEN:
		_delete_from_disk()
		return
	session_token = saved_token
	user_id = str(parsed.get("user_id", ""))
	user_email = str(parsed.get("email", ""))
	expires_at = int(parsed.get("expires_at", 0))
	# Optimistic until validate() confirms (see header comment).
	is_logged_in = true


func _save_to_disk() -> void:
	var payload := {
		"schema_version": SCHEMA_VERSION,
		"token": session_token,
		"user_id": user_id,
		"email": user_email,
		"expires_at": expires_at,
		"saved_at": int(Time.get_unix_time_from_system()),
	}
	# Atomic write so a crash mid-write can't corrupt the session file.
	var tmp := SESSION_FILE + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[Session] cannot write ", tmp)
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	if DirAccess.rename_absolute(tmp, SESSION_FILE) != OK:
		push_error("[Session] rename failed for ", tmp)
		DirAccess.remove_absolute(tmp)


func _delete_from_disk() -> void:
	if FileAccess.file_exists(SESSION_FILE):
		DirAccess.remove_absolute(SESSION_FILE)
