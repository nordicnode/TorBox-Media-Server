<div align="center">

# 🎬 TorBox Media Server

**A single-command, zero-storage personal streaming setup — powered by TorBox cloud.**

[![ShellCheck](https://github.com/nordicnode/TorBox-Media-Server/actions/workflows/lint.yml/badge.svg)](https://github.com/nordicnode/TorBox-Media-Server/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Requires-Docker-blue?logo=docker)](https://docs.docker.com/get-docker/)
[![TorBox](https://img.shields.io/badge/Powered%20by-TorBox-orange)](https://torbox.app)
[![GitHub Stars](https://img.shields.io/github/stars/nordicnode/TorBox-Media-Server?style=social)](https://github.com/nordicnode/TorBox-Media-Server/stargazers)

</div>

> **Your request → TorBox finds & stores → You stream. Zero local storage.**

A single script that installs, configures, and runs a complete debrid-powered media server using Docker. **No media is stored locally** — everything streams from [TorBox](https://torbox.app)'s cloud. Think of it as your own personal Netflix where *you* decide what's available, backed by TorBox's cloud download and cache infrastructure.

## ⚡ Quick Start

```bash
git clone https://github.com/nordicnode/TorBox-Media-Server.git && cd TorBox-Media-Server
chmod +x setup.sh && ./setup.sh
```

For unattended installs:

```bash
TORBOX_API_KEY="your-api-key" TORBOX_MEDIA_SERVER="plex" ./setup.sh --yes
```

Run `./setup.sh --help` for all available options.

> **Prerequisites:** A Linux machine with an internet connection, and a [TorBox paid plan](https://torbox.app). The script auto-installs Docker, FUSE, and jq.

---

## 📑 Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Components](#components)
- [Before You Begin](#before-you-begin)
- [Setup Walkthrough](#setup-walkthrough)
- [What the Script Configures Automatically](#what-the-script-configures-automatically)
- [Post-Install Walkthrough](#post-install-walkthrough)
- [Management](#management)
- [Accessing From Other Devices](#accessing-from-other-devices)
- [Security Notes](#security-notes)
- [Updating](#updating)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Design Decisions](#design-decisions)
- [Glossary](#glossary)
- [Contributing](#contributing)
- [License](#license)

---

## How It Works

```
  You search for a movie in Seerr (or Radarr/Sonarr)
                    │
                    ▼
  Radarr/Sonarr search Prowlarr's indexers for the best torrent
                    │
                    ▼
  The torrent is sent to Decypharr (which pretends to be qBittorrent)
                    │
                    ▼
  Decypharr sends the torrent hash to TorBox via its API
                    │
                    ▼
  TorBox checks its cache — if someone else already downloaded it,
  it's available INSTANTLY. Otherwise, TorBox downloads it in the cloud.
                    │
                    ▼
  Decypharr mounts TorBox's storage via WebDAV and creates symlinks
  (shortcuts) that point to the cloud files
                    │
                    ▼
  Plex or Jellyfin reads these symlinks and streams the content
  to any device on your network — phone, TV, tablet, computer
```

### Example: Requesting Your First Movie

1. You open **Seerr** in your browser and search for "Inception"
2. You click "Request" — Seerr tells Radarr to find it
3. **Radarr** asks **Prowlarr** to search torrent indexers for the best quality version
4. Prowlarr finds a 1080p Bluray torrent and sends it back to Radarr
5. Radarr sends the torrent to **Decypharr** (which looks like qBittorrent to Radarr)
6. Decypharr sends the torrent hash to **TorBox** — TorBox already has it cached (popular movie!), so it's available **instantly**
7. Decypharr creates a symlink: `/movies/Inception (2010) [imdbid-tt1375666]/Inception (2010) [Bluray-1080p].mkv`
8. Radarr imports the file and notifies **Plex/Jellyfin**
9. You open Plex or Jellyfin on your TV and press play — it streams directly from TorBox's cloud

The whole process takes **seconds** for cached content (most popular movies/shows).

---

## Architecture

```
User Request                Search & Automation           Cloud Download
┌───────────┐   request   ┌────────────┐   search   ┌──────────────┐
│   Seerr   │ ──────────→│ Radarr     │ ─────────→│  Prowlarr    │
│   :5055   │            │ Sonarr     │           │  :9696       │
└───────────┘            └─────┬──────┘           │  + Byparr    │
                               │ grab torrent      └──────────────┘
                               ▼
                         ┌──────────────┐    TorBox API
                         │  Decypharr   │ ──────────────→ TorBox Cloud
                         │  :8282       │                 (download/cache)
                         │  (mock qBit) │ ←── WebDAV ──── TorBox WebDAV
                         └──────┬───────┘    mount via     webdav.torbox.app
                                │            rclone FUSE
                                │ symlink
                                ▼
                         ┌──────────────┐
                         │ Plex :32400  │    Streams to any device
                         │   or         │    Zero local storage
                         │ Jellyfin     │
                         │  :8096       │
                         └──────────────┘
```

---

## Components

| Service | Port | What It Does |
|---------|------|--------------|
| **Decypharr** | 8282 | The bridge between Radarr/Sonarr and TorBox. Pretends to be qBittorrent, mounts TorBox's cloud storage via WebDAV, and creates symlinks (shortcuts) to cloud files. |
| **Prowlarr** | 9696 | Manages your torrent indexers (search sources). When Radarr/Sonarr need a torrent, Prowlarr searches all your configured sites. |
| **Byparr** | 8191 | Helps Prowlarr bypass Cloudflare protection on some indexer sites. Works automatically in the background. |
| **Radarr** | 7878 | Movie manager. Searches for movies, picks the best quality torrent, sends it to Decypharr, and organizes your movie library. |
| **Sonarr** | 8989 | TV show manager. Same as Radarr but for TV series — handles seasons, episodes, and ongoing shows automatically. |
| **Seerr** | 5055 | Beautiful web UI where you (and your family/friends) can browse and request movies and TV shows. Supports Plex, Jellyfin & Emby. |
| **Plex** | 32400 | Media server option 1. Streams your library to any device. Requires a free Plex account. |
| **Jellyfin** | 8096 | Media server option 2 (open-source, no account needed). Streams your library to any device. |

> **Note:** All service ports including Plex and Jellyfin are bound to `127.0.0.1` (localhost only) by default for security. To stream from other devices on your LAN, you will need to expose the Plex/Jellyfin ports. See [Accessing From Other Devices](#accessing-from-other-devices).

---

## Before You Begin

Before running the setup script, make sure you have everything ready:

### Required

- [ ] **A Linux machine** — Designed for CachyOS (Arch-based) but works on Debian/Ubuntu, Fedora, and most distros
- [ ] **A TorBox account with a paid plan** — [Sign up at torbox.app](https://torbox.app) (plans start at a few dollars/month)
- [ ] **Your TorBox API key** — After signing up:
  1. Go to [torbox.app/settings](https://torbox.app/settings)
  2. Scroll to the "API Key" section
  3. Click "Create API Key" or copy your existing one
  4. Save it somewhere — you'll paste it during setup
- [ ] **~30 minutes** for the initial setup (most of it is automated)
- [ ] **~5–8 GB of bandwidth** for downloading Docker images on the first run

### Optional

- [ ] **Plex claim token** (only if you choose Plex as your media server):
  1. Go to [plex.tv/claim](https://www.plex.tv/claim/)
  2. Sign in to your Plex account (or create one for free)
  3. Copy the claim token (starts with `claim-`)
  4. **Use it within 4 minutes** — they expire quickly!

### Technical Prerequisites

The setup script checks for these and can install them automatically:

| Requirement | Purpose | Auto-installed? |
|---|---|---|
| **Docker** + **Docker Compose** | Runs all services in containers | ✅ Yes |
| **FUSE** | Enables rclone WebDAV mounts | Checked (usually pre-installed) |
| **jq** | JSON manipulation for advanced auto-configuration | ✅ Yes |
| **openssl** | Generates random API keys and passwords | ✅ Yes |

---

## Setup Walkthrough

The script will interactively ask you for:

| Prompt | What to enter |
|---|---|
| **TorBox API key** | Paste the API key from your [TorBox settings](https://torbox.app/settings) |
| **Plex or Jellyfin** | Choose `1` for Plex or `2` for Jellyfin |
| **Plex claim token** | (Plex only) Paste your claim token, or press Enter to skip |
| **Hardware acceleration** | Auto-detected; only prompted if both Intel and NVIDIA GPUs are present |
| **Start services?** | Press Enter or `Y` to start immediately (recommended) |

> **Auto-detected values:** Mount directory (`/mnt/torbox-media`), user/group IDs, timezone, and hardware acceleration are auto-detected. Override via environment variables: `TORBOX_MOUNT_DIR`, `TORBOX_HW_ACCEL`.

Then the script automatically:

1. Checks and installs dependencies (Docker, FUSE, jq, openssl)
2. Creates the full directory structure
3. Generates Decypharr config with your TorBox API key
4. Pre-seeds API keys into Radarr, Sonarr, and Prowlarr config files
5. Generates the `.env` file and Docker Compose
6. Creates the `manage.sh` management script
7. Sets up FUSE mount propagation
8. Installs a systemd service for automatic startup on boot
9. Starts all Docker containers
10. Waits for services to initialize, then auto-configures via API:
   - Download clients, root folders, media management, naming conventions, quality profiles, and service interconnections
   - Seerr connected to Radarr, Sonarr, and Plex/Jellyfin
   - Plex libraries (Movies + TV Shows) if claim token was provided
   - Default public indexer (1337x) in Prowlarr

> **First run takes 5–15 minutes** (mostly downloading Docker images). Subsequent starts take seconds.
>
> **Re-running the script** is safe — it detects existing installations, preserves your API keys to avoid breaking integrations, and lets you keep your existing TorBox API key or enter a new one.

---

## What the Script Configures Automatically

The setup script pre-seeds and auto-configures as much as possible so you don't have to. Here's exactly what's handled for you:

### Pre-Seeded (via config.xml, before containers start)

| Setting | Value | Why |
|---------|-------|-----|
| API keys | Random 32-char hex keys for Radarr, Sonarr, Prowlarr | Enables API auto-configuration on first launch |
| Authentication | `Enabled` | Requires login from first boot (auto-configured via API with pre-seeded credentials) |
| Decypharr config | TorBox API key, WebDAV mount, rclone mount, symlink paths | Connects to your TorBox account and enables rclone FUSE mounting |
| Systemd service | `torbox-media-server.service` | Auto-starts mount propagation and containers on boot |

### Auto-Configured via API (after containers start)

| Service | What's configured |
|---------|-------------------|
| **Radarr** | Download client (Decypharr), root folder, media management settings, naming convention, quality profile upgrades, Plex notifications |
| **Sonarr** | Download client (Decypharr), root folder, media management settings, naming convention, quality profile upgrades, Plex/Jellyfin notifications |
| **Prowlarr** | Connected to Radarr + Sonarr, default indexer (1337x) added |
| **Seerr** | Connected to Radarr, Sonarr, and your media server (Plex or Jellyfin) |
| **Plex** | Libraries for Movies and TV Shows created (if claim token was provided) |

> **Requires jq for API configuration.** If jq isn't available, the script skips the JSON-based auto-configuration steps. Run `./setup.sh` again after installing jq to complete configuration.

---

## Post-Install Walkthrough

After setup, follow these steps to verify everything is working:

### Step 1: Open Your Services (~1 minute)

Once setup completes, open these URLs in your browser:

| Service | URL | Purpose |
|---------|-----|---------|
| Seerr | http://localhost:5055 | Main request interface |
| Radarr | http://localhost:7878 | Movie manager |
| Sonarr | http://localhost:8989 | TV show manager |
| Prowlarr | http://localhost:9696 | Indexer manager |
| Decypharr | http://localhost:8282 | TorBox bridge status |
| Plex | http://localhost:32400/web | Media server (if chosen) |
| Jellyfin | http://localhost:8096 | Media server (if chosen) |

### Step 2: Verify Services Are Running (~1 minute)

Check that all containers are healthy:
```bash
cd torbox-media-server/
./manage.sh status
```

All services should show as `running (healthy)`. If any show `starting`, wait another minute and check again.

### Step 3: Complete Seerr Setup (~3 minutes)

Seerr requires a brief one-time wizard:

1. Open **Seerr** (http://localhost:5055)
2. Click **Get Started**
3. Sign in with your **Plex account** (if using Plex) — or create a local admin account (if using Jellyfin)
4. On the **Media Server** step:
   - **Plex:** Click **Sync Libraries**, select Movies and TV Shows, click **Continue**
   - **Jellyfin:** Enter `http://jellyfin:8096`, your admin credentials, sync libraries, continue
5. On the **Services** step:
   - Radarr should already be listed — click **Test**, then **Save**
   - Sonarr should already be listed — click **Test**, then **Save**
6. Click **Finish Setup**

> **If Radarr/Sonarr aren't connected:** Re-run `./setup.sh` — it detects existing installations and re-configures. Or add them manually:
> - **Radarr:** Hostname `radarr`, Port `7878`, API key from `./manage.sh keys`, Root Folder `/data/media/movies`
> - **Sonarr:** Hostname `sonarr`, Port `8989`, API key from `./manage.sh keys`, Root Folder `/data/media/tv`

**✅ What success looks like:** Seerr's main page shows a search bar and "Discover" section with trending movies and shows.

### Step 4: Test the Full Flow (~2 minutes)

Everything is set up! Let's make sure it all works end-to-end.

1. Open **Seerr** (http://localhost:5055) — or go directly to **Radarr** (http://localhost:7878)
2. Search for a **popular movie** (e.g., "Inception", "The Dark Knight", "Interstellar")
   - Popular movies are almost always already cached on TorBox, so they'll be available instantly
3. Click **Request** (in Seerr) or **Add Movie** (in Radarr)
4. Watch the progress:
   - In **Radarr** → Activity → Queue: you should see the movie being processed
   - Radarr searches Prowlarr → finds a torrent → sends it to Decypharr
   - Decypharr sends the hash to TorBox → TorBox has it cached → available immediately
   - Decypharr creates a symlink → Radarr imports it
5. Within **seconds to minutes**, the movie should appear in:
   - **Radarr** → Movies (with a green checkmark)
   - **Plex/Jellyfin** → Movies library
6. Press **play** in Plex/Jellyfin — it should stream smoothly!

🎉 **Congratulations!** Your personal streaming server is fully operational.

---

## Management

After setup, use the management script to control your services:

```bash
cd torbox-media-server/

./manage.sh start     # Start all services (re-applies mount propagation)
./manage.sh stop      # Stop all services
./manage.sh restart   # Restart all services (re-applies mount propagation)
./manage.sh status    # Check service status
./manage.sh logs      # View all logs (follow mode)
./manage.sh logs radarr  # View specific service logs
./manage.sh update    # Pull pinned image versions & restart
./manage.sh down      # Stop and remove containers
./manage.sh urls      # Show all service URLs
./manage.sh keys      # Show API keys (use with care)
./manage.sh enable    # Enable auto-start on boot
./manage.sh disable   # Disable auto-start on boot
```

> **Auto-start on boot:** The setup script installs a systemd service (`torbox-media-server`) that automatically handles mount propagation and starts all containers when your computer boots. You don't need to do anything — just turn on your computer and everything will be running.

## File Structure

```
torbox-media-server/
├── docker-compose.yml          # Auto-generated Docker Compose
├── .env                        # API keys, user IDs, timezone, mount paths
├── manage.sh                   # Management script (start/stop/logs/etc.)
├── configs/
│   ├── decypharr/config.json   # Decypharr config (TorBox API key, WebDAV)
│   ├── prowlarr/config.xml     # Pre-seeded API key & auth settings
│   ├── radarr/config.xml       # Pre-seeded API key & auth settings
│   ├── sonarr/config.xml       # Pre-seeded API key & auth settings
│   ├── seerr/
│   └── plex/ or jellyfin/
└── data/
    ├── media/
    │   ├── movies/              # Radarr root folder (symlinks to cloud files)
    │   └── tv/                  # Sonarr root folder (symlinks to cloud files)
    └── downloads/               # Decypharr symlinks landing zone
```

The project root also contains:
- `setup.sh` — Main installation and configuration script
- `uninstall.sh` — Clean removal script (stop containers, remove configs, systemd service)

---

## Accessing From Other Devices

By default, all services are bound to `127.0.0.1` (localhost only) — meaning only the computer running the server can access them. To let other devices on your network (phones, TVs, other computers) access your media server:

### Option 1: Edit Port Bindings (Simple)

Edit `docker-compose.yml` and change `127.0.0.1:PORT:PORT` to `0.0.0.0:PORT:PORT` (or just `PORT:PORT`) for the services you want to expose:

```yaml
# Before (localhost only):
ports:
  - "127.0.0.1:5055:5055"

# After (accessible from any device on your network):
ports:
  - "5055:5055"
```

Then restart: `./manage.sh restart`

By default **every** service — including Plex and Jellyfin — is bound to `127.0.0.1` (loopback) only. If you want other devices on your LAN to reach them, you must explicitly relax the binding for the chosen service.

> **Plex note:** To expose Plex on your LAN, change `"127.0.0.1:32400:32400"` to `"32400:32400"` in `docker-compose.yml`, then run `./manage.sh restart`. Plex will then be reachable at `http://YOUR-IP:32400/web`. The same applies to Jellyfin (`8096`) and Seerr (`5055`).

### Option 2: Reverse Proxy (Advanced)

For remote access outside your home network, use a reverse proxy like [Caddy](https://caddyserver.com/), [Nginx Proxy Manager](https://nginxproxymanager.com/), or [Traefik](https://traefik.io/). This provides HTTPS, custom domain names, and proper security for internet-facing services.

---

## Security Notes

- **Ports are bound to `127.0.0.1`** by default, preventing LAN/WAN exposure of admin UIs, including Plex and Jellyfin
- **Authentication is set to `Forms` with `Enabled`** automatically during setup. Secure admin credentials are auto-generated for Radarr, Sonarr, and Prowlarr, ensuring they are protected by default if you choose to expose them to your LAN
- **The `.env` file** contains your TorBox API key, admin credentials, and *arr API keys — it's `chmod 600` (owner-read only). Don't commit it to version control
- **Only Decypharr** gets `SYS_ADMIN` capability and FUSE access — other containers only read files via symlinks
- **Decypharr config is mounted read-only** — the config directory is bound as `:ro` to prevent containers from modifying their own configuration

> ⚠️ **Never expose Radarr, Sonarr, Prowlarr, or Decypharr admin UIs to the public internet** without authentication and a reverse proxy with HTTPS. Seerr is designed for this purpose and has its own authentication system.

---

## Updating

To update all services to their pinned versions:

```bash
cd torbox-media-server/
./manage.sh update
```

This pulls the pinned Docker image versions and restarts all containers. Your configuration and data are preserved.

> **Note:** Docker images are pinned to specific versions in `setup.sh` for reproducibility. To upgrade to newer versions, re-run `./setup.sh` which regenerates the Docker Compose file with updated image tags.

---

## Uninstalling

Run the uninstall script from the project root:

```bash
chmod +x uninstall.sh
./uninstall.sh
```

The script will:
1. Stop and remove all Docker containers and the network
2. Remove the systemd auto-start service
3. Remove the installation directory (configs, data, docker-compose, .env)
4. Unmount and remove the mount point
5. Optionally remove Docker images to free ~5–8 GB of disk space

You'll be asked to confirm before anything is removed. Your TorBox account and cloud-stored media are not affected.

> **Note:** This does not uninstall Docker itself. To reclaim all Docker disk space (including unrelated images), run `docker system prune -a`.

---

## Troubleshooting

### Mount not visible in Plex/Jellyfin

The setup script installs a systemd service that handles mount propagation automatically on boot. If it's not working:

1. Check that the systemd service is enabled and running:
   ```bash
   sudo systemctl status torbox-media-server
   ```
2. If it failed, restart it:
   ```bash
   sudo systemctl restart torbox-media-server
   ```
3. Or manually re-apply mount propagation:
   ```bash
   sudo mount --bind /mnt/torbox-media /mnt/torbox-media
   sudo mount --make-shared /mnt/torbox-media
   cd torbox-media-server/
   ./manage.sh restart
   ```

### Radarr/Sonarr says "download client not configured"

This means the API auto-configuration didn't run (e.g., you chose not to start services during setup, or a service wasn't ready in time). You can:

1. **Re-run the setup script** — it detects existing installations, preserves your API keys, and reconfigures
2. **Configure manually** in the service's web UI:

| Field | Value |
|-------|-------|
| Client | qBittorrent |
| Host | `decypharr` |
| Port | `8282` |
| Username | `http://radarr:7878` (for Radarr) or `http://sonarr:8989` (for Sonarr) |
| Password | The service's API key (Settings → General → API Key) |
| Category | `radarr` or `sonarr` |
| Root Folder | `/data/media/movies` (for Radarr) or `/data/media/tv` (for Sonarr) |

### Media management / naming not configured

If jq wasn't available during setup, advanced configuration (naming conventions, media management, quality profiles) is skipped. You can:

1. Install jq and re-run `./setup.sh`
2. Configure manually:
   - **Media Management** → Disable "Use Hardlinks instead of Copy" (**critical** for debrid setups!)
   - **Media Management** → Enable "Import Extra Files" with extensions: `srt,sub,idx,ass,ssa,nfo`
   - **Naming** → Enable renaming with your preferred format
   - **Profiles** → Check "Upgrades Allowed" on your quality profiles

### First request takes a long time

TorBox works best with popular content that's already cached. If you request something niche:
- TorBox may need to actually download the torrent, which can take minutes to hours depending on seeders
- Check the progress in Radarr/Sonarr → Activity → Queue
- Check your TorBox dashboard at [torbox.app](https://torbox.app) to see download progress

For popular movies and TV shows, content is usually available within seconds.

### TorBox rate limit errors (429)

TorBox's API has a limit of 60 requests per hour. If you request a full TV season at once, Sonarr may try to grab many episodes rapidly and exhaust this limit. The setup script configures Decypharr with `rate_limit: "55/hour"` to stay within bounds, but if you see `HTTP error 429: {"detail":"60 per 1 hour"}`:

- Wait an hour for the limit to reset — queued grabs will retry automatically
- Avoid requesting multiple full seasons simultaneously
- Check your Decypharr config (`configs/decypharr/config.json`) and ensure `rate_limit` is set to `"55/hour"` or lower

### Byparr not solving Cloudflare challenges

Some sites have advanced protections that no automated solver can bypass. Try:
- Using indexers that don't require Cloudflare bypass
- Checking if Byparr needs an update: `./manage.sh update`

### Services not accessible from other devices

Ports are bound to `127.0.0.1` by default. See [Accessing From Other Devices](#accessing-from-other-devices) above.

### "Seerr can't connect to Radarr/Sonarr"

Make sure you're using **container names** (`radarr`, `sonarr`) as the hostname in Seerr, NOT `localhost`. All services communicate using Docker's internal network where each container is reachable by its service name.

### "Seerr can't find/connect to Plex"

Plex and Seerr are on the same Docker bridge network. Use the internal container URL:
```
http://plex:32400
```
If this doesn't work, check that both containers are running (`./manage.sh status`) and on the same network (`docker network inspect torbox-media-server_media-network`).

### How do I find my API keys?

Use the management script:
```bash
cd torbox-media-server/
./manage.sh keys
```

Or view a specific service's API key in its web UI: Settings → General → API Key.

### Services take a long time to start

On the first run, Docker pulls all container images (~5–8 GB total) which can take several minutes depending on your internet speed. Subsequent starts are fast (~10 seconds). The setup script waits up to 90 seconds per service for initialization.

### Prowlarr shows "Applications unavailable"

This usually means Radarr or Sonarr hasn't finished starting yet. Wait a minute and refresh. If the problem persists:
1. Go to **Settings → Apps**
2. Click the problematic app (Radarr or Sonarr)
3. Click **Test** — if it fails, verify the URL and API key are correct
4. The internal URLs should be `http://radarr:7878` and `http://sonarr:8989`

---

## Design Decisions

- **Seerr** instead of Overseerr — Overseerr was archived in 2024; Seerr is the merged successor supporting Plex, Jellyfin, and Emby
- **Byparr** instead of FlareSolverr — FlareSolverr is currently non-functional (Cloudflare detects it); Byparr is a drop-in replacement using the same API
- **Only Decypharr gets FUSE/SYS_ADMIN** — Plex/Jellyfin/Radarr/Sonarr only read files, they don't need elevated privileges
- **Plex on bridge networking** — Plex runs on the same Docker bridge network as all other services, allowing Seerr to connect via container name (`http://plex:32400`). Host networking was avoided because many Linux firewalls (UFW, firewalld) block traffic from Docker bridge containers to the host, causing Seerr ↔ Plex connectivity failures
- **Plex notifications on Radarr/Sonarr** — triggers an instant Plex library scan when content is imported, upgraded, or deleted, so new media appears in seconds instead of waiting for Plex's periodic scan interval
- **Ports bound to localhost** — prevents accidental LAN/WAN exposure of admin UIs, including Plex and Jellyfin
- **Mount propagation** — uses `rshared` on Decypharr (the mount source) and `rslave` on media servers (consumers); a systemd service (`torbox-media-server`) handles this automatically on boot, and `manage.sh` re-applies it as a safety net
- **Hardlinks disabled** — debrid setups use symlinks from Decypharr's WebDAV mount, not local files; hardlinks would fail
- **Systemd auto-start** — a `torbox-media-server.service` unit handles mount propagation and container startup on boot, so users never have to manually start services after a reboot
- **Auto-configured Auth** — the setup script pre-seeds `Forms` auth with `Enabled` from first boot, then uses the API key to programmatically set admin credentials — no unauthenticated window
- **Pre-seeded API keys** — generated during setup and injected into config.xml before containers start, enabling fully automated API-based configuration
- **jq for JSON manipulation** — used to modify *arr config via API; auto-installed as a dependency
- **Quality profile upgrades enabled** — without this, Radarr/Sonarr won't replace a 720p version with a 1080p one; most users want automatic upgrades
- **Docker images pinned to specific versions** — avoids breakage from upstream changes; re-run `setup.sh` to pick up newer versions intentionally
- **Decypharr config mounted read-only** — config.json is bind-mounted as `:ro` to prevent containers from accidentally modifying it
- **Decypharr credentials pre-seeded** — generated during setup and injected into config.json, eliminating manual credential creation

---

## Glossary

New to this? Here's what the key terms mean:

| Term | Meaning |
|------|----------|
| **Debrid** | A cloud downloading service (like TorBox) that downloads torrents for you in the cloud. You stream the files instead of downloading them locally. |
| **Indexer** | A torrent search site (like 1337x). Prowlarr manages your indexers and searches them when Radarr/Sonarr need content. |
| **Quality Profile** | A set of rules for what video quality to accept (e.g., "only 1080p or higher"). Used by Radarr/Sonarr when choosing which torrent to grab. |
| **Root Folder** | The base directory where Radarr/Sonarr store media (e.g., `/movies` or `/tv`). Each movie/show gets its own subfolder. |
| **Symlink** | A "shortcut" file that points to another file. Decypharr creates symlinks that point to TorBox's cloud-mounted files, so Plex/Jellyfin can find them. |
| **Hardlink** | A direct reference to file data on the same filesystem. Doesn't work with cloud mounts, which is why the setup disables them. |
| **WebDAV** | A protocol for accessing remote files over the internet, like a network drive. TorBox exposes your downloaded files via WebDAV. |
| **FUSE** | "Filesystem in Userspace" — lets rclone mount TorBox's WebDAV as if it were a local drive. |
| **Mount Propagation** | A Linux kernel feature that lets one container's mounted drives be visible to other containers. Needed so Plex/Jellyfin can see Decypharr's WebDAV mount. |
| **rclone** | A tool that mounts cloud storage (like TorBox's WebDAV) as a local filesystem. Built into Decypharr. |
| **Claim Token** | A one-time code from Plex that links a new Plex server to your Plex account. Expires after 4 minutes. |
| **API Key** | A secret password that services use to talk to each other. The setup script generates these automatically. |
| ***arr suite** | Collective name for the automation apps built around the Servarr project: Radarr, Sonarr, Prowlarr, etc. |

---

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on submitting issues, bug reports, and pull requests.

---

## License

MIT — see [LICENSE](LICENSE) for details.
