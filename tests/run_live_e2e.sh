#!/usr/bin/env bash
# LIVE E2E against the DEPLOYED Tandora dedicated server
# (wss://tandoraserver.nuclearquads.com).
#
# Runs tests/live_e2e_client_a.tscn (host: full account matrix, session
# persistence, protected create gate, room creation, waits for a joiner)
# and tests/live_e2e_client_b.tscn (joiner: protected join gate with empty
# and valid tokens). Client B starts as soon as A publishes its room code.
#
# NOT part of the default local suite — needs internet access to the
# deployed server. Leaves throwaway @tandora.test accounts on the public
# server (the protocol has no delete action); all test sessions are
# revoked at the end of the run.
#
# Usage: bash tests/run_live_e2e.sh   (set GODOT=/path/to/godot if needed)

set -u
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d /tmp/tandora-live-e2e.XXXXXX)"
FAILURES=0

say() { printf '\n=== %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'CHECK FAILED: %s\n' "$*"; }

cleanup() {
	rm -rf "$TMP"
}
trap cleanup EXIT

say "Godot: $("$GODOT" --version 2>/dev/null || echo missing)"
if ! "$GODOT" --version >/dev/null 2>&1; then
	echo "FATAL: godot not found (set GODOT=/path/to/godot)"
	exit 1
fi

A_LOG="$TMP/live_a.log"
B_LOG="$TMP/live_b.log"
B_PID=""

say "Starting client A (host) against the deployed server"
"$GODOT" --headless res://tests/live_e2e_client_a.tscn \
	-- --port=7795 > "$A_LOG" 2>&1 &
A_PID=$!

# A waits up to 90 s for a joiner, so hand it the room code quickly.
ROOM_CODE=""
for _ in $(seq 1 120); do
	if grep -q "^LIVE_A ROOM_CODE " "$A_LOG" 2>/dev/null; then
		ROOM_CODE="$(grep -m1 "^LIVE_A ROOM_CODE " "$A_LOG" | awk '{print $3}')"
		break
	fi
	if ! kill -0 "$A_PID" 2>/dev/null; then
		break
	fi
	sleep 1
done

if [ -n "$ROOM_CODE" ]; then
	say "A created room $ROOM_CODE — starting client B (joiner)"
	"$GODOT" --headless res://tests/live_e2e_client_b.tscn \
		-- --port=7796 --room_code="$ROOM_CODE" > "$B_LOG" 2>&1 &
	B_PID=$!
else
	say "A produced no room code — skipping client B"
fi

wait "$A_PID"
A_RC=$?
B_RC=0
if [ -n "$B_PID" ]; then
	wait "$B_PID"
	B_RC=$?
fi

echo "---- client A log ----"
cat "$A_LOG"
if [ -n "$B_PID" ]; then
	echo "---- client B log ----"
	cat "$B_LOG"
fi

if [ $A_RC -ne 0 ] || ! grep -q "LIVE_A PASSED" "$A_LOG"; then
	fail "client A (rc=$A_RC, see log above)"
fi
if [ -n "$B_PID" ]; then
	if [ $B_RC -ne 0 ] || ! grep -q "LIVE_B PASSED" "$B_LOG"; then
		fail "client B (rc=$B_RC, see log above)"
	fi
else
	fail "no room code from client A — join flow was not exercised"
fi

say "Result"
if [ "$FAILURES" -eq 0 ]; then
	echo "ALL LIVE E2E TESTS PASSED"
	exit 0
else
	echo "LIVE E2E TESTS FAILED: $FAILURES check(s)"
	exit 1
fi
