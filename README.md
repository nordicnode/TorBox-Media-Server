# TorBox Media Server — All-in-One Setup

A single script that installs, configures, and runs a complete debrid-powered media server using Docker. **No media is stored locally** — everything streams from [TorBox](https://torbox.app).

## What Is This?

Imagine having your own personal Netflix, where **you** decide what's available. Instead of downloading movies and TV shows to your computer, a cloud service called [TorBox](https://torbox.app) handles all the downloading and storage for you. Your media server then streams directly from TorBox's cloud — no large hard drives needed, no waiting for downloads, no storage management.

This setup script builds that entire system for you automatically. It connects several open-source tools together so that when you search for a movie or TV show, it gets found, downloaded in the cloud, and made available to stream on any device in your home — all within seconds for popular content.

**In short:** You request → TorBox finds & stores → You stream. Zero local storage.

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

> **Note:** All service ports except Plex are bound to `127.0.0.1` (localhost only) by default for security. Plex binds to all interfaces (`0.0.0.0:32400`) so other devices on your LAN can stream. See [Accessing From Other Devices](#accessing-from-other-devices) to open access for other services.

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
| **python3** | JSON manipulation for advanced auto-configuration | Not installed by script* |

\* If python3 is not present, the script still works — it just skips advanced configuration (media management, naming, quality profiles) and you'd configure those manually. Python3 is pre-installed on most Linux distributions.

## Quick Start

```bash
git clone https://github.com/nordicnode/TorBox-Media-Server.git && cd TorBox-Media-Server
chmod +x setup.sh
./setup.sh
```

For unattended/automated installs, use `--yes` mode with environment variables:

```bash
TORBOX_API_KEY="your-api-key" TORBOX_MEDIA_SERVER="plex" ./setup.sh --yes
```

Run `./setup.sh --help` for all available options.

The script will interactively ask you for:

| Prompt | What to enter |
|---|---|
| **TorBox API key** | Paste the API key from your [TorBox settings](https://torbox.app/settings) |
| **Plex or Jellyfin** | Choose `1` for Plex or `2` for Jellyfin |
| **Plex claim token** | (Plex only) Paste your claim token, or press Enter to skip |
| **Hardware acceleration** | Auto-detected; only prompted if both Intel and NVIDIA GPUs are present |
| **Start services?** | Press Enter or `Y` to start immediately (recommended) |

> **Auto-detected values:** Mount directory (`/mnt/torbox-media`), user/group IDs, timezone, and hardware acceleration are auto-detected. Override via env vars: `TORBOX_MOUNT_DIR`, `TORBOX_HW_ACCEL`.

Then the script automatically:

1. Checks and installs dependencies (Docker, FUSE)
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

## What the Script Configures Automatically

The setup script pre-seeds and auto-configures as much as possible so you don't have to. Here's exactly what's handled for you:

### Pre-Seeded (via config.xml, before containers start)

| Setting | Value | Why |
|---------|-------|-----|
| API keys | Random 32-char hex keys for Radarr, Sonarr, Prowlarr | Enables API auto-configuration on first launch |
| Authentication | `DisabledForLocalAddresses` | Allows API calls to work without credentials on first launch |
| Decypharr config | TorBox API key, WebDAV mount, rclone mount, symlink paths | Connects to your TorBox account and enables rclone FUSE mounting |
| Systemd service | `torbox-media-server.service` | Auto-starts mount propagation + containers on boot |

### Auto-Configured via API (after containers start)

| Service | Setting | Value |
|---------|---------|-------|
| **Radarr** | Download client | Decypharr (as qBittorrent mock) on `decypharr:8282` |
| **Radarr** | Root folder | `/data/media/movies` |
| **Radarr** | Hardlinks | Disabled (required — debrid uses symlinks, not local files) |
| **Radarr** | Movie renaming | Enabled: `{Movie CleanTitle} ({Release Year}) [{Quality Full}]` |
| **Radarr** | Movie folder format | `{Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]` |
| **Radarr** | Colon replacement | Dash (`-`) for filesystem safety |
| **Radarr** | Subtitle/extras import | Enabled (srt, sub, idx, ass, ssa, nfo) |
| **Radarr** | Quality profiles | Upgrades enabled on all default profiles |
| **Radarr** | Recycle bin | Disabled (no local storage to recycle) |
| **Radarr** | Min free space on import | 100 MB |
| **Sonarr** | Download client | Decypharr (as qBittorrent mock) on `decypharr:8282` |
| **Sonarr** | Root folder | `/data/media/tv` |
| **Sonarr** | Hardlinks | Disabled (required — debrid uses symlinks, not local files) |
| **Sonarr** | Episode renaming | Enabled: `{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]` |
| **Sonarr** | Series folder format | `{Series TitleYear}` |
| **Sonarr** | Season folder format | `Season {season:00}` |
| **Sonarr** | Colon replacement | Smart replacement (mode 4) |
| **Sonarr** | Subtitle/extras import | Enabled (srt, sub, idx, ass, ssa, nfo) |
| **Sonarr** | Quality profiles | Upgrades enabled on all default profiles |
| **Sonarr** | Recycle bin | Disabled (no local storage to recycle) |
| **Sonarr** | Min free space on import | 100 MB |
| **Prowlarr** | Byparr proxy | `http://byparr:8191` (Cloudflare bypass) |
| **Prowlarr** | Radarr app | Connected with API key, full sync, movie categories |
| **Prowlarr** | Sonarr app | Connected with API key, full sync, TV categories |
| **Radarr** | Plex notification | Triggers instant Plex library scan on import/upgrade/delete (Plex only) |
| **Sonarr** | Plex notification | Triggers instant Plex library scan on import/upgrade/delete (Plex only) |
| **Prowlarr** | Default indexer | 1337x pre-added as a public torrent indexer |
| **Seerr** | Radarr connection | Pre-configured with Radarr hostname, port, and API key |
| **Seerr** | Sonarr connection | Pre-configured with Sonarr hostname, port, and API key |
| **Seerr** | Plex/Jellyfin | Pre-configured with media server connection |
| **Plex** | Libraries | Movies + TV Shows libraries auto-added (requires claim token) |

### File Naming Examples

Here's what your media library will look like on disk after the naming conventions are applied:

**Movies (Radarr):**
```
/data/media/movies/
├── Inception (2010) [imdbid-tt1375666]/
│   └── Inception (2010) [Bluray-1080p].mkv
├── The Dark Knight (2008) [imdbid-tt0468569]/
│   ├── The Dark Knight (2008) [Bluray-2160p].mkv
│   └── The Dark Knight (2008) [Bluray-2160p].srt
└── Dune - Part Two (2024) [imdbid-tt15239678]/
    └── Dune - Part Two (2024) [WEBDL-1080p Proper].mkv
```

**TV Shows (Sonarr):**
```
/data/media/tv/
├── Breaking Bad (2008)/
│   ├── Season 01/
│   │   ├── Breaking Bad (2008) - S01E01 - Pilot [Bluray-1080p].mkv
│   │   ├── Breaking Bad (2008) - S01E02 - Cat's in the Bag... [Bluray-1080p].mkv
│   │   └── ...
│   └── Season 02/
│       └── ...
└── The Last of Us (2023)/
    └── Season 01/
        ├── The Last of Us (2023) - S01E01 - When You're Lost in the Darkness [WEBDL-2160p].mkv
        └── ...
```

Note that colons in titles (like "Mission: Impossible") are automatically replaced with dashes for filesystem compatibility.

## Post-Install Walkthrough

After the script finishes, only a few manual steps remain. Follow these in order.

> **Important — Docker Networking:**
> When connecting services **to each other** (e.g., Seerr → Radarr), use the **container name** as the hostname (e.g., `radarr`, `sonarr`, `prowlarr`). When accessing services **in your browser**, use `http://localhost:PORT`. This is because containers talk to each other on an internal Docker network, not through your computer's localhost.

---

### Step 1: Verify Decypharr (~5 minutes)

Decypharr is the critical bridge between your media managers and TorBox. **Nothing else works if Decypharr isn't set up correctly**, so do this first.

1. Open **http://localhost:8282** in your browser
2. On first launch, you'll see a setup page — create your Decypharr credentials (username & password)
3. After logging in, verify the pre-configured settings:
   - **Debrid** tab: TorBox API key should be shown ✓, Rclone Folder set to `/mnt/remote/torbox/__all__` ✓, WebDAV enabled ✓
   - **Rclone** tab: Mount should be **enabled** ✓, mount path `/mnt/remote` ✓
   - All of the above are pre-configured by the setup script — just verify they look correct
4. Click **Save** if you made any changes

**✅ What success looks like:** The Debrid tab shows your API key, WebDAV is enabled, and the Rclone tab shows the mount as active.

---

### Step 2: Set Up Prowlarr Indexers (~5 minutes)

Prowlarr manages your torrent indexers (the sites where torrents are found). The script already connected Byparr, Radarr, and Sonarr — you just need to add indexer sites.

1. Open **http://localhost:9696**
2. **Set up authentication first** (important!):
   - Go to **Settings → General**
   - Under **Authentication**, select **Forms (Login Page)**
   - Enter a **username** and **password**
   - Click **Save Changes** at the top

   > ⚠️ Authentication is disabled for local addresses by default to allow the setup script's API calls to work. You should enable it now for security.

3. Go to **Indexers → Add Indexer** (the `+` button)
4. Search for and add torrent indexers you want to use. Some popular public options:
   - **1337x** — General purpose, large catalog
   - **EZTV** — Specializes in TV shows
   - **TorrentGalaxy** — General purpose
   - **LimeTorrents** — Movies and TV shows
   - **Nyaa** — Anime

   For each indexer, just search its name, click it, and click **Save**. Most work with default settings.

5. (Optional) Verify Radarr and Sonarr connections:
   - Go to **Settings → Apps** — you should see Radarr and Sonarr already listed with green checkmarks

**✅ What success looks like:** Indexers page shows your added sites with green status icons. Settings → Apps shows Radarr and Sonarr connected.

> **Tip:** If an indexer is behind Cloudflare, the Byparr proxy handles it automatically — no extra configuration needed.

---

### Step 3: Verify Radarr (~2 minutes)

Radarr manages your movie library. The script already configured everything — you just need to set up authentication and verify.

1. Open **http://localhost:7878**
2. **Set up authentication:**
   - Go to **Settings → General**
   - Under **Security**, set Authentication to **Forms (Login Page)**
   - Enter a **username** and **password**
   - Click **Save Changes**
3. Verify the auto-configuration worked:
   - **Settings → Download Clients** → you should see **Decypharr** listed
   - **Settings → Media Management** → Root Folders should show `/data/media/movies`
   - **Settings → Media Management** → "Use Hardlinks instead of Copy" should be **OFF** ✓
   - **Settings → Media Management** → "Import Extra Files" should be **ON** ✓
   - **Settings → Media Management** → Movie Naming should be **ON** ✓
   - **Settings → Profiles** → all profiles should have "Upgrades Allowed" checked ✓
4. (Optional) Choose your preferred default quality profile:
   - When you add movies later, you'll choose a quality profile. "HD-1080p" is a good default for most people.

**✅ What success looks like:** No orange/red warnings on the System page. Download client shows a green icon. Root folder shows `/data/media/movies` with no errors.

---

### Step 4: Verify Sonarr (~2 minutes)

Sonarr manages your TV show library. Same auto-configuration as Radarr.

1. Open **http://localhost:8989**
2. **Set up authentication:**
   - Go to **Settings → General**
   - Under **Security**, set Authentication to **Forms (Login Page)**
   - Enter a **username** and **password**
   - Click **Save Changes**
3. Verify the auto-configuration worked:
   - **Settings → Download Clients** → you should see **Decypharr** listed
   - **Settings → Media Management** → Root Folders should show `/data/media/tv`
   - **Settings → Media Management** → "Use Hardlinks instead of Copy" should be **OFF** ✓
   - **Settings → Media Management** → "Import Extra Files" should be **ON** ✓
   - **Settings → Media Management** → Episode Naming should be **ON** ✓
   - **Settings → Profiles** → all profiles should have "Upgrades Allowed" checked ✓

**✅ What success looks like:** Same as Radarr — no warnings, green icons on download client and root folder `/data/media/tv`.

---

### Step 5: Set Up Your Media Server (~5 minutes)

#### If you chose Plex:

1. Open **http://localhost:32400/web**
2. Sign in with your Plex account
   - If you provided a claim token during setup, the server should already be claimed
   - If not, you'll be prompted to claim it now
3. Complete the initial setup wizard:
   - Give your server a name
   - Skip the "Add Library" step for now (we'll do it properly next)
4. After the wizard, go to **Settings → Libraries → Add Library**:
   - Click **Add Library** → **Movies** → Add folder → browse to `/data/media/movies` → **Add Library**
   - Click **Add Library** → **TV Shows** → Add folder → browse to `/data/media/tv` → **Add Library**
5. Recommended settings:
   - **Settings → Library** → Disable "Scan my library automatically" (Decypharr handles file availability)
   - Leave "Run a partial scan when changes are detected" enabled

**✅ What success looks like:** Your Plex dashboard shows the Movies and TV Shows libraries (they'll be empty until you add content).

#### If you chose Jellyfin:

1. Open **http://localhost:8096**
2. Complete the initial setup wizard:
   - Choose your language
   - Create an **admin account** (username and password)
   - Add libraries when prompted:
     - **Movies** → Content type: Movies → Add folder → enter `/data/media/movies`
     - **TV Shows** → Content type: Shows → Add folder → enter `/data/media/tv`
   - Configure metadata language (your preference)
   - Finish the wizard

**✅ What success looks like:** Your Jellyfin dashboard shows the Movies and TV Shows libraries (they'll be empty until you add content).

---

### Step 6: Set Up Seerr (~5 minutes)

Seerr provides a beautiful frontend where you (and optionally your family/friends) can browse and request movies and TV shows.

> **Remember:** When entering server addresses inside Seerr, use **container names** (like `radarr`) not `localhost`, because Seerr connects to other services through Docker's internal network.

1. Open **http://localhost:5055**
2. Sign in:
   - **Plex users:** Click "Sign In with Plex" and authorize with your Plex account, then select your Plex server from the list.
     > When prompted for the Plex server URL, use `http://plex:32400` — Plex and Seerr are on the same Docker network, so the container name works directly.
   - **Jellyfin users:** Click "Use Jellyfin" → enter your Jellyfin server URL as `http://jellyfin:8096` → sign in with your Jellyfin admin credentials
3. Add **Radarr** (movies):
   - Click **Add Radarr Server**
   - **Default Server:** ✅ (check this)
   - **Server Name:** `Radarr`
   - **Hostname or IP Address:** `radarr` ← (container name, NOT localhost!)
   - **Port:** `7878`
   - **API Key:** *(your Radarr API key — see below how to find it)*
   - Click **Test** — you should see a green checkmark
   - Select a **Quality Profile** (e.g., "HD-1080p")
   - Select a **Root Folder** (`/data/media/movies`)
   - Click **Add Server**
4. Add **Sonarr** (TV shows):
   - Click **Add Sonarr Server**
   - **Default Server:** ✅ (check this)
   - **Server Name:** `Sonarr`
   - **Hostname or IP Address:** `sonarr` ← (container name, NOT localhost!)
   - **Port:** `8989`
   - **API Key:** *(your Sonarr API key — see below how to find it)*
   - Click **Test** — you should see a green checkmark
   - Select a **Quality Profile** (e.g., "HD-1080p")
   - Select a **Root Folder** (`/data/media/tv`)
   - Click **Add Server**
5. Click **Finish Setup**

> **Finding your API keys:** The setup script printed them at the end, and they're stored in the `.env` file:
> ```bash
> grep API_KEY torbox-media-server/.env
> ```
> You can also find each service's API key in its web UI: **Settings → General → API Key**.

**✅ What success looks like:** Seerr's main page shows a search bar and "Discover" section with trending movies and shows.

---

### Step 7: Test the Full Flow (~2 minutes)

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

> **Note:** The first request may take a moment as services warm up. If TorBox doesn't have the content cached (rare for popular titles), it may take a few minutes to download in the cloud. You'll see the progress in Radarr's Activity tab.

🎉 **Congratulations!** Your personal streaming server is fully operational.

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
>
> Use `./manage.sh` for manual control when needed. The management script also re-applies mount propagation as a safety net.

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

For most users, your media server (Plex or Jellyfin) is already accessible on your network. You only need to do this if you want to expose **Seerr** so family and friends can request content.

> **Plex note:** Plex exposes port 32400 on all interfaces by default, so it's accessible on your network at `http://YOUR-IP:32400/web`. To restrict it to localhost only, change `"32400:32400"` to `"127.0.0.1:32400:32400"` in `docker-compose.yml`.

### Option 2: Reverse Proxy (Advanced)

For remote access outside your home network, use a reverse proxy like [Caddy](https://caddyserver.com/), [Nginx Proxy Manager](https://nginxproxymanager.com/), or [Traefik](https://traefik.io/). This provides HTTPS, custom domain names, and proper security for internet-facing services.

## Security Notes

- **Ports are bound to `127.0.0.1`** by default, preventing LAN/WAN exposure of admin UIs
- **Authentication is set to `DisabledForLocalAddresses`** after setup to allow API auto-configuration — **you should enable full authentication** in each service's Settings → General → Authentication after the initial setup (see Steps 2–4 in the walkthrough above)
- **The `.env` file** contains your TorBox API key and *arr API keys — it's `chmod 600` (owner-read only). Don't commit it to version control
- **Only Decypharr** gets `SYS_ADMIN` capability and FUSE access — other containers only read files via symlinks
- **Decypharr config is mounted read-only** — the config directory is bound as `:ro` to prevent containers from modifying their own configuration

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

If python3 wasn't available during setup, advanced configuration (naming conventions, media management, quality profiles) is skipped. You can:

1. Install python3 and re-run `./setup.sh`
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

Make sure you're using **container names** (`radarr`, `sonarr`) as the hostname in Seerr, NOT `localhost`. See the Docker networking note at the top of the [Post-Install Walkthrough](#post-install-walkthrough).

### "Seerr can't find/connect to Plex"

Plex and Seerr are on the same Docker bridge network (`media-network`), so use the container name:
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

## Design Decisions

- **Seerr** instead of Overseerr — Overseerr was archived in 2024; Seerr is the merged successor supporting Plex, Jellyfin, and Emby
- **Byparr** instead of FlareSolverr — FlareSolverr is currently non-functional (Cloudflare detects it); Byparr is a drop-in replacement using the same API
- **Only Decypharr gets FUSE/SYS_ADMIN** — Plex/Jellyfin/Radarr/Sonarr only read files, they don't need elevated privileges
- **Plex on bridge networking** — Plex runs on the same Docker bridge network as all other services, allowing Seerr to connect via container name (`http://plex:32400`). Port 32400 is exposed on all interfaces for LAN streaming. Host networking was avoided because many Linux firewalls (UFW, firewalld) block traffic from Docker bridge containers to the host, causing Seerr <-> Plex connectivity failures
- **Plex notifications on Radarr/Sonarr** — triggers an instant Plex library scan when content is imported, upgraded, or deleted, so new media appears in seconds instead of waiting for Plex's periodic scan interval
- **Ports bound to localhost** — prevents accidental LAN/WAN exposure of admin UIs
- **Mount propagation** — uses `rshared` on Decypharr (the mount source) and `rslave` on media servers (consumers); a systemd service (`torbox-media-server`) handles this automatically on boot, and `manage.sh` re-applies it as a safety net
- **Hardlinks disabled** — debrid setups use symlinks from Decypharr's WebDAV mount, not local files; hardlinks would fail
- **Systemd auto-start** — a `torbox-media-server.service` unit handles mount propagation and container startup on boot, so users never have to manually start services after a reboot
- **`DisabledForLocalAddresses` auth** — allows the setup script's API calls to configure services on first launch without requiring credentials; users should enable full auth afterward
- **Pre-seeded API keys** — generated during setup and injected into config.xml before containers start, enabling fully automated API-based configuration
- **python3 for JSON manipulation** — used to GET/modify/PUT *arr config endpoints; gracefully skipped if not installed
- **Quality profile upgrades enabled** — without this, Radarr/Sonarr won't replace a 720p version with a 1080p one; most users want automatic upgrades
- **Docker images pinned to specific versions** — avoids breakage from upstream changes; re-run `setup.sh` to pick up newer versions intentionally
- **Decypharr config mounted read-only** — prevents containers from accidentally modifying their own configuration

## Updating

To update all services to their pinned versions:

```bash
cd torbox-media-server/
./manage.sh update
```

This pulls the pinned Docker image versions and restarts all containers. Your configuration and data are preserved.

> **Note:** Docker images are pinned to specific versions in `setup.sh` for reproducibility. To upgrade to newer versions, re-run `./setup.sh` which regenerates the Docker Compose file with updated image tags.

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

## Glossary

New to this? Here's what the key terms mean:

| Term | Meaning |
|------|---------|
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

## License

MIT
