#!/usr/bin/env bash
# Accounts test suite for Tandora.
#   1. unit store tests (godot -s, no network)
#   2. live integration: real dedicated server on a test port + WS client
#   3. invariants: no plaintext password in server log or on disk,
#      correct hash format, schema envelopes present.
# Exit 0 only if everything passes. Usage: bash tests/run_accounts_tests.sh

set -u
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SERVER_PORT=7791
CLIENT_STRAY_PORT=7793
STORE_PORT=7794
TEST_PASSWORD='correct-horse-battery-staple-42!'

TMP="$(mktemp -d /tmp/tandora-accounts-test.XXXXXX)"
SERVER_PID=""
FAILURES=0

say() { printf '\n=== %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'CHECK FAILED: %s\n' "$*"; }

cleanup() {
	if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill -INT "$SERVER_PID" 2>/dev/null
		for _ in $(seq 1 20); do
			kill -0 "$SERVER_PID" 2>/dev/null || break
			sleep 0.5
		done
		kill -KILL "$SERVER_PID" 2>/dev/null
	fi
	wait "$SERVER_PID" 2>/dev/null
	rm -rf "$TMP"
}
trap cleanup EXIT

say "Godot: $("$GODOT" --version 2>/dev/null || echo missing)"
if ! "$GODOT" --version >/dev/null 2>&1; then
	echo "FATAL: godot not found (set GODOT=/path/to/godot)"
	exit 1
fi

say "Importing project (idempotent)"
"$GODOT" --headless --import >/dev/null 2>&1 || true

# ---------------------------------------------------------------- unit tests
say "1/3 unit store tests"
"$GODOT" --headless -s tests/test_accounts_store.gd \
	-- --port=$STORE_PORT --accounts_dir="$TMP/store" > "$TMP/store.log" 2>&1
STORE_RC=$?
grep -E "STORE_TEST (PASSED|FAILED)" "$TMP/store.log" || tail -20 "$TMP/store.log"
if [ $STORE_RC -ne 0 ]; then
	fail "unit store tests (rc=$STORE_RC, see $TMP/store.log)"
fi

# ------------------------------------------------------------- integration
say "2/3 integration (live server on :$SERVER_PORT + WS client)"
SERVER_LOG="$TMP/server.log"
"$GODOT" --headless --port=$SERVER_PORT --accounts_dir="$TMP/server_data" \
	> "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for the WebSocket listener (exported binaries buffer stdout — judge
# by the socket, not the log).
LISTENED=0
for _ in $(seq 1 120); do
	if (exec 3<>"/dev/tcp/127.0.0.1/$SERVER_PORT") 2>/dev/null; then
		exec 3>&- 3<&- 2>/dev/null
		LISTENED=1
		break
	fi
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		break
	fi
	sleep 0.5
done
if [ "$LISTENED" -ne 1 ]; then
	fail "server did not start listening on :$SERVER_PORT"
	tail -30 "$SERVER_LOG"
fi

CLIENT_LOG="$TMP/client.log"
"$GODOT" --headless res://tests/test_accounts_network_client.tscn \
	-- --connect_port=$SERVER_PORT --port=$CLIENT_STRAY_PORT --accounts_dir="$TMP/client_data" \
	> "$CLIENT_LOG" 2>&1
CLIENT_RC=$?
grep -E "NETWORK_TEST (PASSED|FAILED)|FATAL|ok  -|FAIL" "$CLIENT_LOG"
if [ $CLIENT_RC -ne 0 ]; then
	fail "integration client (rc=$CLIENT_RC, see $CLIENT_LOG)"
fi

# Stop the server (SIGINT => clean shutdown so buffered logs are flushed).
if kill -0 "$SERVER_PID" 2>/dev/null; then
	kill -INT "$SERVER_PID"
	for _ in $(seq 1 20); do
		kill -0 "$SERVER_PID" 2>/dev/null || break
		sleep 0.5
	done
	kill -KILL "$SERVER_PID" 2>/dev/null
fi
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

# ---------------------------------------------------------------- invariants
say "3/3 storage & logging invariants"
USERS_JSON="$TMP/server_data/users.json"
SESSIONS_JSON="$TMP/server_data/sessions.json"

if [ ! -f "$USERS_JSON" ]; then
	fail "users.json not created at $USERS_JSON"
else
	if grep -qF "$TEST_PASSWORD" "$USERS_JSON"; then
		fail "plaintext test password found in users.json"
	fi
	if ! grep -qF 'pbkdf2_sha256$210000$' "$USERS_JSON"; then
		fail "users.json missing PBKDF2-SHA256 hash at expected cost"
	fi
	if ! grep -qF '"schema_version": 1' "$USERS_JSON"; then
		fail "users.json missing schema_version envelope"
	fi
fi
if [ -f "$SESSIONS_JSON" ]; then
	if ! grep -qF '"schema_version": 1' "$SESSIONS_JSON"; then
		fail "sessions.json missing schema_version envelope"
	fi
fi
if grep -qF "$TEST_PASSWORD" "$SERVER_LOG"; then
	fail "plaintext test password found in server log"
fi
if ! grep -qF "Ready to host at ws://0.0.0.0:$SERVER_PORT" "$SERVER_LOG"; then
	fail "server log missing startup line (log may not have flushed)"
fi

# ---------------------------------------------------------------- result
say "Result"
if [ "$FAILURES" -eq 0 ]; then
	echo "ALL ACCOUNTS TESTS PASSED"
	exit 0
else
	echo "ACCOUNTS TESTS FAILED: $FAILURES check(s)"
	exit 1
fi
