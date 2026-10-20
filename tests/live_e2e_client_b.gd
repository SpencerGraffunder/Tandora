extends Node
## LIVE E2E client B (joiner): authenticates on the DEPLOYED dedicated
## server (wss://tandoraserver.nuclearquads.com) and exercises the
## protected join gate — bogus/empty token rejected, VALID token accepted.
##
## Companion to live_e2e_client_a.gd (the host). Orchestrated by
## tests/run_live_e2e.sh — NOT part of the default local suite.
##
## Run:
##   godot --headless res://tests/live_e2e_client_b.tscn \
##       -- --port=<stray> --room_code=<code from client A>
##
## Exits 0 on success, 1 on any failure.

const SERVER_URL := "wss://tandoraserver.nuclearquads.com"
const CONNECT_TIMEOUT_MS := 30000
const FLOW_TIMEOUT_MS := 180000
const SIG_TIMEOUT_MS := 15000
const TEST_PASSWORD := "correct-horse-battery-staple-42!"
const SESSION_FILE := "user://session.json"

var failures: int = 0
var _connected := false
var _flow_started := false
var _deadline_ms: int = 0
var _test_email: String = ""
var _room_code: String = ""
var _request_seq: int = 0


class _Waiter:
	signal done(result)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--room_code="):
			_room_code = arg.get_slice("=", 1)
	var ts := int(Time.get_unix_time_from_system())
	_test_email = "e2e-live-b-%d@tandora.test" % ts
	if FileAccess.file_exists(SESSION_FILE):
		DirAccess.remove_absolute(SESSION_FILE)
	if Session.is_logged_in:
		Session._clear_session()

	if _room_code == "":
		_fail("missing --room_code=")
		return

	_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	print("[LIVE_B] connecting to ", SERVER_URL, " (email=", _test_email, ")")
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client(SERVER_URL) != OK:
		_fail("create_client failed")
		return
	Network.multiplayer.multiplayer_peer = peer
	Network.multiplayer.connected_to_server.connect(_on_connected)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _connected and now > _deadline_ms:
		_fail("timed out waiting for connection to " + SERVER_URL)
	elif _flow_started and now > _deadline_ms:
		_fail("timed out in flow")


func _on_connected() -> void:
	_connected = true
	_deadline_ms = Time.get_ticks_msec() + FLOW_TIMEOUT_MS
	_flow_started = true
	Network.username = "e2e-live-joiner"
	print("[LIVE_B] connected (peer id %d)" % Network.multiplayer.get_unique_id())
	_run_flow()


## Awaitable account RPC via the Network autoload.
func rpc_call(action: String, email: String, secret: String) -> Dictionary:
	_request_seq += 1
	var id := _request_seq
	var waiter := _Waiter.new()
	var conn := func(rid: int, ok: bool, error: String, data: Dictionary):
		if rid == id:
			waiter.done.emit({"ok": ok, "error": error, "data": data})
	Network.account_response.connect(conn, CONNECT_ONE_SHOT)
	Network.rpc_account_request.rpc_id(1, id, action, email, secret)
	var timer := get_tree().create_timer((SIG_TIMEOUT_MS + 60000) / 1000.0)
	timer.timeout.connect(func(): waiter.done.emit(null))
	var args: Variant = await waiter.done
	if args == null:
		return {"ok": false, "error": "TIMEOUT", "data": {}}
	return args


func _wait_signal(sig: Signal, timeout_ms: int) -> Variant:
	var waiter := _Waiter.new()
	var conn := func(args: Array):
		waiter.done.emit(args)
	sig.connect(conn, CONNECT_ONE_SHOT)
	var timer := get_tree().create_timer(timeout_ms / 1000.0)
	timer.timeout.connect(func(): waiter.done.emit(null))
	var args: Variant = await waiter.done
	if args == null:
		sig.disconnect(conn)
	return args


func _check(label: String, cond: bool) -> void:
	if cond:
		print("  ok  - ", label)
	else:
		failures += 1
		printerr("  FAIL - ", label)


func _fail(msg: String) -> void:
	printerr("[LIVE_B] FATAL: ", msg)
	failures += 1
	get_tree().quit(1)


func _run_flow() -> void:
	var r: Dictionary

	print("[LIVE_B] 1. create account (Session API)")
	r = await Session.create_account(_test_email, TEST_PASSWORD)
	_check("create ok", r["ok"] and String(r["data"].get("user_id", "")).begins_with("usr_"))

	print("[LIVE_B] 2. login (Session API)")
	r = await Session.login(_test_email, TEST_PASSWORD)
	_check("login ok", r["ok"] and Session.session_token.length() == 64)
	_check("is_logged_in", Session.is_logged_in)

	print("[LIVE_B] 3. protected join: NO token => rejected")
	var args: Variant = await _wait_protected_join(_room_code, "")
	_check("join_failed NOT_AUTHENTICATED (empty token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	print("[LIVE_B] 4. protected join: VALID token => room_joined")
	args = await _wait_protected_join(_room_code, Session.session_token)
	_check("room_joined with valid session",
		args != null and String(args[0]) == "joined" and String(args[2]) == _room_code)
	_check("room count is 2 (host + joiner)",
		args != null and int(args[1]) == 2)

	print("[LIVE_B] 5. logout (Session API)")
	var stale_token := Session.session_token
	r = await Session.logout()
	_check("logout ok", r["ok"])
	_check("session cleared locally", not Session.is_logged_in and Session.session_token == "")

	print("[LIVE_B] 6. protected join: REVOKED token => rejected")
	args = await _wait_protected_join(_room_code, stale_token)
	_check("join_failed NOT_AUTHENTICATED (revoked token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	if failures == 0:
		print("LIVE_B PASSED")
		get_tree().quit(0)
	else:
		printerr("LIVE_B FAILED: %d assertion(s) failed" % failures)
		get_tree().quit(1)


func _wait_protected_join(code: String, token: String) -> Variant:
	var waiter := _Waiter.new()
	var c1 := func(reason: String = ""):
		waiter.done.emit([reason])
	var c2 := func(player_count: int, room_code: String):
		waiter.done.emit(["joined", player_count, room_code])
	Network.join_failed.connect(c1, CONNECT_ONE_SHOT)
	Network.room_joined.connect(c2, CONNECT_ONE_SHOT)
	Network.rpc_join_room.rpc_id(1, code, 1, "e2e-live-b-device", Network.username, token)
	var args: Variant = await _wait_signal(waiter.done, SIG_TIMEOUT_MS)
	Network.join_failed.disconnect(c1)
	Network.room_joined.disconnect(c2)
	return args
