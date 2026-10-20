extends Node
## Integration test client: connects to a REAL running Tandora dedicated
## server over the WebSocket protocol and exercises the account endpoints
## end-to-end (create, login, validate, logout, rate limiting).
##
## Run by tests/run_accounts_tests.sh, which starts the server first:
##   godot --headless res://tests/test_accounts_network_client.tscn \
##       -- --connect_port=<server port> --port=<stray port>
## (--port is consumed by the Network autoload's own headless server, which
## we don't use here; it must not collide with the test server's port.)
##
## Exits 0 on success, 1 on any failure. The flow's password is a fixed
## fixture; the runner greps the server log to prove it was never logged.

const CONNECT_TIMEOUT_MS := 30000
const FLOW_TIMEOUT_MS := 120000  # login is ~0.6 s each (PBKDF2); allow slack
const TEST_PASSWORD := "correct-horse-battery-staple-42!"

var failures: int = 0
var _connected := false
var _flow_started := false
var _connect_deadline_ms: int = 0
var _flow_deadline_ms: int = 0
var _request_seq: int = 0
var _test_email: String = ""
var _test_email2: String = ""

class _Waiter:
	signal done(ok: bool, error: String, data: Dictionary)


func _ready() -> void:
	var port := 7791
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--connect_port="):
			port = arg.get_slice("=", 1).to_int()
	_test_email = "tandora-net-test-%d@tandora.test" % int(Time.get_unix_time_from_system())
	_test_email2 = "tandora-net-test2-%d@tandora.test" % int(Time.get_unix_time_from_system())
	_connect_deadline_ms = Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	print("[NETTEST] connecting to ws://127.0.0.1:%d (email=%s)" % [port, _test_email])
	var peer := WebSocketMultiplayerPeer.new()
	if peer.create_client("ws://127.0.0.1:%d" % port) != OK:
		_fail("create_client failed")
		return
	# The account RPCs live on the Network autoload — the same node path
	# (/root/Network) on client and server, which is what Godot's scene RPC
	# routing requires. Install the client peer on Network's multiplayer.
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
	print("[NETTEST] connected (peer id %d)" % Network.multiplayer.get_unique_id())
	_flow_started = true
	_run_flow()


# ---- RPC plumbing ----
# The request/response RPC functions live on the Network autoload (see
# scripts/Network.gd "ACCOUNT RPCs"). We send via Network and listen on
# Network.account_response; scene RPC routing matches on node path, so the
# sender must be the same-named node as the receiver (both /root/Network).

## Awaitable account RPC: returns {"ok": bool, "error": String, "data": Dictionary}.
func rpc_call(action: String, email: String, secret: String) -> Dictionary:
	_request_seq += 1
	var id := _request_seq
	var waiter := _Waiter.new()
	var conn := func(rid: int, ok: bool, error: String, data: Dictionary):
		if rid == id:
			waiter.done.emit(ok, error, data)
	Network.account_response.connect(conn, CONNECT_ONE_SHOT)
	Network.rpc_account_request.rpc_id(1, id, action, email, secret)
	var args: Array = await waiter.done
	return {"ok": args[0], "error": args[1], "data": args[2]}


# ---- the flow ----

func _run_flow() -> void:
	var r: Dictionary

	print("[NETTEST] 1. create account")
	r = await rpc_call("create", _test_email, TEST_PASSWORD)
	_check("create ok", r["ok"] and String(r["data"].get("user_id", "")).begins_with("usr_"))
	_check("create returns normalized email", r["data"].get("email") == _test_email)

	print("[NETTEST] 2. duplicate email (different case)")
	r = await rpc_call("create", _test_email.to_upper(), "another-pass-1")
	_check("duplicate rejected EMAIL_TAKEN", not r["ok"] and r["error"] == "EMAIL_TAKEN")

	print("[NETTEST] 3. invalid email")
	r = await rpc_call("create", "not-an-email", TEST_PASSWORD)
	_check("rejected INVALID_EMAIL", not r["ok"] and r["error"] == "INVALID_EMAIL")

	print("[NETTEST] 4. weak password")
	r = await rpc_call("create", _test_email2, "short")
	_check("rejected WEAK_PASSWORD", not r["ok"] and r["error"] == "WEAK_PASSWORD")

	print("[NETTEST] 5. login with wrong password")
	r = await rpc_call("login", _test_email, "wrong-pass-000")
	_check("rejected INVALID_CREDENTIALS", not r["ok"] and r["error"] == "INVALID_CREDENTIALS")

	print("[NETTEST] 6. login with valid credentials")
	r = await rpc_call("login", _test_email, TEST_PASSWORD)
	var token := String(r["data"].get("token", ""))
	_check("login ok", r["ok"])
	_check("token is 64 hex chars", token.length() == 64)
	_check("login returns email", r["data"].get("email") == _test_email)

	print("[NETTEST] 7. validate session")
	r = await rpc_call("validate", "", token)
	_check("validate ok", r["ok"] and r["data"].get("email") == _test_email)

	print("[NETTEST] 8. logout")
	r = await rpc_call("logout", "", token)
	_check("logout ok", r["ok"])

	print("[NETTEST] 9. validate after logout")
	r = await rpc_call("validate", "", token)
	_check("stale token rejected INVALID_SESSION", not r["ok"] and r["error"] == "INVALID_SESSION")

	print("[NETTEST] 10. re-login yields a fresh token")
	r = await rpc_call("login", _test_email, TEST_PASSWORD)
	var token2 := String(r["data"].get("token", ""))
	_check("re-login ok with new token", r["ok"] and token2 != "" and token2 != token)

	print("[NETTEST] 11. brute-force lockout (5 bad, then correct)")
	for i in range(5):
		r = await rpc_call("login", _test_email, "guess-%d-%d" % [i, i])
		_check("bad attempt %d rejected" % (i + 1), not r["ok"] and r["error"] == "INVALID_CREDENTIALS")
	r = await rpc_call("login", _test_email, TEST_PASSWORD)
	_check("correct attempt while locked => RATE_LIMITED", not r["ok"] and r["error"] == "RATE_LIMITED")

	if failures == 0:
		print("NETWORK_TEST PASSED")
		get_tree().quit(0)
	else:
		printerr("NETWORK_TEST FAILED: %d assertion(s) failed" % failures)
		get_tree().quit(1)


func _check(label: String, cond: bool) -> void:
	if cond:
		print("  ok  - ", label)
	else:
		failures += 1
		printerr("  FAIL - ", label)


func _fail(msg: String) -> void:
	printerr("[NETTEST] FATAL: ", msg)
	failures += 1
	get_tree().quit(1)
