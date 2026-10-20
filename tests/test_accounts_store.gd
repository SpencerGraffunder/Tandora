extends SceneTree
## Unit tests for AccountService + PasswordHasher + SecureRandom.
## Run: godot --headless -s tests/test_accounts_store.gd
## Exits 0 on success, 1 on any failure.

const TEST_EMAIL := "Alice@Example.com"
const TEST_EMAIL_KEY := "alice@example.com"
const TEST_PASSWORD := "hunter22-secret!"
const TEST_PASSWORD_WRONG := "wrong-password-99"
const WEAK_PASSWORD := "short"
const BAD_EMAIL := "not-an-email"

var failures: int = 0
var service  # untyped: AccountService instance (methods resolved at runtime)
var tmp_dir: String
var _request_seq: int = 0
var _captured: Dictionary = {}


func _init() -> void:
	# Unique per run: ticks_msec alone can collide on fast re-runs in some
	# environments (container clocks), and a reused dir makes the flow tests
	# fail against stale state. ticks_usec never collides between runs.
	tmp_dir = "/tmp/tandora-store-test-%d-%06d" % [Time.get_ticks_msec(), Time.get_ticks_usec() & 0xFFFFFF]
	var script: GDScript = load("res://scripts/AccountService.gd")
	service = script.new()
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	service.ensure_ready(tmp_dir)

	_test_crypto_known_answers()
	_test_create_and_login_flow()
	_test_rate_limiting()
	_test_file_invariants()
	_test_migration_v0()

	DirAccess.remove_absolute(tmp_dir)
	if failures == 0:
		print("STORE_TEST PASSED")
		quit(0)
	else:
		printerr("STORE_TEST FAILED: %d assertion(s) failed" % failures)
		quit(1)


func _check(label: String, cond: bool) -> void:
	if cond:
		print("  ok  - ", label)
	else:
		failures += 1
		printerr("  FAIL - ", label)


# ---- crypto known-answer tests (vectors computed independently in Python) ----

