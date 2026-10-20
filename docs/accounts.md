# Tandora — Accounts Protocol

Account creation, login, logout, and session validation for the dedicated
server. Implemented in `scripts/AccountService.gd` (store + logic),
`scripts/PasswordHasher.gd` (KDF), `scripts/SecureRandom.gd` (random bytes),
and bridged over the WebSocket channel in `scripts/Network.gd`.

Verified live 2026-10-20 (see `tests/run_accounts_tests.sh`).

## Transport: one request/response RPC pair

"Endpoints" in this codebase are Godot multiplayer RPCs on the existing
WebSocket channel — there is no HTTP. One request RPC and one response RPC
cover all four account actions:

```
client -> server:  rpc_account_request(request_id, action, email, secret)
server -> client:  rpc_account_response(request_id, ok, error, data)
```

- Both RPCs live on the **Network autoload** (`/root/Network`) — scene RPC
  routing matches on node path, so clients must send from their own Network
  node, never from some other scene node.
- `request_id` is chosen by the client (any unique int) and echoed back; the
  client matches responses to requests on it.
- `action` is one of: `create`, `login`, `logout`, `validate`.
- `secret` is the **password** for create/login and the **session token** for
  logout/validate. `email` is only used for create/login (send `""` for the
  others).

### Client usage pattern (GDScript)

```gdscript
func account_rpc(action: String, email: String, secret: String) -> Dictionary:
    # ... wire a one-shot connection to Network.account_response that matches
    # on request_id, then:
    Network.rpc_account_request.rpc_id(1, request_id, action, email, secret)
```

The Network autoload emits `account_response(request_id, ok, error, data)`
on the client when the server replies.

## Actions

| action | secret means | success `data` |
|---|---|---|
| `create` | password | `{user_id, email}` (email lowercased) |
| `login` | password | `{user_id, email, token, expires_at}` (unix seconds) |
| `logout` | session token | `{}` (idempotent — unknown tokens are OK) |
| `validate` | session token | `{user_id, email}` |

### `create`

- Email: case-insensitive uniqueness (stored normalized to lowercase),
  max 254 chars / 64 local part, must match `_EMAIL_RE` in AccountService.gd.
- Password: min 8 chars and at least two of {lower, upper, digit}
  (`PasswordHasher.is_valid_password`).
- Duplicate email → `EMAIL_TAKEN`. A second account per email is never
  possible.

### `login`

- Unknown email and wrong password both return `INVALID_CREDENTIALS`
  (no user enumeration), and unknown emails still pay a full KDF against a
  server-side dummy hash (no timing enumeration).
- Success returns a **session token**: 256-bit hex (64 chars) from
  `/dev/urandom`, 30-day **sliding** expiry (each `validate` refreshes it).
  Max 10 live sessions per user; the oldest is evicted when the cap is hit.
- Brute force: **5 failed logins per connection ⇒ 60 s lockout**
  (`RATE_LIMITED` even for the correct password). The counter is per peer id
  and cleared on successful login or disconnect.

### `logout` / `validate`

- Malformed tokens (wrong length / non-hex) → `INVALID_SESSION`.
- `logout` revokes the session; it is idempotent (revoking an unknown
  token still returns ok=true).
- Expired or unknown tokens → `INVALID_SESSION`.

## Error codes

`ok=false`, `error` is one of:

`INVALID_EMAIL` · `WEAK_PASSWORD` · `EMAIL_TAKEN` · `INVALID_CREDENTIALS` ·
`INVALID_SESSION` · `RATE_LIMITED` · `UNKNOWN_ACTION`

## Credentials & storage

- **Password hashing: PBKDF2-HMAC-SHA256**, 210,000 iterations, per-user
  16-byte salt, 32-byte digest. Stored string (self-describing, iteration
  count per hash so it can be raised later):

  ```
  pbkdf2_sha256$210000$<salt_base64>$<digest_base64>
  ```

  HMAC-SHA256 and PBKDF2 are built on the engine's native SHA-256
  (`HashingContext`); a pure-GDScript SHA-256 reference implementation is
  kept in PasswordHasher and cross-checked against the native one in tests.
- **Files** (JSON, one per store, each wrapped in a `schema_version`
  envelope — see `docs/migrations.md`):
  - `users.json` — `id` (`usr_` + 24 hex), `email`, `email_key` (lowercase),
    `display_name`, `password_hash`, `created_at`, `updated_at`
    (ISO-8601 UTC with `Z`).
  - `sessions.json` — token → `{token, user_id, email_key, created_at,
    expires_at, last_validated_at}` (unix seconds).
- **Location**: `--accounts_dir=<path>` CLI arg; otherwise `/app/data`
  when that directory exists (the container's mounted volume), else
  `user://data`. **Accounts must live under the mounted volume** —
  `user://` is wiped on every deploy (see `docs/accounts-baseline.md`).
- Writes are atomic (write `.tmp`, then `rename` over the target) so a crash
  mid-write cannot truncate a credential file.
- **Nothing sensitive is logged**: only the lowercased email is printed;
  passwords, tokens, and digests never reach the log or any file.

## Testing

```
bash tests/run_accounts_tests.sh
```

1. Unit store tests (`tests/test_accounts_store.gd`) — crypto
   known-answer vectors (SHA-256, HMAC, PBKDF2, base64; all computed
   independently in Python), account flows, rate limiting, persistence,
   v0→v1 migration, and the "no plaintext on disk" invariants.
2. Integration — a real dedicated server on `:7791` plus a WebSocket
   client scene exercising the full protocol.
3. Storage/logging invariants — hash format, schema envelopes, and the
   test password absent from both the store files and the server log.

Exit 0 only if everything passes.
