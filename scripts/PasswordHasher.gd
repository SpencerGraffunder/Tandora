class_name PasswordHasher
extends RefCounted
## Password hashing: PBKDF2-HMAC-SHA256 with a per-user 16-byte salt.
##
## Stored format (self-describing, like Django/Passlib):
##   pbkdf2_sha256$<iterations>$<salt_b64>$<digest_b64>
##
## The iteration count is stored per hash so it can be raised later without
## re-hashing. Godot 4.7 has no PBKDF2 primitive, so this builds it from the
## engine's native SHA-256 (HashingContext, C++/SIMD). A pure-GDScript SHA-256
## reference implementation (sha256_reference) is kept and cross-checked in
## tests so any divergence between the two is caught.
##
## SECURITY NOTE — plaintext passwords are never stored, and nothing on this
## path is ever printed (only the lowercased email is logged elsewhere).

const SALT_BYTES := 16
const DIGEST_BYTES := 32
const ALGO := "pbkdf2_sha256"
const MIN_PASSWORD_LEN := 8
const DEFAULT_ITERATIONS := 210000  # ~1-2 s per KDF on the native path; stored per hash


# ---- public API ----

## True when the password meets the bar (length + at least two of
## lower/upper/digit).
static func is_valid_password(pw: String) -> bool:
	if pw.length() < MIN_PASSWORD_LEN:
		return false
	var classes := 0
	var has_lower := false
	var has_upper := false
	var has_digit := false
	for c in pw:
		if c >= "a" and c <= "z":
			has_lower = true
		elif c >= "A" and c <= "Z":
			has_upper = true
		elif c >= "0" and c <= "9":
			has_digit = true
	if has_lower:
		classes += 1
	if has_upper:
		classes += 1
	if has_digit:
		classes += 1
	return classes >= 2


## Hash a plaintext password with a fresh random salt. Result is a
## self-describing stored string (see class doc).
static func hash(password: String) -> String:
	var salt := SecureRandom.new().random_bytes(SALT_BYTES)
	var digest := pbkdf2_sha256(password.to_utf8_buffer(), salt, DEFAULT_ITERATIONS, DIGEST_BYTES)
	return "%s$%d$%s$%s" % [ALGO, DEFAULT_ITERATIONS, _b64_encode(salt), _b64_encode(digest)]


## Constant-time-ish compare of a candidate password against a stored string.
## Unknown/legacy formats verify against a dummy hash of the same shape so
## response timing does not reveal which emails are registered (the caller
## passes the dummy hash in for unknown users).
static func verify(password: String, stored: String) -> bool:
	var spec = parse_stored(stored)
	if spec == null:
		return false
	var salt := _b64_decode(spec.get_salt_b64())
	if salt.is_empty():
		return false
	var want := _b64_decode(spec.get_digest_b64())
	if want.size() != DIGEST_BYTES:
		return false
	var got := pbkdf2_sha256(password.to_utf8_buffer(), salt, spec.get_iterations(), DIGEST_BYTES)
	return got == want


## Parse "pbkdf2_sha256$iters$salt_b64$digest_b64". Returns null on malformed.
static func parse_stored(stored: String):
	var parts := stored.split("$", false, -1)
	if parts.size() != 4 or parts[0] != ALGO:
		return null
	var iters := int(parts[1])
	if iters <= 0 or iters > 10_000_000:
		return null
	return _Spec.new(parts[1], parts[2], parts[3])


# ---- PBKDF2-HMAC-SHA256 (RFC 2898), one block, built on the native SHA-256 ----

