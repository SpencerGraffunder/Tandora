extends Node
## Integration test for the ACCOUNT UI half of the accounts feature: the
## Session autoload (create/login/validate/logout + user://session.json
## persistence) and the protected game actions (room create/join require a
## valid session token), exercised against a REAL dedicated server.
##
## Run by tests/run_accounts_tests.sh, which starts the server first:
##   godot --headless res://tests/test_account_session_client.tscn \
##       -- --connect_port=<server port> --port=<stray port>
##
## Exits 0 on success, 1 on any failure.

const CONNECT_TIMEOUT_MS := 30000
const FLOW_TIMEOUT_MS := 120000  # several PBKDF2 logins; allow slack
const SIG_TIMEOUT_MS := 10000
const TEST_PASSWORD := "correct-horse-battery-staple-42!"
const SESSION_FILE := "user://session.json"

var failures: int = 0
var _connected := false
var _flow_started := false
var _connect_deadline_ms: int = 0
var _flow_deadline_ms: int = 0
var _test_email: String = ""


class _Waiter:
	signal done(result)


func _ready() -> void:
	var port := 7791
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--connect_port="):
			port = arg.get_slice("=", 1).to_int()
	_test_email = "tandora-ui-test-%d@tandora.test" % int(Time.get_unix_time_from_system())
	# Start from a clean slate: a leftover session file (or a session
	# restored from one) must not leak into these assertions.
	if FileAccess.file_exists(SESSION_FILE):
		DirAccess.remove_absolute(SESSION_FILE)
	if Session.is_logged_in:
		Session._clear_session()
	_check("no pre-existing session", not Session.is_logged_in and Session.session_token == "")

	_connect_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	print("[UINET] connecting to ws://127.0.0.1:%d (email=%s)" % [port, _test_email])
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client("ws://127.0.0.1:%d" % port) != OK:
		_fail("create_client failed")
		return
	Network.multiplayer.multiplayer_peer = peer
	Network.multiplayer.connected_to_server.connect(_on_connected)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _connected and now > _connect_deadline_ms:
		_fail("timed out waiting for connection")
	elif _flow_started and now > _flow_deadline_ms:
		_fail("timed out in flow")


func _on_connected() -> void:
	_connected = true
	_flow_deadline_ms = Time.get_ticks_msec() + FLOW_TIMEOUT_MS
	print("[UINET] connected (peer id %d)" % Network.multiplayer.get_unique_id())
	_flow_started = true
	Network.username = "ui-tester"
	_run_flow()


## Await one emission of `sig`; returns the signal's argument array, or
## null on timeout. (CONNECT_ONE_SHOT consumes the emission.)
func _wait_signal(sig: Signal) -> Variant:
	var waiter := _Waiter.new()
	var conn := func(args: Array):
		waiter.done.emit(args)
	sig.connect(conn, CONNECT_ONE_SHOT)
	var timer := get_tree().create_timer(SIG_TIMEOUT_MS)
	timer.timeout.connect(func(): waiter.done.emit(null))
	var args: Variant = await waiter.done
	if args == null:
		sig.disconnect(conn)
	return args


# ---- the flow ----

func _run_flow() -> void:
	var r: Dictionary

	print("[UINET] 1. Session.create_account")
	r = await Session.create_account(_test_email, TEST_PASSWORD)
	_check("create ok", r["ok"])

	print("[UINET] 2. Session.login")
	r = await Session.login(_test_email, TEST_PASSWORD)
	_check("login ok", r["ok"])
	_check("session token stored (64 hex)", Session.session_token.length() == 64)
	_check("is_logged_in", Session.is_logged_in)
	_check("user email recorded", Session.user_email == _test_email)
	_check("user_id recorded", Session.user_id.begins_with("usr_"))

	print("[UINET] 3. session.json on disk")
	var on_disk_ok := _check_session_file()
	_check("session.json valid (schema, token, no password)", on_disk_ok)

	print("[UINET] 4. Session.validate")
	r = await Session.validate()
	_check("validate ok", r["ok"] and r["data"].get("email") == _test_email)

	print("[UINET] 5. protected create: NO token => rejected")
	var args: Variant = await _wait_protected_create("")
	_check("create_failed NOT_AUTHENTICATED (empty token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	print("[UINET] 6. protected join: BOGUS token => rejected")
	args = await _wait_protected_join("deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
	_check("join_failed NOT_AUTHENTICATED (bogus token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	print("[UINET] 7. protected create: VALID token => room created")
	args = await _wait_protected_create(Session.session_token)
	_check("room_created with valid session", args != null and String(args[0]) == "created")

	print("[UINET] 8. Session.logout")
	var stale_token := Session.session_token
	r = await Session.logout()
	_check("logout ok", r["ok"])
	_check("session cleared locally", not Session.is_logged_in and Session.session_token == "")
	_check("session.json removed", not FileAccess.file_exists(SESSION_FILE))

	print("[UINET] 9. protected create: REVOKED token => rejected")
	args = await _wait_protected_create(stale_token)
	_check("create_failed NOT_AUTHENTICATED (revoked token)",
		args != null and String(args[0]) == "NOT_AUTHENTICATED")

	if failures == 0:
		print("SESSION_UI_TEST PASSED")
		get_tree().quit(0)
	else:
		printerr("SESSION_UI_TEST FAILED: %d assertion(s) failed" % failures)
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


## Fires the real Lobby-side RPC (same signature as scripts/Lobby.gd) and
## waits for either the server's create rejection or the room creation.
func _wait_protected_create(token: String) -> Variant:
	var waiter := _Waiter.new()
	var c1 := func(reason: String):
		waiter.done.emit([reason])
	var c2 := func(code: String):
		waiter.done.emit(["created", code])
	Network.create_failed.connect(c1, CONNECT_ONE_SHOT)
	Network.room_created.connect(c2, CONNECT_ONE_SHOT)
	Network.rpc_create_room.rpc_id(1, 1, 1, "ui-test-device", Network.username, token)
	var args: Variant = await _wait_signal(waiter.done)
	Network.create_failed.disconnect(c1)
	Network.room_created.disconnect(c2)
	return args


func _wait_protected_join(token: String) -> Variant:
	var waiter := _Waiter.new()
	var c1 := func(reason: String):
		waiter.done.emit([reason])
	Network.join_failed.connect(c1, CONNECT_ONE_SHOT)
	Network.rpc_join_room.rpc_id(1, "zzzz", 1, "ui-test-device", Network.username, token)
	var args: Variant = await _wait_signal(waiter.done)
	Network.join_failed.disconnect(c1)
	return args


func _check(label: String, cond: bool) -> void:
	if cond:
		print("  ok  - ", label)
	else:
		failures += 1
		printerr("  FAIL - ", label)


func _fail(msg: String) -> void:
	printerr("[UINET] FATAL: ", msg)
	failures += 1
	get_tree().quit(1)
