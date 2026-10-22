extends Node
## LIVE E2E client A (host): full account matrix + protected-room gate
## against the DEPLOYED dedicated server (wss://tandoraserver.nuclearquads.com).
##
## Companion to live_e2e_client_b.gd (the joiner). Orchestrated by
## tests/run_live_e2e.sh — NOT part of the default local suite.
##
## Live-server etiquette: exactly ONE wrong-password attempt per account
## (the 5-strike lockout would leave a real account locked on the public
## server). Test accounts are unique per run and sessions are revoked at
## the end; the room dissolves server-side when we disconnect (empty rooms
## auto-dissolve), so no state is left behind beyond the account rows
## (the protocol has no delete action — known limitation).
##
## Run (see run_live_e2e.sh):
##   godot --headless res://tests/live_e2e_client_a.tscn -- --port=<stray>
##
## Exits 0 on success, 1 on any failure.

const SERVER_URL := "wss://tandoraserver.nuclearquads.com"
const CONNECT_TIMEOUT_MS := 30000
const FLOW_TIMEOUT_MS := 240000
const WAIT_JOIN_TIMEOUT_MS := 90000
const SIG_TIMEOUT_MS := 15000
const TEST_PASSWORD := "correct-horse-battery-staple-42!"
const SESSION_FILE := "user://session.json"

var failures: int = 0
var _connected := false
var _flow_started := false
var _deadline_ms: int = 0
var _test_email: String = ""
var _test_email2: String = ""
var _request_seq: int = 0


class _Waiter:
	signal done(result)


func _ready() -> void:
	var ts := int(Time.get_unix_time_from_system())
	_test_email = "e2e-live-a-%d@tandora.test" % ts
	_test_email2 = "e2e-live-a2-%d@tandora.test" % ts
	if FileAccess.file_exists(SESSION_FILE):
		DirAccess.remove_absolute(SESSION_FILE)
	if Session.is_logged_in:
		Session._clear_session()
	_check("no pre-existing session", not Session.is_logged_in and Session.session_token == "")

	_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	print("[LIVE_A] connecting to ", SERVER_URL, " (email=", _test_email, ")")
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
	Network.username = "e2e-live-host"
	print("[LIVE_A] connected (peer id %d)" % Network.multiplayer.get_unique_id())
	_run_flow()


## Awaitable account RPC via the Network autoload (same path the game uses).
func rpc_call(action: String, email: String, secret: String) -> Dictionary:
	_request_seq += 1
	var id := _request_seq
	var waiter := _Waiter.new()
	var conn := func(rid: int, ok: bool, error: String, data: Dictionary):
		if rid == id:
			waiter.done.emit({"ok": ok, "error": error, "data": data})
	Network.account_response.connect(conn, CONNECT_ONE_SHOT)
	Network.rpc_account_request.rpc_id(1, id, action, email, secret)
	var args: Variant = await _await_one(waiter, SIG_TIMEOUT_MS + 60000)
	if args == null:
		return {"ok": false, "error": "TIMEOUT", "data": {}}
	return args


## Await one emission of `sig`; null on timeout.
func _await_one(waiter: _Waiter, timeout_ms: int) -> Variant:
	var timer := get_tree().create_timer(timeout_ms / 1000.0)
	timer.timeout.connect(func(): waiter.done.emit(null))
	var args: Variant = await waiter.done
	return args


func _wait_signal(sig: Signal, timeout_ms: int) -> Variant:
	var waiter := _Waiter.new()
	var conn := func(args: Array):
		waiter.done.emit(args)
	sig.connect(conn, CONNECT_ONE_SHOT)
	var args: Variant = await _await_one(waiter, timeout_ms)
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
	printerr("[LIVE_A] FATAL: ", msg)
	failures += 1
	get_tree().quit(1)


func _check_session_file() -> bool:
	if not FileAccess.file_exists(SESSION_FILE):
		printerr("  FAIL - session.json missing")
		return false
	var f: FileAccess = FileAccess.open(SESSION_FILE, FileAccess.READ)
	if f == null:
		printerr("  FAIL - session.json unreadable")
		return false
	var raw := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		printerr("  FAIL - session.json is not JSON")
		return false
	var ok: bool = (
		int(parsed.get("schema_version", 0)) == 1
		and parsed.get("token") == Session.session_token
		and parsed.get("email") == _test_email
		and not raw.contains(TEST_PASSWORD)
	)
	if not ok:
		printerr("  FAIL - session.json envelope/token/email/password invariant")
	return ok


