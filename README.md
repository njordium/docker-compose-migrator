**A Bash tool for migrating Docker Compose stacks between servers via a third-party client -- no direct server-to-server connection required.**

<img width="424" height="261" alt="Screenshot2026-06-24 at 19 28 46" src="https://github.com/user-attachments/assets/212678d9-cb5c-412a-befd-de340702f409" />

## Why this exists

Moving a Docker Compose stack from one server to another sounds simple until you actually try it. Named volumes live under `/var/lib/docker/volumes/` and can't be `docker cp`'d out. Bind mounts may reference paths that don't exist on the destination. Database containers need graceful shutdown before copying data. Port conflicts on the destination silently break services. And if the two servers can't reach each other directly (different networks, firewalls, NAT), you're stuck stitching together tar pipes and SSH tunnels by hand.

This script handles the entire workflow from a Mac or Linux workstation sitting between the two servers -- pre-flight checks, dependency-aware service selection, safe database shutdown, volume transfer, image pull, startup, and post-migration verification.

## What it does

- Migrates Docker Compose stacks between any two hosts via a **third-party client** (your laptop/workstation)
- Transfers **named volumes** and **compose project files** using tar-over-SSH with dedicated connections
- **Database-aware shutdown** -- detects Postgres/MySQL/MariaDB/MongoDB/Redis and uses extended graceful timeout with exit-code verification
- **Dependency resolution** -- selecting a service automatically includes its entire `depends_on` chain
- **Pre-flight checks** -- SSH connectivity, Docker versions, architecture match, disk space, port conflicts, storage driver, LXC compatibility, inotify limits, PUID/PGID verification
- **SSH multiplexing** for control commands with dedicated fresh connections for data transfer
- **Backup and restore** -- full stack backup to local archive before migration, with numbered restore menu
- **Post-migration verification** -- container status, volume integrity, port accessibility, log error scan
- Supports **non-root SSH** with passwordless sudo (login user differs from effective user)
- Runs on **macOS** (Bash 4+ via Homebrew) and **Linux**

## Quick start

```bash
git clone https://github.com/njordium/docker-compose-migrator.git
cd docker-compose-migrator
chmod +x docker-migrate.sh
```

**macOS** (requires Bash 4+):
```bash
/opt/homebrew/bin/bash docker-migrate.sh
```

**Linux:**
```bash
bash docker-migrate.sh
```

On first run, use menu option **k** to generate an SSH keypair and deploy it to both servers, then option **1** to configure the connection.

## Requirements

| Requirement | Details |
| ----------- | ------- |
| Client OS | macOS (Bash 4+ via `brew install bash`) or Linux |
| Tools | ssh, rsync, tar, awk, grep, sed, ping, stat |
| Source server | Docker + Docker Compose, SSH access |
| Destination server | Docker + Docker Compose, SSH access |
| SSH | Key-based auth to both servers (script can generate and deploy keys) |
| Sudo | Passwordless sudo if SSH login user differs from root |

## Usage

```
Usage: docker-migrate.sh [OPTIONS]

Options:
  -v, --verbose   Show detailed output for all checks and operations
  -f, --force     Skip confirmation prompts
  -h, --help      Show this help

Examples:
  bash docker-migrate.sh                  # Interactive menu
  bash docker-migrate.sh --verbose        # Menu with verbose output
  bash docker-migrate.sh --verbose --force
```

### Interactive menu

The script presents a full menu on launch:

```
── Setup ──────────────────────────────
  1) Configure connection
  2) Select stack + services to migrate

── Checks ─────────────────────────────
  3) Run pre-flight checks
  4) Run extended diagnostics

── Migration ──────────────────────────
  5) Start migration
  6) Dry-run migration (no changes)
  7) Verify destination

── Backup & Restore ───────────────────
  b) Backup source stack
  r) Restore backup to destination

── Tools ──────────────────────────────
  8) Toggle verbose mode
  9) Toggle decommission mode
  0) View log file
  c) Clear saved configuration
  a) Verify access (SSH + sudo + docker)
  k) SSH key management (generate + deploy)
  q) Quit
```

### Typical workflow

1. **k** -- Generate SSH key and deploy to both servers (one-time setup)
2. **1** -- Configure source and destination connection details
3. **2** -- Scan source for compose projects, pick one, optionally select specific services
4. **3** -- Run pre-flight checks (catches problems before touching anything)
5. **5** -- Run the migration
6. **7** -- Verify destination is healthy

---

## How it works

### Connection model

```
┌──────────┐        SSH         ┌──────────────┐        SSH         ┌─────────────┐
│  Source  │◄──────────────────►│    Client    │◄──────────────────►│ Destination │
│  Server  │   tar czf → pipe   │ (Mac/Linux)  │   pipe → tar xzf   │   Server    │
└──────────┘                    └──────────────┘                    └─────────────┘
```

The client machine orchestrates everything. Data flows: source → client → destination via tar-over-SSH pipes. Control commands use SSH multiplexing for speed; data transfers use dedicated connections to avoid saturating the shared socket.

### Migration steps

| Step | Action |
| ---- | ------ |
| 1 | **Backup** -- streams compose project + volumes to a local `.tar.gz` archive |
| 2 | **Stop source** -- `docker compose down` with database-aware timeout (60s for Postgres). Verifies clean shutdown via container exit code |
| 3 | **Prepare destination** -- creates target directory |
| 4 | **Transfer compose project** -- tar pipe from source through client to destination |
| 5 | **Migrate volumes** -- registers each volume with `docker volume create`, then streams data via tar pipe. Verifies entry counts after transfer |
| 6 | **Pull images** -- background `docker compose pull` on destination with polling |
| 7 | **Start stack** -- `docker compose up -d` with container count polling |
| 8 | **Health check** -- container status, volume integrity, port listening, log error scan |

