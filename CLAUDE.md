# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TorBox Media Server is a set of shell scripts that installs, configures, and runs a complete debrid-powered media server using Docker. **No media is stored locally** — everything streams from TorBox's cloud. The main entry point is `setup.sh`, which generates configs, a Docker Compose file, and a `manage.sh` script.

## Repository Structure

| File | Purpose |
|------|---------|
| `setup.sh` | Main installation script. Interactive by default; supports `--yes` for non-interactive installs. Generates `docker-compose.yml`, `.env`, `manage.sh`, and systemd service. |
| `uninstall.sh` | Clean removal of containers, configs, data, and systemd service. |
| `install-casaos.sh` | CasaOS one-click installer. Clones repo, runs `setup.sh --yes`, and syncs credentials. |
| `docker-compose.yml` | Reference Docker Compose file (copied to install dir by `setup.sh`; user edits expected post-install for LAN access). |
| `.env.example` | Template for non-interactive installs. Users set env vars before running `setup.sh --yes`. |
| `tests/` | Shell-based test suites: `test_setup_functions.sh` (unit), `test_api_key.sh`, `test_e2e.sh` (full pipeline). |
| `.shellcheckrc` | ShellCheck config with intentional disables (e.g., `SC2034`, `SC2086`). |
| `.github/workflows/lint.yml` | CI: `shfmt` formatting, ShellCheck, unit tests, `manage.sh` extraction/validation, compose validation. |

## Common Commands

### Run tests

```bash
# Unit tests (mask_key, generate_api_key, etc.)
bash tests/test_setup_functions.sh

# API key tests
bash tests/test_api_key.sh

# Full E2E test suite (syntax, config generation, compose validation, manage.sh generation, systemd correctness, uninstall safety)
bash tests/test_e2e.sh
```

### Lint / format

```bash
# ShellCheck (lint)
shellcheck setup.sh uninstall.sh tests/*.sh

# shfmt (format)
shfmt -d -i 4 -ci setup.sh uninstall.sh tests/
shfmt -w -i 4 -ci setup.sh uninstall.sh tests/   # write changes
```

### Validate manually

```bash
# Syntax check
bash -n setup.sh
bash -n uninstall.sh
bash -n tests/test_*.sh

# Validate docker-compose.yml with dummy env (example for plex profile)
export PUID=1000 PGID=1000 TZ=UTC
export CONFIG_DIR=/tmp/config DATA_DIR=/tmp/data MOUNT_DIR=/tmp/mount
export TORBOX_API_KEY=testkey1234567890123456789012345
export RADARR_API_KEY=radarrkey12345678901234567890123
export SONARR_API_KEY=sonarrkey12345678901234567890123
export PROWLARR_API_KEY=prowlarrkey1234567890123456789012
export DECYPHARR_USER=torbox DECYPHARR_PASS=password
export PLEX_CLAIM=claim-xxxxx
export COMPOSE_PROFILES=plex
docker compose config -q
```

### Run the setup script

```bash
# Interactive
chmod +x setup.sh && ./setup.sh

# Non-interactive
TORBOX_API_KEY="your-key" TORBOX_MEDIA_SERVER="plex" ./setup.sh --yes
```

## Architecture

### Script architecture

`setup.sh` is a single monolithic Bash script (~3000 lines) broken into sections with visual comment dividers. It is designed to be self-contained and runnable on any Linux distro (tested primarily on CachyOS/Arch-based systems). Key design decisions:

- **Self-contained**: All functions, config generation logic, and the entire `manage.sh` script are embedded as heredocs inside `setup.sh`. This means `setup.sh` can be downloaded and run standalone without dependencies on other repo files.
- ** Generated artifacts**: Running `setup.sh` produces:
  - `torbox-media-server/.env` — auto-detected/generated values (PUID, PGID, TZ, API keys, passwords).
  - `torbox-media-server/docker-compose.yml` — copied from repo, with `docker-compose.override.yml` injected for hardware acceleration.
  - `torbox-media-server/manage.sh` — post-install management script (status, logs, update, stop, start, keys, etc.), generated via concatenated heredocs.
  - `torbox-media-server/torbox-media-server.service` — systemd unit for auto-start.
- **Idempotent re-runs**: Existing `.env` values are preserved; only missing values are regenerated. This ensures API keys and passwords remain stable across updates.
- **Interrupt safety**: `trap` handlers clean up partial installations on `SIGINT`/`SIGTERM`.

### Service orchestration

The stack uses Docker Compose with profiles (`plex` or `jellyfin`) to activate only the selected media server:

- **Decypharr** — mocks qBittorrent API, connects to TorBox, handles rclone WebDAV mount.
- **Prowlarr** — indexer aggregator.
- **Byparr** — FlareSolverr-compatible bypass for Prowlarr.
- **Radarr / Sonarr** — movie/TV show management (auto-configured via API after startup).
- **Seerr** — request / discovery UI (auto-configured via API).
- **Plex or Jellyfin** — media server (user-selected, hardware acceleration auto-detected).

### Auto-configuration pipeline

After `docker compose up`, `setup.sh` performs automated first-time config via the *arr APIs:

1. **Download clients** — connects Radarr/Sonarr to Decypharr (qBittorrent API).
2. **Root folders** — adds `/data/movies` and `/data/tv`.
3. **Media management & naming** — sets naming templates, quality profiles, and enables upgrades.
4. **Prowlarr apps & proxy** — syncs Prowlarr with Radarr/Sonarr.
5. **Seerr** — connects to Radarr/Sonarr and Plex/Jellyfin.
6. **Plex libraries** — creates Movies and TV Show libraries via Plex API (if Plex selected).
7. **Auth sync** — pushes `.env` admin credentials into *arr services.

### Port map (single source of truth in `setup.sh`)

| Service | Port |
|---------|------|
| Decypharr | 8282 |
| Prowlarr | 9696 |
| Byparr | 8191 |
| Radarr | 7878 |
| Sonarr | 8989 |
| Seerr | 5055 |
| Plex | 32400 |
| Jellyfin | 8096 |

## Testing approach

Tests are Bash scripts using a lightweight framework defined in `tests/test_utils.sh` (`pass`/`fail`/`print_summary`).

- `test_setup_functions.sh` sources specific functions from `setup.sh` using `sed` to extract them by name (e.g., `source <(sed -n '/^generate_api_key() {/,/^}/p' setup.sh)`). This avoids side effects from sourcing the entire script.
- `test_e2e.sh` validates the full pipeline: syntax, config generation, compose validation, `manage.sh` generation, systemd correctness, and uninstall safety.
- CI runs all tests plus `manage.sh` extraction (via Perl to handle nested heredocs) and Docker Compose validation for both `plex` and `jellyfin` profiles.

## Code style

- Functions are named with underscores (e.g., `generate_api_key`, `run_with_spinner`).
- Long sections are separated by visual `# ==== … ====` dividers.
- User-facing messages use the `log_*` helpers (`log_info`, `log_warn`, `log_error`, `log_step`, `log_section`).
- All shell scripts must pass ShellCheck (CI enforces this).
- Commit messages use conventional commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`).