func _run_flow() -> void:
	var r: Dictionary

	print("[LIVE_A] 1. create account (Session API — same path as the UI)")
	r = await Session.create_account(_test_email, TEST_PASSWORD)
	_check("create ok", r["ok"] and String(r["data"].get("user_id", "")).begins_with("usr_"))
	_check("create returns normalized email", r["data"].get("email") == _test_email)

	print("[LIVE_A] 2. duplicate email (uppercase) => EMAIL_TAKEN")
	r = await rpc_call("create", _test_email.to_upper(), "another-pass-1")
	_check("duplicate rejected EMAIL_TAKEN", not r["ok"] and r["error"] == "EMAIL_TAKEN")

	print("[LIVE_A] 3. invalid email")
	r = await rpc_call("create", "not-an-email", TEST_PASSWORD)
	_check("rejected INVALID_EMAIL", not r["ok"] and r["error"] == "INVALID_EMAIL")

	print("[LIVE_A] 4. weak password")
	r = await rpc_call("create", _test_email2, "short")
	_check("rejected WEAK_PASSWORD", not r["ok"] and r["error"] == "WEAK_PASSWORD")

	print("[LIVE_A] 5. login with wrong password (single attempt — live server)")
	r = await rpc_call("login", _test_email, "wrong-pass-000")
	_check("rejected INVALID_CREDENTIALS", not r["ok"] and r["error"] == "INVALID_CREDENTIALS")

	print("[LIVE_A] 6. login with valid credentials (Session API)")
	r = await Session.login(_test_email, TEST_PASSWORD)
	var token := String(Session.session_token)
	_check("login ok", r["ok"])
	_check("session token stored (64 hex)", token.length() == 64)
	_check("is_logged_in", Session.is_logged_in)
	_check("user email recorded", Session.user_email == _test_email)
	_check("user_id recorded", Session.user_id.begins_with("usr_"))

	print("[LIVE_A] 7. session.json on disk")
	_check("session.json valid (schema, token, no password)", _check_session_file())

	print("[LIVE_A] 8. validate session (Session API)")
	r = await Session.validate()
	_check("validate ok", r["ok"] and r["data"].get("email") == _test_email)

	print("[LIVE_A] 9. protected create: NO token => rejected")
	var args: Variant = await _wait_protected_create("")
	_check("create_failed NOT_AUTHENTICATED (empty token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	print("[LIVE_A] 10. protected join: BOGUS token => rejected")
	args = await _wait_protected_join("deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
	_check("join_failed NOT_AUTHENTICATED (bogus token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	print("[LIVE_A] 11. protected create: VALID token => room created")
	args = await _wait_protected_create(Session.session_token)
	var room_code := ""
	if args != null and String(args[0]) == "created":
		room_code = String(args[1])
	_check("room_created with valid session", room_code != "")
	if room_code == "":
		_finish()
		return
	print("LIVE_A ROOM_CODE ", room_code)

	print("[LIVE_A] 12. waiting for client B to join (room_updated count>=2)")
	var joined := false
	var waited_ms := 0
	while waited_ms < WAIT_JOIN_TIMEOUT_MS:
		var u: Variant = await _wait_room_updated(5000)
		waited_ms += 5000
		if u != null and int(u[0]) >= 2:
			joined = true
			print("  ok  - join observed on host side (count=%d)" % int(u[0]))
			break
	_check("client B joined room (host observed count>=2)", joined)

	print("[LIVE_A] 13. logout (Session API)")
	var stale_token := Session.session_token
	r = await Session.logout()
	_check("logout ok", r["ok"])
	_check("session cleared locally", not Session.is_logged_in and Session.session_token == "")

	print("[LIVE_A] 14. protected create: REVOKED token => rejected")
	args = await _wait_protected_create(stale_token)
	_check("create_failed NOT_AUTHENTICATED (revoked token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	# Hold the connection (and the room) briefly so client B can finish its
	# own logout + revoked-join checks before we disconnect.
	await get_tree().create_timer(25.0).timeout

	_finish()


## Await the host-side room_updated (2-arg signal); null on timeout.
func _wait_room_updated(timeout_ms: int) -> Variant:
	var waiter := _Waiter.new()
	var conn := func(player_count: int, level: int):
		waiter.done.emit([player_count, level])
	Network.room_updated.connect(conn, CONNECT_ONE_SHOT)
	var args: Variant = await _await_one(waiter, timeout_ms)
	if args == null:
		Network.room_updated.disconnect(conn)
	return args


func _wait_protected_create(token: String) -> Variant:
	var waiter := _Waiter.new()
	var c1 := func(reason: String):
		waiter.done.emit([reason])
	var c2 := func(code: String):
		waiter.done.emit(["created", code])
	Network.create_failed.connect(c1, CONNECT_ONE_SHOT)
	Network.room_created.connect(c2, CONNECT_ONE_SHOT)
	Network.rpc_create_room.rpc_id(1, 1, 1, "e2e-live-a-device", Network.username, token)
	var args: Variant = await _wait_signal(waiter.done, SIG_TIMEOUT_MS)
	Network.create_failed.disconnect(c1)
	Network.room_created.disconnect(c2)
	return args


func _wait_protected_join(token: String) -> Variant:
	var waiter := _Waiter.new()
	var c1 := func(reason: String = ""):
		waiter.done.emit([reason])
	Network.join_failed.connect(c1, CONNECT_ONE_SHOT)
	Network.rpc_join_room.rpc_id(1, "zzzz", 1, "e2e-live-a-device", Network.username, token)
	var args: Variant = await _wait_signal(waiter.done, SIG_TIMEOUT_MS)
	Network.join_failed.disconnect(c1)
	return args


func _finish() -> void:
	if failures == 0:
		print("LIVE_A PASSED")
		get_tree().quit(0)
	else:
		printerr("LIVE_A FAILED: %d assertion(s) failed" % failures)
		get_tree().quit(1)
