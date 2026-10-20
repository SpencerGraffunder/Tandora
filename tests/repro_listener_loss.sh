#!/usr/bin/env bash
# Repro attempt: does the dedicated server lose its WS listener after
# clients disconnect (cleanly or abruptly)?
set -u
GODOT="$HOME/.local/bin/godot"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT=7795
TMP="$(mktemp -d /tmp/tandora-repro.XXXXXX)"
SRV="$TMP/server.log"
"$GODOT" --headless --port="$PORT" --accounts_dir="$TMP/data" > "$SRV" 2>&1 &
SPID=$!
cleanup() { kill -9 "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

for i in $(seq 1 120); do
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then exec 3>&- 3<&-; break; fi
  kill -0 "$SPID" 2>/dev/null || break
  sleep 0.5
done

probe() {
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then exec 3>&- 3<&-; r="TCP-OPEN"; else r="TCP-CLOSED"; fi
  if kill -0 "$SPID" 2>/dev/null; then p="process-alive"; else p="process-dead"; fi
  echo "PROBE $1: $r, $p"
}

probe "baseline"

echo "== scenario 1: clean client run (protocol test, normal quit) =="
"$GODOT" --headless res://tests/test_accounts_network_client.tscn -- --connect_port=$PORT --port=7796 > "$TMP/s1.log" 2>&1
echo "s1 rc=$?"
probe "after-clean-run-1"

echo "== scenario 2: SIGKILL client mid-flow =="
"$GODOT" --headless res://tests/test_account_session_client.tscn -- --connect_port=$PORT --port=7797 > "$TMP/s2.log" 2>&1 &
CPID=$!
sleep 8
kill -9 "$CPID" 2>/dev/null
wait "$CPID" 2>/dev/null
sleep 2
probe "after-sigkill"

echo "== scenario 3: clean client run again =="
"$GODOT" --headless res://tests/test_accounts_network_client.tscn -- --connect_port=$PORT --port=7798 > "$TMP/s3.log" 2>&1
echo "s3 rc=$?"
probe "after-clean-run-2"

echo "== server log tail =="
tail -8 "$SRV"
