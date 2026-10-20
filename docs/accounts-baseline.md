# Tandora — Baseline for the Accounts Feature

Prepared for the `feature/accounts` branch (branched from `master` @ baf6466).
This documents how the app builds, runs, persists, and deploys **today**, so the
accounts work can build on it without re-discovering anything.
Verified live 2026-10-19.

## What Tandora is

- Godot **4.7** multiplayer game (Tetris-style, 1–8 players per room).
- One codebase, two modes:
  - **Client** — normal exported app (web + native), connects to a server.
  - **Dedicated server** — the Linux export run `--headless`; `_ready()` in
    `scripts/Network.gd` detects the headless display server and auto-starts a
    room host listening on **TCP/WS :7777** (`[SERVER] Ready to host at ws://0.0.0.0:7777`).
- Networking: Godot `MultiplayerPeer`. Client address is hardcoded in
  `scripts/Network.gd::_set_server_address_and_protocol()`:
  - feature tag `local` → `127.0.0.1:7777`
  - otherwise → `tandoraserver.nuclearquads.com` (Cloudflare tunnel → Unraid :7777)

## Repo & branches

- Repo: `github.com/SpencerGraffunder/Tandora`, **default branch is `master`**
  (not `main`).
- Feature work happens on **`feature/accounts`** (this branch, pushed to origin).
- Canonical checkout lives on Unraid at `/mnt/user/ai-workspace/Tandora`
  (CIFS share `ai-workspace`; reachable from the workstation as
  `/mnt/ai-workspace/Tandora`). `core.filemode=false` is already set (CIFS).
- CI (`.github/workflows/build.yml`, Godot 4.7 via `GODOT_VERSION`):
  - Every push/PR: builds Linux server + web exports.
  - Push to **master** only: publishes the Linux binary to the GitHub release
    **`latest`** (asset name must stay **`tandora.x86_64`**) and deploys the web
    build to `nuclearquads.github.io/tandora`.
  - Pushing `feature/accounts` triggers builds but **not** publish/deploy —
    safe to push WIP.

## Running locally (verified 2026-10-19)