### Service selection and dependency resolution

When migrating a subset of services, the script parses `docker compose config` to resolve the full `depends_on` chain. Selecting `teslamate` automatically includes `database` and `mosquitto` if they're declared as dependencies.

### SSH architecture

- **Multiplexed control sockets** (`ControlMaster`) for rapid pre-flight commands -- avoids IDS rate limiting from many short-lived connections
- **Dedicated fresh connections** (`ControlMaster=no`) for all data transfers -- prevents keepalive timeouts when saturating the socket with large tar streams
- **`ssh -n`** on all `ssh_src`/`ssh_dst` calls -- prevents SSH from consuming stdin in `while read` loops (a classic Bash pitfall that silently skips loop iterations)

---

## Pre-flight checks

The pre-flight system validates the full migration path before touching anything:

| Check | What it verifies |
| ----- | ---------------- |
| SSH connectivity | Key auth to both servers (combined SSH + sudo in one round trip) |
| Docker | Engine and Compose versions on both hosts |
| Storage driver | Detects LXC, checks for fuse-overlayfs, /dev/fuse |
| Hardware | iGPU passthrough (/dev/dri) for Plex/VAAPI stacks |
| Compose project | Locates compose file, enumerates services and volumes |
| Database detection | Warns about Postgres/MySQL and recommends logical backup |
| Bind mounts | Flags mounts outside the project path that won't auto-transfer |
| PUID/PGID | Verifies user/group IDs exist on destination |
| Disk space | Compares data size to destination free space |
| Architecture | Confirms source and destination CPU arch match |
| Port conflicts | Checks each published port on destination, identifies owning container |
| inotify limits | Validates watches and instances for container-heavy stacks |

---

## Backup & restore

### Backup

```bash
# From the menu: option b
# Or during migration: Step 1 offers automatic pre-migration backup
```

Creates a `.tar.gz` archive containing the compose project directory and all named volume data, streamed directly from the source server.

### Restore

```bash
# From the menu: option r
```

Lists available backups for the configured stack with timestamps and sizes. Selecting a backup stops the destination stack, extracts the archive locally, pushes compose files and volumes to the destination, and starts the stack.

---

## Access verification

Option **a** tests every layer of the access chain with specific fix instructions:

```
── Source (khaverblad@192.168.0.22:22) ──────
  [1] SSH key exists: ~/.ssh/id_ed25519
  [2] Key permissions: 600
  [3] SSH TCP connection: OK
  [4] Key-based auth: working (no password required)
  [5] Passwordless sudo: working (khaverblad → root)
  [6] sudo docker: working (v28.1.1)
  [7] Base path writable: /opt
```

---

## Configuration

The script saves connection details to `~/.docker-migrate.conf` and auto-loads them on next run. Clear with menu option **c**.

| Setting | Default | Description |
| ------- | ------- | ----------- |
| `SRC_HOST` / `DST_HOST` | -- | Server IP or hostname |
| `SRC_PORT` / `DST_PORT` | `22` | SSH port |
| `SRC_USER` / `DST_USER` | `root` | Effective user (runs docker commands) |
| `SRC_LOGIN` / `DST_LOGIN` | -- | SSH login user (if different, uses sudo) |
| `SRC_KEY` / `DST_KEY` | `~/.ssh/id_ed25519` | SSH private key path |
| `SRC_BASE` / `DST_BASE` | `/opt` | Base path scanned for compose projects |
| `DECOMMISSION_MODE` | `true` | Leave source stopped after migration |

---

## Troubleshooting

**SSH connection drops during volume transfer**

Large volumes can trigger IDS rate limiting. The script uses dedicated connections for data transfers, but if your firewall is aggressive, increase `ServerAliveInterval` or whitelist the client IP.

**Only some volumes transferred**

Fixed in v3.6.1. Ensure you're running the latest version -- older versions had a bug where `ssh` inside `while read` loops consumed stdin, silently skipping volumes after the first.

**Postgres data missing or corrupt after migration**

The script stops Postgres with a 60-second graceful timeout and verifies the exit code. If you see `Exited (137)` (SIGKILL), the timeout wasn't enough -- create a `pg_dump` backup before migrating.

**Port conflicts on destination**

Run pre-flight (option 3) before migrating. It checks every published port and identifies which container owns it on the destination.

**macOS: `LIBARCHIVE.xattr` tar warnings**

Fixed in v3.6.1. The local tar now uses `COPYFILE_DISABLE=1` to suppress Apple extended attribute headers.

**macOS: Bash version error**

macOS ships with Bash 3.2. Install Bash 4+ via Homebrew:
```bash
brew install bash
/opt/homebrew/bin/bash docker-migrate.sh
```

**Destination containers start but app shows no data**

Verify all volumes were transferred:
```bash
ssh user@destination "docker volume ls | grep STACK_NAME"
```
Each volume should have data under `/var/lib/docker/volumes/VOLNAME/_data/`.

---

## Contributing

Pull requests are welcome. For significant changes please open an issue first to discuss the approach.

---

## License

[MIT](LICENSE) -- free to use, modify, and distribute. Attribution appreciated but not required.

---

*Giving back to the open source community that makes our work possible.*
