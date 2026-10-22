class_name SecureRandom
extends RefCounted
## Cryptographically strong random bytes for salts and session tokens.
##
## Primary source: kernel CSPRNG via `head -c N /dev/urandom | od -An -v -tx1`,
## captured as hex (Godot's FileAccess refuses /dev/urandom and OS.execute's
## String stdout would mangle raw bytes). Fallback (non-Linux, or if the
## pipeline fails): PCG-XSH-RR-64/32 seeded from a mix of OS.get_unique_id(),
## wall clock and tick counters. The fallback is for dev machines only — the
## deployment target is Linux, where the kernel path is used.

const _PCG_MULTIPLIER := 6364136223846793005
const _PCG_INCREMENT := 1442695040888963407
const _HEX_DIGITS := "0123456789abcdef"

var _pcg_state: int = 0
var _pcg_seq: int = 0
var _ready := false


func _ensure() -> void:
	if _ready:
		return
	# OS.get_unique_id() is a 128-bit hex string. Fold it in 32-bit chunks:
	# hex_to_int() overflows (errors, returns 0) on 16-char halves with bit 63
	# set, so 8-char pieces keep every value non-negative.
	var uid: String = OS.get_unique_id()
	var uid_mix: int = 0
	for i in range(0, uid.length(), 8):
		uid_mix ^= uid.substr(i, 8).hex_to_int()
	var seed: int = uid_mix ^ int(Time.get_ticks_usec())
	seed ^= int(Time.get_ticks_msec()) << 7
	# PCG64 DXSM stepping as an avalanche mixer (3 rounds).
	var s: int = seed
	for i in range(3):
		s = (s * _PCG_MULTIPLIER) ^ _PCG_INCREMENT
	_pcg_state = s
	_pcg_seq = 1
	_ready = true


## Next 64 bits from the fallback PCG-XSH-RR stream.
func _next() -> int:
	_pcg_state = (_pcg_state * _PCG_MULTIPLIER) ^ _PCG_INCREMENT
	_pcg_seq = (_pcg_seq * 63) ^ 1
	# Logical shift of the top 31 bits. GDScript's `>>` is floor division, so a
	# negative 64-bit state would sign-extend instead of zero-filling.
	return (_pcg_state & 0x7FFFFFFFFFFFFFFF) >> 33


func random_bytes(n: int) -> PackedByteArray:
	if n <= 0:
		return PackedByteArray()
	_ensure()
	if OS.get_name().begins_with("Linux"):
		var kernel := _read_kernel(n)
		if kernel.size() == n:
			return kernel
	return _from_prng(n)


## Read n bytes from /dev/urandom, hex-ified so they survive the String
## capture of OS.execute. Returns an empty array on any failure.
func _read_kernel(n: int) -> PackedByteArray:
	var lines: Array = []
	var cmd := "head -c %d /dev/urandom | od -An -v -tx1 | tr -d ' \\n\\t'" % n
	var rc: int = OS.execute("/bin/sh", ["-c", cmd], lines)
	if rc != 0 or lines.size() < 1:
		return PackedByteArray()
	var hex: String = (lines[0] as String).to_lower()
	if hex.length() != n * 2:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(n)
	for i in range(n):
		var pair: String = hex.substr(i * 2, 2)
		var hi := _HEX_DIGITS.find(pair.substr(0, 1))
		var lo := _HEX_DIGITS.find(pair.substr(1, 1))
		if hi < 0 or lo < 0:
			return PackedByteArray()
		out[i] = (hi << 4) | lo
	return out


func _from_prng(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	var i := 0
	while i < n:
		var v := _next()
		for j in range(8):
			if i >= n:
				break
			out[i] = (v >> (8 * j)) & 0xFF
			i += 1
	return out