static func pbkdf2_sha256(password: PackedByteArray, salt: PackedByteArray, iterations: int, out_len: int) -> PackedByteArray:
	if iterations <= 0:
		iterations = 1
	var ctx := HashingContext.new()
	var k := password
	if k.size() > 64:
		k = sha256_raw(k)
	var pads := _hmac_pads(k)
	var ipad: PackedByteArray = pads[0]
	var opad: PackedByteArray = pads[1]
	var dt := PackedByteArray()
	var block_index := 1
	while dt.size() < out_len:
		# Block = salt || block_index (big-endian uint32).
		var block := PackedByteArray()
		block.append_array(salt)
		block.append((block_index >> 24) & 0xFF)
		block.append((block_index >> 16) & 0xFF)
		block.append((block_index >> 8) & 0xFF)
		block.append(block_index & 0xFF)
		var u := _hmac_stream(ctx, ipad, opad, block)
		var acc := PackedByteArray()
		acc.resize(DIGEST_BYTES)
		for i in range(DIGEST_BYTES):
			acc[i] = u[i]
		for _j in range(1, iterations):
			u = _hmac_stream(ctx, ipad, opad, u)
			for i in range(DIGEST_BYTES):
				acc[i] ^= u[i]
		dt.append_array(acc)
		block_index += 1
	if dt.size() > out_len:
		dt.resize(out_len)
	return dt


# ---- HMAC-SHA256 (RFC 2104), built on the native SHA-256 ----