Use Godot **4.7 stable** (must match CI's `GODOT_VERSION`).

1. Import: `godot --headless --import` → exits 0, no script errors.
2. Run from source (starts as dedicated server when headless):
   `godot --headless` → prints `[SERVER] Ready to host at ws://0.0.0.0:7777`
   and creates the leaderboard dir under `user://`.
3. Run the shipped artifact (what the server actually runs):
   `tandora.x86_64 --headless` from the `latest` release asset → listens on :7777
   (verified: `ss -ltnp` shows the listener).
   Note: the exported binary buffers stdout when not on a tty — judge it by the
   listener, not by log silence.
4. Multiple local instances (debugging setup in README): `--instance_id=N`
   (appended to the device id by `scripts/DeviceID.gd`).

## Environment variables

- **The app reads no environment variables at all** (grep-verified across all
  `.gd` sources). All behavior is via CLI args (`--headless`,
  `--instance_id=N`) and export feature tags (`local`).
- Deployment side: `GITHUB_TOKEN` is *optional* for the updater (only raises the
  API rate limit). The compose project sets no env vars.

## Persistence & "migrations"

**There is no SQL database.** All persistence is flat JSON written by the
dedicated server only:

| File | Format |
|---|---|
| `user://leaderboards/<player_count>.json` (1–8) | JSON array, sorted by score desc, capped at 25 (`leaderboard_limit`). Entry: `{"score": int, "level": int, "timestamp": "YYYY-MM-DD HH:MM:SS" (server local, no TZ), "usernames": [host_display_name], "player_numbers": [...]}` |
| `user://device_id.txt` | single line: `<OS.get_unique_id()>-<randi()>` |

- `user://` on Linux = `$HOME/.local/share/godot/app_userdata/Tandora/`.
- Leaderboard saves require a non-empty host username (anonymous games are
  skipped); on save the server pushes the updated list to all connected peers
  (`rpc_leaderboard_response`), which `LeaderboardUI.gd` renders.
- **⚠️ KNOWN GAP (affects accounts design):** in the container `HOME=/root`, so
  ALL persistence sits in the container's **ephemeral writable layer** — the
  updater's `docker compose up -d --force-recreate` wipes it on every release
  deploy. Leaderboards are currently empty (no data lost yet); `device_id.txt`
  silently resets on every update.
- **Consequence for accounts:** put any account/credential store under
  `/app/data/` (the only mounted volume → `/mnt/user/appdata/tandora`) or add a
  second volume in `compose.yaml`. "Migration" for accounts = new JSON file(s)
  under that persistent path + the path constant change in code. There are no
  migration commands to run (no DB engine).
- If the accounts work changes the leaderboard entry shape, keep
  `Network.gd` (write) and `LeaderboardUI.gd` (read) in sync.

## Target server: Unraid "UnCube" (192.168.4.200)

- **Compose project** `tandora-server` at
  `/boot/config/plugins/compose.manager/projects/tandora-server/compose.yaml`:
  image `debian:stable-slim`, `network_mode: host`,
  volume `/mnt/user/appdata/tandora:/app`, command:
  `apt-get install -y --no-install-recommends libfontconfig1 curl` (the Godot
  binary needs fontconfig; runs on every container start) then
  `exec ./tandora.x86_64 --headless`.
- **Auto-deploy** (no auth needed — public repo): root crontab
  `*/10 * * * * /mnt/user/appdata/tandora/tandora-update-cron.sh` →
  `update-tandora.sh`:
  1. Polls GitHub release `latest` on the repo.
  2. Idempotent via `.last_release_id`; **refuses to roll back** to an older
     release id (override with `--force`).
  3. Verifies the download is a real ELF (`\x7fELF`) before swapping
     (previous binary kept as `tandora.x86_64.bak`).
  4. Restarts via `docker compose up -d --force-recreate`.
  - Log: `/mnt/user/appdata/tandora/update.log` (bounded to 1 MB).
- **Boot**: compose project autostarts with Unraid; a user.scripts entry
  ("update tandora") also runs the updater at boot.
- **Client endpoint**: `tandoraserver.nuclearquads.com` (Cloudflare tunnel) →
  host :7777.

### Verified healthy (2026-10-19)

- `docker ps`: `tandora-server  Up 12 days`.
- Deployed binary sha256 `20e7487c57…` == `latest` release asset sha256
  (release `latest` = commit baf6466 = master HEAD; release id 401949402).
- `ss -ltnp`: `*:7777` LISTEN by `tandora.x86_64`.
- Updater last runs: `Already up to date (release id 401949402)` — healthy.
- Websocket `ERROR` lines in `docker logs` are normal noise: the Godot WSL
  peer rejecting non-WebSocket (HTTP health-check/probe) connections.

### Manual deploy / rollback

- Deploy a specific build: export Linux with Godot 4.7
  (`godot --headless --export-release Linux build_linux/tandora.x86_64`),
  publish it as release `latest` (asset `tandora.x86_64`) — cron picks it up
  within 10 min, or run `/mnt/user/appdata/tandora/update-tandora.sh` manually.
- Rollback: `update-tandora.sh --force` after repointing `latest`, or restore
  `tandora.x86_64.bak` and `docker compose restart`.

## Gotchas for the accounts tasks

1. Server mode is selected **by being headless** — keep `--headless` in the
   compose command; don't add UI-only code paths that assume a display.
2. The web client hardcodes the server hostname in `Network.gd` — if accounts
   need a different endpoint, that's the place.
3. Don't rename the release asset or the `latest` tag — the updater depends on
   both.
4. CIFS: no symlinks, `core.filemode=false` (already set); run Godot builds on
   local disk and copy artifacts across.
5. Anything that must survive deploys belongs under `/app/` (mounted), never
   `user://` — see the persistence gap above.
