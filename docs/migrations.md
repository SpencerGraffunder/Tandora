# Tandora — Account Store Migrations

The account store is JSON files (no SQL). Every file is wrapped in an
envelope carrying its schema version, and `AccountService` upgrades older
schemas in place at startup (once per file; the migrated file is re-written).

Files: `users.json`, `sessions.json` (under the accounts data dir —
`--accounts_dir=<path>`, or `/app/data` in the container; see
`docs/accounts.md`).

## Schema versions

### v1 (current, `schema_version: 1`)

`users.json`:

```json
{
  "schema_version": 1,
  "users": [
    {
      "id": "usr_<24 hex>",
      "email": "original-case@example.com",
      "email_key": "original-case@example.com",
      "display_name": "original-cas",
      "password_hash": "pbkdf2_sha256$210000$<salt_b64>$<digest_b64>",
      "created_at": "2026-10-20T04:04:05Z",
      "updated_at": "2026-10-20T04:04:05Z"
    }
  ]
}
```

`sessions.json`:

```json
{
  "schema_version": 1,
  "sessions": {
    "<64-hex token>": {
      "token": "<64-hex token>",
      "user_id": "usr_<24 hex>",
      "email_key": "original-case@example.com",
      "created_at": 1792469047,
      "expires_at": 1795061047,
      "last_validated_at": 1792469047
    }
  }
}
```

### v0 (legacy)

- `users.json` — a **bare JSON array** of user objects, no envelope. Entries
  may lack `id` and timestamps.
- `sessions.json` — a bare object mapping token → session dict (already
  close to v1).

## Migration rules (implemented in AccountService.gd)

- `v0 users.json` → v1: each entry is normalized — missing `id` gets a fresh
  `usr_` id, missing timestamps get "now", missing `display_name` is derived
  from the local email part (max 16 chars). Entries without a usable email
  **and** password hash are dropped (they are unusable).
- `v0 sessions.json` → v1: entries lacking `user_id` or `expires_at` are
  dropped; the rest are copied with default fill-ins.
- A file with a schema version **newer** than supported is loaded as-is with
  a warning (forward-compatibility: a newer server wrote it, so trust it).
- A file that is **unrecognized** (neither array nor envelope) is not
  touched: it is backed up to `<file>.bak` and the store starts empty.
  Nothing is silently destroyed.
- After any migration the file is re-written in the current format, so each
  schema step runs exactly once.

## Adding a new schema version (runbook)

1. Bump `SCHEMA_VERSION` in `scripts/AccountService.gd`.
2. Add/extend the `_migrate_users` / `_migrate_sessions` branches for the
   previous version. Keep migrations pure (no KDF work, no network).
3. Add a unit test in `tests/test_accounts_store.gd` that writes an old
   version file and asserts the migrated content.
4. Bumping the PBKDF2 iteration count is **not** a schema change — the count
   is stored per hash; new hashes use the new count and old hashes keep
   theirs (optionally re-hash on next successful login, future work).