static func hmac_sha256(key: PackedByteArray, msg: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	var k := key
	if k.size() > 64:
		k = sha256_raw(k)
	var pads := _hmac_pads(k)
	return _hmac_stream(ctx, pads[0], pads[1], msg)


static func _hmac_pads(k: PackedByteArray) -> Array:
	var ipad := PackedByteArray()
	ipad.resize(64)
	var opad := PackedByteArray()
	opad.resize(64)
	for i in range(64):
		var kb: int = k[i] if i < k.size() else 0
		ipad[i] = kb ^ 0x36
		opad[i] = kb ^ 0x5C
	return [ipad, opad]


static func _hmac_stream(ctx: HashingContext, ipad: PackedByteArray, opad: PackedByteArray, msg: PackedByteArray) -> PackedByteArray:
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(ipad)
	ctx.update(msg)
	var inner := ctx.finish()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(opad)
	ctx.update(inner)
	return ctx.finish()


# ---- SHA-256 ----

## Fast path: the engine's native C++ SHA-256.
static func sha256_raw(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if not data.is_empty():  # update() errors on a zero-length buffer
		ctx.update(data)
	return ctx.finish()


## Pure-GDScript reference implementation (kept for cross-checks in tests and
## as an independent second opinion on the native primitive). FIPS 180-4.
static func sha256_reference(data: PackedByteArray) -> PackedByteArray:
	# Pad: 0x80, zeros, then 64-bit big-endian bit length.
	var msg := PackedByteArray()
	msg.append_array(data)
	var bit_len: int = data.size() * 8
	msg.append(0x80)
	while msg.size() % 64 != 56:
		msg.append(0)
	for i in range(7, -1, -1):
		msg.append((bit_len >> (8 * i)) & 0xFF)
	var h := [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
	var K: Array = _sha256_k()
	var w := PackedInt32Array()
	w.resize(64)
	for off in range(0, msg.size(), 64):
		for i in range(16):
			var i4 := off + i * 4
			w[i] = (msg[i4] << 24) | (msg[i4 + 1] << 16) | (msg[i4 + 2] << 8) | msg[i4 + 3]
		for i in range(16, 64):
			# Mask before `>>`: GDScript's `>>` is floor division, so a negative
			# (sign-extended) word would keep the high 32 bits set in the result.
			var wi15: int = w[i - 15] & 0xFFFFFFFF
			var wi2: int = w[i - 2] & 0xFFFFFFFF
			var s0: int = _ror(wi15, 7) ^ _ror(wi15, 18) ^ (wi15 >> 3)
			var s1: int = _ror(wi2, 17) ^ _ror(wi2, 19) ^ (wi2 >> 10)
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF
		var a: int = h[0]
		var b: int = h[1]
		var c: int = h[2]
		var d: int = h[3]
		var e: int = h[4]
		var f: int = h[5]
		var g: int = h[6]
		var hh: int = h[7]
		for i in range(64):
			var s1: int = _ror(e, 6) ^ _ror(e, 11) ^ _ror(e, 25)
			var ch: int = (e & f) ^ ((~e) & g)
			var t1: int = (hh + s1 + ch + K[i] + w[i]) & 0xFFFFFFFF
			var s0: int = _ror(a, 2) ^ _ror(a, 13) ^ _ror(a, 22)
			var maj: int = (a & b) ^ (a & c) ^ (b & c)
			var t2: int = (s0 + maj) & 0xFFFFFFFF
			hh = g
			g = f
			f = e
			e = (d + t1) & 0xFFFFFFFF
			d = c
			c = b
			b = a
			a = (t1 + t2) & 0xFFFFFFFF
		h[0] = (h[0] + a) & 0xFFFFFFFF
		h[1] = (h[1] + b) & 0xFFFFFFFF
		h[2] = (h[2] + c) & 0xFFFFFFFF
		h[3] = (h[3] + d) & 0xFFFFFFFF
		h[4] = (h[4] + e) & 0xFFFFFFFF
		h[5] = (h[5] + f) & 0xFFFFFFFF
		h[6] = (h[6] + g) & 0xFFFFFFFF
		h[7] = (h[7] + hh) & 0xFFFFFFFF
	var out := PackedByteArray()
	for i in range(8):
		out.append((h[i] >> 24) & 0xFF)
		out.append((h[i] >> 16) & 0xFF)
		out.append((h[i] >> 8) & 0xFF)
		out.append(h[i] & 0xFF)
	return out


static func _sha256_k() -> Array:
	# FIPS 180-4 first 32 bits of the fractional parts of the cube roots of
	# the first 64 primes.
	return [
		0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
		0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
		0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
		0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
		0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
		0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
		0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
		0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
	]


static func _ror(v: int, n: int) -> int:
	# Zero-extend first: GDScript's `>>` is floor division, so shifting a
	# negative (sign-extended) int leaves the high 32 bits set, which would
	# poison the OR below. With u < 2^32, `u << (32-n)` never overflows int64.
	var u: int = v & 0xFFFFFFFF
	return ((u >> n) | (u << (32 - n))) & 0xFFFFFFFF


# ---- base64 / hex helpers (Godot 4.7 PackedByteArray has no base64 API) ----

const _BASE := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

static func _b64_encode(data: PackedByteArray) -> String:
	var out := PackedStringArray()
	var i := 0
	while i + 3 <= data.size():
		var n: int = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]
		out.append(_BASE[(n >> 18) & 0x3F])
		out.append(_BASE[(n >> 12) & 0x3F])
		out.append(_BASE[(n >> 6) & 0x3F])
		out.append(_BASE[n & 0x3F])
		i += 3
	var rem: int = data.size() - i
	if rem == 1:
		var n: int = data[i] << 16
		out.append(_BASE[(n >> 18) & 0x3F])
		out.append(_BASE[(n >> 12) & 0x3F])
		out.append("==")
	elif rem == 2:
		var n: int = (data[i] << 16) | (data[i + 1] << 8)
		out.append(_BASE[(n >> 18) & 0x3F])
		out.append(_BASE[(n >> 12) & 0x3F])
		out.append(_BASE[(n >> 6) & 0x3F])
		out.append("=")
	return "".join(out)


static func _b64_decode(text: String) -> PackedByteArray:
	var vals := PackedInt32Array()
	for c in text:
		var idx := _BASE.find(c)
		if idx >= 0:
			vals.append(idx)
	var out := PackedByteArray()
	var i := 0
	var nvals: int = vals.size()
	while i + 4 <= nvals:
		var n: int = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6) | vals[i + 3]
		out.append((n >> 16) & 0xFF)
		out.append((n >> 8) & 0xFF)
		out.append(n & 0xFF)
		i += 4
	var rem: int = nvals - i
	if rem == 2:
		var n: int = (vals[i] << 18) | (vals[i + 1] << 12)
		out.append((n >> 16) & 0xFF)
	elif rem == 3:
		var n: int = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6)
		out.append((n >> 16) & 0xFF)
		out.append((n >> 8) & 0xFF)
	return out


class _Spec:
	var _it: int = 0
	var _salt: String = ""
	var _digest: String = ""

	func _init(iterations: String, salt: String, digest: String) -> void:
		_it = iterations.to_int()
		_salt = salt
		_digest = digest

	func get_iterations() -> int:
		return _it

	func get_salt_b64() -> String:
		return _salt

	func get_digest_b64() -> String:
		return _digest