func _test_crypto_known_answers() -> void:
	print("== crypto known answers ==")
	# --- SHA-256 (RFC 6234 / FIPS 180-4) ---
	_check("sha256('abc')", PasswordHasher.sha256_raw("abc".to_utf8_buffer()).hex_encode() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	_check("sha256('')", PasswordHasher.sha256_raw(PackedByteArray()).hex_encode() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	# 2-block vector: exercises the hash-state carry between blocks.
	_check("sha256 2-block", PasswordHasher.sha256_raw("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_utf8_buffer()).hex_encode() == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
	# 1 MiB of 'a': ~15,626 blocks, large bit-length field, many MSB words.
	var one_mb := PackedByteArray()
	one_mb.resize(1000000)
	one_mb.fill(0x61)
	_check("sha256 1MiB", PasswordHasher.sha256_raw(one_mb).hex_encode() == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
	# --- HMAC-SHA256 (RFC 4231) ---
	var key1 := PackedByteArray()
	key1.resize(20)
	for i in range(20):
		key1[i] = 0x0B
	_check("hmac rfc4231 tc1", PasswordHasher.hmac_sha256(key1, "Hi There".to_utf8_buffer()).hex_encode() == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
	_check("hmac rfc4231 tc2", PasswordHasher.hmac_sha256("Jefe".to_utf8_buffer(), "what do ya want for nothing?".to_utf8_buffer()).hex_encode() == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
	_check("hmac password|SALT", PasswordHasher.hmac_sha256("password".to_utf8_buffer(), "SALT".to_utf8_buffer()).hex_encode() == "1b5494fcdeb4d4fa4083bd131341375803942e007487623eea4de9093d5cd269")
	# tc7: key longer than the 64-byte block size must be pre-hashed.
	var long_key := PackedByteArray()
	long_key.resize(131)
	for i in range(131):
		long_key[i] = 0xAA
	_check("hmac rfc4231 tc7 (key>64B pre-hashed)", PasswordHasher.hmac_sha256(long_key, "Test Using Larger Than Block-Size Key - Hash Key First".to_utf8_buffer()).hex_encode() == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
	# --- PBKDF2-HMAC-SHA256 (vs Python hashlib.pbkdf2_hmac) ---
	_check("pbkdf2 i1", PasswordHasher.pbkdf2_sha256("password".to_utf8_buffer(), "salt".to_utf8_buffer(), 1, 32).hex_encode() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
	_check("pbkdf2 i2", PasswordHasher.pbkdf2_sha256("password".to_utf8_buffer(), "salt".to_utf8_buffer(), 2, 32).hex_encode() == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
	_check("pbkdf2 i100", PasswordHasher.pbkdf2_sha256("password".to_utf8_buffer(), "salt".to_utf8_buffer(), 100, 32).hex_encode() == "07e6997180cf7f12904f04100d405d34888fdf62af6d506a0ecc23b196fe99d8")
	# Multibyte UTF-8 password/salt, 5000 iterations.
	_check("pbkdf2 multibyte i5000", PasswordHasher.pbkdf2_sha256("pässword".to_utf8_buffer(), "sàlt-bytes".to_utf8_buffer(), 5000, 32).hex_encode() == "65e29dc643810cfb5be5d098cdd7a86c689fb1de893f27afbb40058d4a245940")
	# Stored-string round trip against the independent base64 encoding.
	var stored := "pbkdf2_sha256$100$c2FsdA==$B+aZcYDPfxKQTwQQDUBdNIiP32KvbVBqDswjsZb+mdg="
	_check("pbkdf2 v100 cross-impl verify", PasswordHasher.verify("password", stored))
	_check("pbkdf2 v100 rejects wrong password", not PasswordHasher.verify("Password", stored))
	# --- base64 helpers (encode/decode, padding cases) ---
	_check("b64 encode 'salt'", PasswordHasher._b64_encode("salt".to_utf8_buffer()) == "c2FsdA==")
	_check("b64 encode 1 byte", PasswordHasher._b64_encode(PackedByteArray([0xFF])) == "/w==")
	_check("b64 encode 2 bytes", PasswordHasher._b64_encode(PackedByteArray([0xFF, 0xFF])) == "//8=")
	_check("b64 encode 32 bytes", PasswordHasher._b64_encode(PasswordHasher.pbkdf2_sha256("password".to_utf8_buffer(), "salt".to_utf8_buffer(), 100, 32)) == "B+aZcYDPfxKQTwQQDUBdNIiP32KvbVBqDswjsZb+mdg=")
	var a33 := PackedByteArray()
	a33.resize(33)
	a33.fill(0x61)
	_check("b64 decode round-trip 33 bytes", PasswordHasher._b64_decode(PasswordHasher._b64_encode(a33)) == a33)
	_check("b64 decode empty", PasswordHasher._b64_decode("").size() == 0)
	# Native (HashingContext) vs pure-GDScript reference must agree exactly.
	_check("native==ref empty", PasswordHasher.sha256_raw(PackedByteArray()) == PasswordHasher.sha256_reference(PackedByteArray()))
	_check("native==ref 'abc'", PasswordHasher.sha256_raw("abc".to_utf8_buffer()) == PasswordHasher.sha256_reference("abc".to_utf8_buffer()))
	var cross := PackedByteArray()
	cross.resize(137)  # spans two 64-byte blocks
	for i in range(137):
		cross[i] = (i * 7 + 3) % 256
	_check("native==ref 137B", PasswordHasher.sha256_raw(cross) == PasswordHasher.sha256_reference(cross))
	# Round-trip with the real (random-salt) hasher.
	var h := PasswordHasher.hash("some-passphrase-1")
	_check("hash format", h.begins_with("pbkdf2_sha256$210000$"))
	_check("hash round-trip ok", PasswordHasher.verify("some-passphrase-1", h))
	_check("hash round-trip rejects other", not PasswordHasher.verify("some-passphrase-2", h))
	_check("verify rejects garbage stored", not PasswordHasher.verify("any-password-1", "garbage"))
	# SecureRandom: right size, hex-encodable, two draws differ.
	var b1 := SecureRandom.new().random_bytes(32)
	var b2 := SecureRandom.new().random_bytes(32)
	_check("secure random size", b1.size() == 32 and b2.size() == 32)
	_check("secure random differs", b1 != b2)
	_check("secure random hex length", b1.hex_encode().length() == 64)


# ---- account + session flow (in-process, no network) ----

func _test_create_and_login_flow() -> void:
	print("== create/login flow ==")
	var r: Dictionary = service.create_account(TEST_EMAIL, TEST_PASSWORD)
	_check("create ok", r["ok"])
	_check("create returns user_id", String(r["data"].get("user_id", "")).begins_with("usr_"))
	_check("create returns normalized email", r["data"].get("email") == TEST_EMAIL_KEY)

	r = service.create_account("alice@EXAMPLE.com", "different-pass-1")
	_check("duplicate email (case-insensitive) rejected", not r["ok"] and r["error"] == "EMAIL_TAKEN")

	r = service.create_account(BAD_EMAIL, "valid-password-9")
	_check("invalid email rejected", not r["ok"] and r["error"] == "INVALID_EMAIL")

	r = service.create_account("bob@example.com", WEAK_PASSWORD)
	_check("weak password rejected", not r["ok"] and r["error"] == "WEAK_PASSWORD")

	r = service.login(TEST_EMAIL, TEST_PASSWORD_WRONG)
	_check("login wrong password rejected", not r["ok"] and r["error"] == "INVALID_CREDENTIALS")

	r = service.login("ghost@example.com", TEST_PASSWORD)
	_check("login unknown email rejected (no enumeration)", not r["ok"] and r["error"] == "INVALID_CREDENTIALS")

	r = service.login(TEST_EMAIL, TEST_PASSWORD)
	_check("login ok", r["ok"])
	var token: String = String(r["data"].get("token", ""))
	_check("token is 64 hex chars", token.length() == 64 and _is_hex(token))
	_check("login returns email+id", r["data"].get("email") == TEST_EMAIL_KEY and String(r["data"].get("user_id", "")) == String(service.users[0]["id"]))

	r = service.validate_session(token)
	_check("validate ok", r["ok"] and r["data"].get("email") == TEST_EMAIL_KEY)

	r = service.logout(token)
	_check("logout ok", r["ok"])

	r = service.validate_session(token)
	_check("validate after logout rejected", not r["ok"] and r["error"] == "INVALID_SESSION")

	r = service.validate_session("nope")
	_check("validate garbage token rejected", not r["ok"] and r["error"] == "INVALID_SESSION")


func _test_rate_limiting() -> void:
	print("== rate limiting ==")
	var sender := 7
	# 5 failures lock the sender out; the 6th attempt (even with the right
	# password) must be RATE_LIMITED, while a fresh sender is unaffected.
	for i in range(5):
		var r := _rpc(sender, "login", TEST_EMAIL, "bad-guess-%d-%d" % [i, i])
		_check("attempt %d rejected as INVALID_CREDENTIALS" % (i + 1), not r["ok"] and r["error"] == "INVALID_CREDENTIALS")
	var now := int(Time.get_unix_time_from_system())
	_check("sender locked out after 5 failures", service._is_locked_out(sender, now))
	var r6 := _rpc(sender, "login", TEST_EMAIL, TEST_PASSWORD)
	_check("6th attempt (correct password) RATE_LIMITED", not r6["ok"] and r6["error"] == "RATE_LIMITED")
	var r2 := _rpc(2, "login", TEST_EMAIL, TEST_PASSWORD)
	_check("fresh sender unaffected", r2["ok"])
	# Lockout is lifted after the window; simulate by rewinding the lock.
	service._login_failures[sender]["locked_until"] = now - 1
	var r7 := _rpc(sender, "login", TEST_EMAIL, TEST_PASSWORD)
	_check("login works after lockout expires", r7["ok"])


## Drives one request through handle_request and captures the response.
func _rpc(sender: int, action: String, email: String, secret: String) -> Dictionary:
	_captured = {}
	_request_seq += 1
	var id := _request_seq
	var conn := func(_s: int, _rid: int, ok: bool, error: String, data: Dictionary):
		_captured = {"ok": ok, "error": error, "data": data}
	service.response_ready.connect(conn, CONNECT_ONE_SHOT)
	service.handle_request(sender, id, action, email, secret)
	return _captured


func _test_file_invariants() -> void:
	print("== file invariants ==")
	var users_text := _file_text(service.users_path)
	_check("no plaintext password in users.json", not users_text.contains(TEST_PASSWORD))
	_check("no plaintext password in sessions.json", not _file_text(service.sessions_path).contains(TEST_PASSWORD))
	_check("users.json has hash", users_text.contains("pbkdf2_sha256$210000$"))
	var users_parsed: Dictionary = JSON.parse_string(users_text)
	_check("users.json envelope v1", users_parsed.get("schema_version") == 1)
	var entry: Dictionary = users_parsed["users"][0]
	_check("user entry fields", entry.has("id") and entry.has("email") and entry.has("email_key")
		and entry.has("password_hash") and entry.has("created_at") and entry.has("updated_at"))
	_check("timestamps are ISO-UTC", String(entry["created_at"]).length() == 20 and String(entry["created_at"]).contains("T"))
	var sessions_parsed: Dictionary = JSON.parse_string(_file_text(service.sessions_path))
	_check("sessions.json envelope v1", sessions_parsed.get("schema_version") == 1)


# ---- migration: bare-array v0 users.json -> v1 envelope ----

func _test_migration_v0() -> void:
	print("== migration v0 -> v1 ==")
	# Write a legacy file: bare array, one entry missing id/timestamps.
	var legacy := JSON.stringify([
		{
			"email": "Legacy@Example.com",
			"password_hash": "pbkdf2_sha256$100$c2FsdA==$B+aZcYDPfxKQTwQQDUBdNIiP32KvbVBqDswjsZb+mdg=",
			"display_name": "Legacy",
		},
	], "  ")
	var f := FileAccess.open(service.users_path, FileAccess.WRITE)
	f.store_string(legacy)
	f.close()
	var fresh = service.get_script().new()
	fresh.ensure_ready(tmp_dir)
	_check("v0 file migrated to envelope", JSON.parse_string(_file_text(fresh.users_path)).get("schema_version") == 1)
	_check("legacy user preserved", fresh.users.size() == 1 and fresh.users[0]["email_key"] == "legacy@example.com")
	_check("legacy entry gained id", String(fresh.users[0]["id"]).begins_with("usr_"))
	_check("legacy password still verifies", PasswordHasher.verify("password", fresh.users[0]["password_hash"]))


func _file_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _is_hex(s: String) -> bool:
	for i in range(s.length()):
		var c := s[i]
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
			return false
	return true
