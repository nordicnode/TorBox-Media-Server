#!/usr/bin/env bash
set -euo pipefail
set -o errtrace
trap 'echo -e "\n\033[0;31m[ERROR] Unexpected error at line $LINENO in command: $BASH_COMMAND\033[0m"' ERR

# ============================================================================
#  TorBox Media Server - All-in-One Setup Script
#  Automated setup for a debrid-powered media server using Docker
#
#  Components: Prowlarr, Byparr, Decypharr, Seerr,
#              Radarr, Sonarr, rclone/FUSE mount, Plex or Jellyfin
#
#  Designed for CachyOS (Arch-based) but works on most Linux distros.
# ============================================================================

VERSION="1.1.0"
DRY_RUN=false
SERVICES_STARTED=false
NON_INTERACTIVE=false
SPINNER_PID=""

# Tracks any temp file created by run_with_spinner so the interrupt handler can clean it up.
SPINNER_TMPFILE=""

trap 'cleanup_on_interrupt' INT TERM

cleanup_on_interrupt() {
    echo ""
    # Kill any background process started by run_with_spinner
    if [[ -n "${SPINNER_PID:-}" ]]; then
        # Try SIGTERM first to allow the background process to clean up, then SIGKILL
        kill -TERM "${SPINNER_PID}" 2>/dev/null || true
        sleep 0.2
        kill -9 "${SPINNER_PID}" 2>/dev/null || true
    fi
    # Remove any leftover spinner temp file from an in-flight background command
    if [[ -n "${SPINNER_TMPFILE:-}" && -e "${SPINNER_TMPFILE}" ]]; then
        rm -f "${SPINNER_TMPFILE}"
    fi
    # If containers were already started, stop them BEFORE deleting files to
    # avoid leaving containers with stale bind mounts pointing at deleted paths.
    if [[ "${SERVICES_STARTED:-}" == "true" && -f "${COMPOSE_FILE:-}" && -f "${ENV_FILE:-}" ]]; then
        log_warn "Stopping containers before cleanup..."
        if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
            detect_compose_cmd
        fi
        (cd "${INSTALL_DIR}" && "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" down --remove-orphans) 2>/dev/null || true
    fi
    # If setup never completed (.env not written), remove partial installation
    if [[ ! -f "${ENV_FILE:-}" && -d "${INSTALL_DIR:-}" ]]; then
        log_warn "Setup interrupted before completion. Cleaning up partial installation..."
        rm -rf "${INSTALL_DIR:-}"
        log_info "Partial installation removed. Re-run setup.sh to start fresh."
    elif [[ -f "${ENV_FILE:-}" && ! -f "${SETUP_COMPLETE_FILE:-}" ]]; then
        # .env exists but setup_complete doesn't — install was interrupted mid-config
        log_warn "Setup interrupted during configuration. Cleaning up incomplete installation..."
        rm -rf "${INSTALL_DIR:-}"
        log_info "Incomplete installation removed. Re-run setup.sh to start fresh."
    else
        log_warn "Setup interrupted. Re-run to continue where you left off."
    fi
    exit 130
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}"
CONFIG_DIR="${INSTALL_DIR}/configs"
DATA_DIR="${INSTALL_DIR}/data"
MOUNT_DIR="/mnt/torbox-media"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SETUP_COMPLETE_FILE="${INSTALL_DIR}/.setup_complete"

# Source .env variables into the current shell (for SYNC_AUTH_ONLY mode).
# Only reads values that are NOT already set, so it won't override explicit env vars.
load_env_if_present() {
    if [[ -f "${ENV_FILE}" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
        set +a
    fi
}

# Docker image versions are pinned directly in docker-compose.yml.

# Generate deterministic-length API keys (32-char hex, matching *arr format)
generate_api_key() {
    local key=""
    # Try each generator, capturing only on success
    if key=$(openssl rand -hex 16 2>/dev/null); then
        :
    elif key=$(xxd -p -l 16 /dev/urandom 2>/dev/null); then
        :
    elif key=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \t\n'); then
        :
    elif key=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \t\n'); then
        :
    else
        echo ""
        return 1
    fi
    # Normalize: lowercase, strip non-hex, take first 32 chars
    key=$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-f0-9' | head -c 32)
    if [[ ${#key} -ne 32 ]]; then
        echo ""
        return 1
    fi
    echo "$key"
}

# Generate secure random admin passwords (32 chars, ~192 bits entropy)
_gen_admin_pass() {
    local p=""
    if p=$(openssl rand -base64 32 2>/dev/null | tr -d '/+=' | head -c 32); then
        :
    elif p=$(head -c 32 /dev/urandom 2>/dev/null | base64 | tr -d '/+=' | head -c 32); then
        :
    fi
    echo "$p"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    cat <<'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║           TorBox Media Server - All-in-One Setup            ║
  ║                                                             ║
  ║   Prowlarr · Byparr · Decypharr · Seerr                    ║
  ║   Radarr · Sonarr · rclone/FUSE · Plex/Jellyfin            ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} ${BOLD}$*${NC}" >&2; }
log_section() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${CYAN}  $*${NC}" >&2
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}
mask_key() {
    local k="$1"
    if [[ ${#k} -gt 4 ]]; then echo "${k:0:4}...${k: -4}"; else echo "$k"; fi
}

# Service port registry (single source of truth for all port/label references)
SVC_ORDER=(decypharr prowlarr byparr radarr sonarr seerr)
declare -A SVC_PORTS=(
    [decypharr]=8282 [prowlarr]=9696 [byparr]=8191
    [radarr]=7878 [sonarr]=8989 [seerr]=5055
)
declare -A SVC_LABELS=(
    [decypharr]="Decypharr" [prowlarr]="Prowlarr" [byparr]="Byparr"
    [radarr]="Radarr" [sonarr]="Sonarr" [seerr]="Seerr"
)

print_service_urls() {
    local svc
    for svc in "${SVC_ORDER[@]}"; do
        printf "  %b%-14s%b http://localhost:%s\n" "$BOLD" "${SVC_LABELS[$svc]}" "$NC" "${SVC_PORTS[$svc]}"
    done
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        printf "  %b%-14s%b http://localhost:32400/web\n" "$BOLD" "Plex" "$NC"
    else
        printf "  %b%-14s%b http://localhost:8096\n" "$BOLD" "Jellyfin" "$NC"
    fi
}

# Run a command in the background with a spinner animation
run_with_spinner() {
    local msg="$1"
    shift
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local tmpfile
    tmpfile=$(mktemp /tmp/torbox-setup.XXXXXX)
    SPINNER_TMPFILE="$tmpfile" # exposed to cleanup_on_interrupt trap
    "$@" >"$tmpfile" 2>&1 &
    local pid=$! i=0
    SPINNER_PID="$pid"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %s %s" "${spin_chars:i%${#spin_chars}:1}" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    local rc=0
    wait "$pid" && rc=0 || rc=$?
    printf "\r  %-$((${#msg} + 4))s\r" ""
    if [[ $rc -ne 0 ]]; then cat "$tmpfile" >&2; fi
    rm -f "$tmpfile"
    SPINNER_TMPFILE=""
    SPINNER_PID=""
    return "$rc"
}

# Detect the correct docker compose command and store in COMPOSE_CMD array
COMPOSE_CMD=()
_COMPOSE_SUDO_WARNED=false
detect_compose_cmd() {
    if docker info &>/dev/null; then
        COMPOSE_CMD=(docker compose)
    else
        if [[ "$_COMPOSE_SUDO_WARNED" != "true" ]]; then
            log_warn "Docker socket not accessible in current shell — using sudo."
            _COMPOSE_SUDO_WARNED=true
        fi
        COMPOSE_CMD=(sudo docker compose)
    fi
}

# Run a docker compose command with correct env-file and compose-file
compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    # CD into directory so Docker auto-discovers both docker-compose.yml and docker-compose.override.yml
    (cd "${INSTALL_DIR}" && exec "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}

# ============================================================================
#  Dependency Checks
# ============================================================================

check_dependencies() {
    log_section "Checking Dependencies"

    local _warn_only="${1:-}"
    local missing=()

    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if docker compose version &>/dev/null; then
        log_info "Docker Compose: using v2 plugin (docker compose)."
    else
        missing+=("docker-compose")
    fi

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v openssl &>/dev/null; then
        missing+=("openssl")
    fi

    # timedatectl is optional — only used to auto-detect the host's timezone.
    # On non-systemd systems we fall back to TZ=UTC (or the host's $TZ env var).
    if ! command -v timedatectl &>/dev/null; then
        log_warn "timedatectl not found; will default timezone to \${TZ:-UTC}."
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
        if [[ "$_warn_only" == "--warn-only" ]]; then
            # Dry-run mode: do not install anything, just report.
            log_warn "--dry-run mode: dependencies will not be installed automatically."
            log_warn "Re-run without --dry-run to install them."
            return 0
        fi
        local install_deps="y"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Install missing dependencies automatically? [Y/n]: " install_deps
        fi
        if [[ "${install_deps,,}" != "n" ]]; then
            install_dependencies "${missing[@]}"
        else
            log_error "Cannot continue without: ${missing[*]}"
            exit 1
        fi
    else
        log_info "All dependencies satisfied."
    fi

    # In dry-run mode, skip the Docker daemon check and group checks — they
    # would start the daemon, modify group membership, or load kernel modules.
    if [[ "$_warn_only" == "--warn-only" ]]; then
        return 0
    fi

    # Ensure docker daemon is running (distinguish permission errors from daemon-down)
    if ! docker info &>/dev/null; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            log_warn "Docker is running but current user lacks permission."
        else
            log_warn "Docker daemon is not running. Starting it..."
            sudo systemctl start docker 2>/dev/null || true
            sudo systemctl enable docker 2>/dev/null || true
            # Wait for Docker daemon to be ready (up to 15 seconds)
            local docker_wait=0
            local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            while [[ $docker_wait -lt 15 ]]; do
                if sudo docker info &>/dev/null; then
                    printf "\r  %-50s\r" ""
                    break
                fi
                printf "\r  %s Waiting for Docker daemon... %ds/15s" "${spin_chars:docker_wait%${#spin_chars}:1}" "$docker_wait"
                sleep 1
                docker_wait=$((docker_wait + 1))
            done
            printf "\r  %-50s\r" ""
        fi
        if ! sudo docker info &>/dev/null; then
            log_error "Failed to connect to Docker. Please start Docker manually and re-run."
            exit 1
        fi
    fi

    # Ensure current user is in docker group (skip if running as root)
    if [[ $EUID -ne 0 ]] && ! groups | grep -qw docker; then
        log_warn "Current user is not in the 'docker' group."
        sudo usermod -aG docker "$USER"
        log_warn "Added $USER to docker group. You may need to log out and back in."
        log_warn "For now, commands will use sudo as needed."
    fi

    # Check FUSE support
    if [[ ! -e /dev/fuse ]]; then
        log_warn "/dev/fuse not found. Loading fuse module..."
        sudo modprobe fuse 2>/dev/null || true
        if [[ ! -e /dev/fuse ]]; then
            log_error "/dev/fuse still not available. Please install FUSE for your distro:"
            echo "  Arch/CachyOS: sudo pacman -S fuse3"
            echo "  Debian/Ubuntu: sudo apt install fuse3"
            echo "  Fedora: sudo dnf install fuse3"
            exit 1
        fi
    fi
    log_info "FUSE support available."

}

check_port_conflicts() {
    local ports_to_check=() port_names=() svc
    for svc in "${SVC_ORDER[@]}"; do
        ports_to_check+=("${SVC_PORTS[$svc]}")
        port_names+=("${SVC_LABELS[$svc]}")
    done
    # Add media-server-specific ports if MEDIA_SERVER is already set
    if [[ "${MEDIA_SERVER:-}" == "plex" ]]; then
        ports_to_check+=(32400)
        port_names+=("Plex")
    elif [[ "${MEDIA_SERVER:-}" == "jellyfin" ]]; then
        ports_to_check+=(8096)
        port_names+=("Jellyfin")
    fi
    local conflicts=false
    local network_stats=""
    if command -v ss &>/dev/null; then
        network_stats=$(ss -tlnp 2>/dev/null)
    elif command -v netstat &>/dev/null; then
        network_stats=$(netstat -tlnp 2>/dev/null)
    fi

    for i in "${!ports_to_check[@]}"; do
        local port_in_use=false
        # Use explicit word-boundary match to avoid partial port matches (e.g., 828 matching 8282)
        if echo "$network_stats" | grep -qE ":${ports_to_check[$i]}($|[[:space:]])"; then
            port_in_use=true
        fi
        if [[ "$port_in_use" == "true" ]]; then
            log_warn "Port ${ports_to_check[$i]} (${port_names[$i]}) is already in use."
            conflicts=true
        fi
    done
    if [[ "$conflicts" == "true" ]]; then
        log_warn "Some ports are in use. Services using those ports may fail to start."
        log_warn "Stop the conflicting processes or change the ports in docker-compose.yml after setup."
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "Non-interactive mode: continuing despite port conflicts."
        else
            read -rp "Continue anyway? [Y/n]: " continue_anyway
            if [[ "${continue_anyway,,}" == "n" ]]; then
                log_error "Setup cancelled. Free the conflicting ports and re-run."
                exit 1
            fi
        fi
    fi
}

install_dependencies() {
    local deps=("$@")
    log_step "Installing: ${deps[*]}"

    # Detect package manager (CachyOS is Arch-based)
    if command -v pacman &>/dev/null; then
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    sudo pacman -S --noconfirm docker docker-compose-plugin
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose)
                    sudo pacman -S --noconfirm docker-compose-plugin
                    ;;
                curl)
                    sudo pacman -S --noconfirm curl
                    ;;
                jq)
                    sudo pacman -S --noconfirm jq
                    ;;
                openssl)
                    sudo pacman -S --noconfirm openssl
                    ;;
            esac
        done
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    sudo apt-get install -y docker.io docker-compose-plugin
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose)
                    sudo apt-get install -y docker-compose-plugin
                    ;;
                curl)
                    sudo apt-get install -y curl
                    ;;
                jq)
                    sudo apt-get install -y jq
                    ;;
                openssl)
                    sudo apt-get install -y openssl
                    ;;
            esac
        done
    elif command -v dnf &>/dev/null; then
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    # Use the Compose v2 plugin — the legacy `docker-compose` (v1, Python) was deprecated July 2023.
                    sudo dnf install -y docker docker-compose-plugin
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose)
                    sudo dnf install -y docker-compose-plugin
                    ;;
                curl)
                    sudo dnf install -y curl
                    ;;
                jq)
                    sudo dnf install -y jq
                    ;;
                openssl)
                    sudo dnf install -y openssl
                    ;;
            esac
        done
    else
        log_error "Unsupported package manager. Please install ${deps[*]} manually."
        exit 1
    fi

    log_info "Dependencies installed."
}

# ============================================================================
#  User Configuration
# ============================================================================

gather_config() {
    log_section "Configuration"

    # TorBox API Key
    echo -e "${BOLD}TorBox API Key${NC}"
    echo "  Get your API key from: https://torbox.app/settings"
    echo ""
    if [[ -n "${TORBOX_API_KEY:-}" ]]; then
        # Non-interactive: use env var
        log_info "Using TorBox API key from TORBOX_API_KEY env var."
    elif [[ -n "${EXISTING_TORBOX_API_KEY:-}" ]]; then
        echo -e "  ${GREEN}Previous API key found.${NC} Press Enter to keep it, or paste a new one."
        read -rsp "  TorBox API key [keep existing]: " new_torbox_key
        echo ""
        if [[ -n "$new_torbox_key" ]]; then
            TORBOX_API_KEY="$new_torbox_key"
        else
            TORBOX_API_KEY="$EXISTING_TORBOX_API_KEY"
            log_info "Keeping existing TorBox API key."
        fi
    else
        while true; do
            read -rsp "  Enter your TorBox API key: " TORBOX_API_KEY
            echo ""
            if [[ -n "$TORBOX_API_KEY" ]]; then
                break
            fi
            log_error "API key cannot be empty."
        done
    fi
    TORBOX_API_KEY="${TORBOX_API_KEY:-${EXISTING_TORBOX_API_KEY:-}}"
    # Validate API key with allowlist — only safe characters permitted
    if [[ ! "$TORBOX_API_KEY" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "API key contains invalid characters. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
        log_error "Please copy it directly from https://torbox.app/settings"
        exit 1
    fi
    log_info "API key received (${#TORBOX_API_KEY} characters, ending in ...${TORBOX_API_KEY: -4})."

    # Best-effort live verification against the TorBox API (non-fatal — works offline too).
    if command -v curl &>/dev/null; then
        local _torbox_check_status
        _torbox_check_status=$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 --max-time 10 \
            -H "Authorization: Bearer ${TORBOX_API_KEY}" \
            "https://api.torbox.app/v1/api/user/me" 2>/dev/null) || _torbox_check_status="000"
        case "$_torbox_check_status" in
            200) log_info "TorBox API key verified against api.torbox.app." ;;
            401 | 403)
                log_error "TorBox API rejected this key (HTTP ${_torbox_check_status}). Double-check it at https://torbox.app/settings."
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    read -rp "Continue with this key anyway? [y/N]: " _cont
                    [[ "${_cont,,}" != "y" ]] && exit 1
                else
                    exit 1
                fi
                ;;
            000 | "") log_warn "Could not reach api.torbox.app to verify the key (offline?). Continuing." ;;
            *) log_warn "Unexpected response from TorBox API (HTTP ${_torbox_check_status}). Continuing." ;;
        esac
    fi

    echo ""

    # Media Server Choice
    echo -e "${BOLD}Media Server${NC}"
    if [[ -n "${TORBOX_MEDIA_SERVER:-}" ]]; then
        MEDIA_SERVER="${TORBOX_MEDIA_SERVER}"
        log_info "Using media server from TORBOX_MEDIA_SERVER env var: ${MEDIA_SERVER}"
    elif [[ -n "${EXISTING_COMPOSE_PROFILES:-}" ]]; then
        MEDIA_SERVER="${EXISTING_COMPOSE_PROFILES}"
        log_info "Keeping existing media server: ${MEDIA_SERVER}"
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        MEDIA_SERVER="plex"
        log_info "Non-interactive mode: defaulting to Plex."
    else
        echo "  1) Plex"
        echo "  2) Jellyfin"
        echo ""
        while true; do
            read -rp "  Choose your media server [1/2]: " media_choice
            case "$media_choice" in
                1)
                    MEDIA_SERVER="plex"
                    break
                    ;;
                2)
                    MEDIA_SERVER="jellyfin"
                    break
                    ;;
                *) log_error "Please enter 1 or 2." ;;
            esac
        done
    fi

    # Validate media server choice
    if [[ "$MEDIA_SERVER" != "plex" && "$MEDIA_SERVER" != "jellyfin" ]]; then
        log_warn "Invalid media server '${MEDIA_SERVER}'. Defaulting to plex."
        MEDIA_SERVER="plex"
    fi

    PLEX_CLAIM="${TORBOX_PLEX_CLAIM:-}"
    if [[ "$MEDIA_SERVER" == "plex" && -z "$PLEX_CLAIM" && "$NON_INTERACTIVE" != "true" ]]; then
        echo ""
        echo -e "${BOLD}Plex Claim Token${NC} (optional, for first-time setup)"
        echo "  Get your claim token from: https://www.plex.tv/claim/"
        echo "  Press Enter to skip."
        read -rp "  Plex claim token: " PLEX_CLAIM
        PLEX_CLAIM="${PLEX_CLAIM:-}"
    fi
    if [[ -n "$PLEX_CLAIM" && ! "$PLEX_CLAIM" =~ ^claim-[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid Plex claim token format. Tokens start with 'claim-' followed by alphanumeric characters."
        log_error "Please copy it directly from https://www.plex.tv/claim/"
        exit 1
    fi

    echo ""

    # Mount directory — use default silently, allow override via env var
    MOUNT_DIR="${TORBOX_MOUNT_DIR:-/mnt/torbox-media}"
    if [[ "$NON_INTERACTIVE" != "true" && -z "${TORBOX_MOUNT_DIR:-}" ]]; then
        echo -e "${BOLD}Mount Directory${NC} [${MOUNT_DIR}]:"
        read -rp "  Press Enter to accept, or type a custom path: " custom_mount
        MOUNT_DIR="${custom_mount:-$MOUNT_DIR}"
    fi
    if [[ "$MOUNT_DIR" != /* ]]; then
        log_error "Mount path must be an absolute path (start with /). Using default."
        MOUNT_DIR="/mnt/torbox-media"
    fi
    # Reject root itself — chowning "/" would corrupt the entire filesystem
    if [[ "$MOUNT_DIR" == "/" ]]; then
        log_error "Mount path cannot be '/'. Using default."
        MOUNT_DIR="/mnt/torbox-media"
    fi
    # Block system directory prefixes (expanded to include user-data dirs)
    for prefix in /etc /usr /var /tmp /proc /sys /dev /boot /sbin /bin /lib /lib64 /run /home /root /mnt /media /srv /opt /lost+found; do
        if [[ "$MOUNT_DIR" == "$prefix" || "$MOUNT_DIR" == "$prefix"/* ]]; then
            log_error "'${MOUNT_DIR}' is under a system directory. Using default."
            MOUNT_DIR="/mnt/torbox-media"
            break
        fi
    done
    # Reject unsafe characters in mount path
    if [[ "$MOUNT_DIR" =~ [^a-zA-Z0-9_./-] ]]; then
        log_error "Mount path contains unsafe characters. Using default."
        MOUNT_DIR="/mnt/torbox-media"
    fi
    # Reject if the path is a symlink — prevents `sudo chown` from following
    # symlinks and chowning an attacker-controlled target directory.
    if [[ -L "$MOUNT_DIR" ]]; then
        log_error "Mount path '${MOUNT_DIR}' is a symlink. Using default."
        MOUNT_DIR="/mnt/torbox-media"
    fi
    # Reject mount paths that are inside the installation directory — this would
    # cause recursive shared mounts (Decypharr's FUSE mount would itself be visible
    # under INSTALL_DIR/configs, leading to mount loops and `rm -rf` data loss
    # during uninstall).
    if [[ "$MOUNT_DIR" == "$INSTALL_DIR" || "$MOUNT_DIR" == "$INSTALL_DIR"/* ]]; then
        log_error "Mount path '${MOUNT_DIR}' is inside the install directory '${INSTALL_DIR}'."
        log_error "This would cause recursive mounts and data loss. Using default."
        MOUNT_DIR="/mnt/torbox-media"
    fi

    echo ""

    # User/Group IDs
    PUID="$(id -u)"
    PGID="$(id -g)"
    echo -e "${BOLD}User/Group IDs${NC}"
    echo "  Detected: PUID=${PUID}, PGID=${PGID}"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "  Use these? [Y/n]: " use_ids
        if [[ "${use_ids,,}" == "n" ]]; then
            while true; do
                read -rp "  PUID: " PUID
                read -rp "  PGID: " PGID
                if [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]]; then
                    break
                fi
                log_error "PUID and PGID must be numeric values."
            done
        fi
    fi

    # Timezone — prefer timedatectl, then $TZ, then /etc/timezone, finally UTC.
    if command -v timedatectl &>/dev/null; then
        TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo '')"
    fi
    if [[ -z "${TZ:-}" && -r /etc/timezone ]]; then
        TZ="$(tr -d '[:space:]' </etc/timezone)"
    fi
    TZ="${TZ:-UTC}"
    echo ""
    echo -e "${BOLD}Timezone${NC}: ${TZ}"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "  Use this timezone? [Y/n]: " use_tz
        if [[ "${use_tz,,}" == "n" ]]; then
            while true; do
                read -rp "  Enter timezone (e.g., America/New_York): " TZ
                if command -v timedatectl &>/dev/null && timedatectl list-timezones 2>/dev/null | grep -qx "$TZ"; then
                    break
                elif [[ "$TZ" =~ ^[a-zA-Z_/+-]+$ ]]; then
                    log_warn "Could not verify timezone '$TZ' against system list. Using it anyway."
                    break
                else
                    log_error "Invalid timezone format. Use format like 'America/New_York' or 'UTC'."
                fi
            done
        fi
    fi

    # Generate or preserve API keys for the *arr services
    if [[ -n "${EXISTING_RADARR_API_KEY:-}" && -n "${EXISTING_SONARR_API_KEY:-}" && -n "${EXISTING_PROWLARR_API_KEY:-}" ]]; then
        RADARR_API_KEY="$EXISTING_RADARR_API_KEY"
        SONARR_API_KEY="$EXISTING_SONARR_API_KEY"
        PROWLARR_API_KEY="$EXISTING_PROWLARR_API_KEY"
        log_info "Preserved existing API keys from previous installation."
    else
        RADARR_API_KEY="$(generate_api_key)"
        SONARR_API_KEY="$(generate_api_key)"
        PROWLARR_API_KEY="$(generate_api_key)"

        # Validate keys are non-empty and correct length
        for key_name in RADARR_API_KEY SONARR_API_KEY PROWLARR_API_KEY; do
            local key_val="${!key_name}"
            if [[ -z "$key_val" || ${#key_val} -lt 32 ]]; then
                log_error "Failed to generate API key for ${key_name}. Ensure openssl, xxd, or od is installed."
                exit 1
            fi
        done
    fi

    # Generate or preserve admin credentials for the *arr services
    # Radarr
    if [[ -n "${EXISTING_RADARR_ADMIN_USER:-}" && -n "${EXISTING_RADARR_ADMIN_PASS:-}" ]]; then
        RADARR_ADMIN_USER="$EXISTING_RADARR_ADMIN_USER"
        RADARR_ADMIN_PASS="$EXISTING_RADARR_ADMIN_PASS"
    else
        RADARR_ADMIN_USER="admin"
        RADARR_ADMIN_PASS="$(_gen_admin_pass)"
    fi

    # Sonarr
    if [[ -n "${EXISTING_SONARR_ADMIN_USER:-}" && -n "${EXISTING_SONARR_ADMIN_PASS:-}" ]]; then
        SONARR_ADMIN_USER="$EXISTING_SONARR_ADMIN_USER"
        SONARR_ADMIN_PASS="$EXISTING_SONARR_ADMIN_PASS"
    else
        SONARR_ADMIN_USER="admin"
        SONARR_ADMIN_PASS="$(_gen_admin_pass)"
    fi

    # Prowlarr
    if [[ -n "${EXISTING_PROWLARR_ADMIN_USER:-}" && -n "${EXISTING_PROWLARR_ADMIN_PASS:-}" ]]; then
        PROWLARR_ADMIN_USER="$EXISTING_PROWLARR_ADMIN_USER"
        PROWLARR_ADMIN_PASS="$EXISTING_PROWLARR_ADMIN_PASS"
    else
        PROWLARR_ADMIN_USER="admin"
        PROWLARR_ADMIN_PASS="$(_gen_admin_pass)"
    fi

    # Validate passwords are non-empty
    for key_name in RADARR_ADMIN_PASS SONARR_ADMIN_PASS PROWLARR_ADMIN_PASS; do
        if [[ -z "${!key_name}" ]]; then
            log_error "Failed to generate admin password for ${key_name}. Ensure openssl or /dev/urandom is available."
            exit 1
        fi
    done

    echo ""

    # Hardware Acceleration — auto-detect, then prompt only if ambiguous
    echo -e "${BOLD}Hardware Acceleration${NC}"
    if [[ -n "${TORBOX_HW_ACCEL:-}" ]]; then
        HW_ACCEL="${TORBOX_HW_ACCEL}"
        log_info "Using hardware acceleration from TORBOX_HW_ACCEL env var: ${HW_ACCEL}"
    else
        local detected_intel=false detected_amd=false detected_nvidia=false
        # Distinguish Intel vs AMD GPUs by inspecting the render-node driver / PCI vendor.
        # /dev/dri alone is not enough — both vendors expose it.
        if [[ -d /dev/dri ]]; then
            local _gpu_vendors=""
            if command -v lspci &>/dev/null; then
                # Use PCI class codes 0300 (VGA) and 0302 (3D controller) to
                # avoid false positives — a naive text grep on "3d" matches
                # hex IDs like [8086:a33d] in PCIe root port lines.
                _gpu_vendors=$( (
                    lspci -d ::0300 -nn 2>/dev/null
                    lspci -d ::0302 -nn 2>/dev/null
                ) || true)
            fi
            if [[ -n "$_gpu_vendors" ]]; then
                # Vendor IDs: Intel=8086, AMD=1002/1022, NVIDIA=10de
                echo "$_gpu_vendors" | grep -qE '\[8086:' && detected_intel=true
                echo "$_gpu_vendors" | grep -qE '\[1002:|\[1022:' && detected_amd=true
                echo "$_gpu_vendors" | grep -qiE 'nvidia|\[10de:' && detected_nvidia=true
            else
                # lspci not available — fall back to inspecting render-node driver symlinks
                if find /dev/dri/by-path -maxdepth 1 -name '*render*' -ls 2>/dev/null | grep -qiE 'amdgpu|radeon'; then
                    detected_amd=true
                elif find /dev/dri/by-path -maxdepth 1 -name '*render*' -ls 2>/dev/null | grep -qiE 'i915|xe'; then
                    detected_intel=true
                else
                    # No way to disambiguate — assume Intel (most common integrated GPU)
                    # but warn the user so they can override.
                    detected_intel=true
                    log_warn "Could not identify /dev/dri GPU vendor (lspci unavailable). Assuming Intel."
                fi
            fi
        fi
        if command -v nvidia-smi &>/dev/null || [[ -e /dev/nvidia0 ]]; then
            detected_nvidia=true
        fi

        local _gpu_count=0
        [[ "$detected_intel" == "true" ]] && _gpu_count=$((_gpu_count + 1))
        [[ "$detected_amd" == "true" ]] && _gpu_count=$((_gpu_count + 1))
        [[ "$detected_nvidia" == "true" ]] && _gpu_count=$((_gpu_count + 1))

        if [[ $_gpu_count -eq 1 ]]; then
            if [[ "$detected_intel" == "true" ]]; then
                HW_ACCEL="intel"
                log_info "Auto-detected Intel QuickSync (/dev/dri)."
            elif [[ "$detected_amd" == "true" ]]; then
                HW_ACCEL="amd"
                log_info "Auto-detected AMD GPU (VAAPI)."
            else
                HW_ACCEL="nvidia"
                log_info "Auto-detected NVIDIA GPU."
            fi
        elif [[ $_gpu_count -gt 1 ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                # Prefer integrated GPU (power-efficient) when multiple are present
                if [[ "$detected_intel" == "true" ]]; then
                    HW_ACCEL="intel"
                elif [[ "$detected_amd" == "true" ]]; then
                    HW_ACCEL="amd"
                else
                    HW_ACCEL="nvidia"
                fi
                log_info "Multiple GPUs detected. Non-interactive: defaulting to ${HW_ACCEL}."
            else
                echo "  Multiple GPUs detected:"
                [[ "$detected_intel" == "true" ]] && echo "    • Intel  QuickSync"
                [[ "$detected_amd" == "true" ]] && echo "    • AMD    VAAPI"
                [[ "$detected_nvidia" == "true" ]] && echo "    • NVIDIA NVENC (requires nvidia-container-toolkit)"
                echo ""
                local opts=() i=1
                [[ "$detected_intel" == "true" ]] && {
                    echo "  $i) Intel QuickSync"
                    opts+=("intel")
                    i=$((i + 1))
                }
                [[ "$detected_amd" == "true" ]] && {
                    echo "  $i) AMD VAAPI"
                    opts+=("amd")
                    i=$((i + 1))
                }
                [[ "$detected_nvidia" == "true" ]] && {
                    echo "  $i) NVIDIA NVENC"
                    opts+=("nvidia")
                    i=$((i + 1))
                }
                echo ""
                while true; do
                    read -rp "  Choose hardware acceleration [1-$((i - 1))]: " hw_choice
                    if [[ "$hw_choice" =~ ^[0-9]+$ ]] && ((hw_choice >= 1 && hw_choice < i)); then
                        HW_ACCEL="${opts[$((hw_choice - 1))]}"
                        break
                    fi
                    log_error "Please enter a number between 1 and $((i - 1))."
                done
            fi
        else
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                HW_ACCEL="none"
                log_info "No GPU detected. Non-interactive: using software transcoding."
            else
                echo "  No GPU detected."
                echo "  1) None (software transcoding only)"
                echo "  2) Intel QuickSync (if you have integrated GPU)"
                echo "  3) AMD VAAPI (if you have an AMD GPU)"
                echo "  4) NVIDIA NVENC (if you have discrete NVIDIA GPU)"
                echo ""
                while true; do
                    read -rp "  Choose hardware acceleration [1/2/3/4]: " hw_choice
                    case "$hw_choice" in
                        1)
                            HW_ACCEL="none"
                            break
                            ;;
                        2)
                            HW_ACCEL="intel"
                            break
                            ;;
                        3)
                            HW_ACCEL="amd"
                            break
                            ;;
                        4)
                            HW_ACCEL="nvidia"
                            break
                            ;;
                        *) log_error "Please enter 1, 2, 3, or 4." ;;
                    esac
                done
            fi
        fi
    fi

    # Verify nvidia-container-toolkit is installed if NVIDIA is selected.
    # Try to auto-install it using the detected package manager.
    if [[ "${HW_ACCEL}" == "nvidia" ]]; then
        local _has_nvidia_toolkit=false
        command -v nvidia-container-runtime &>/dev/null && _has_nvidia_toolkit=true
        dpkg -s nvidia-container-toolkit &>/dev/null 2>&1 && _has_nvidia_toolkit=true
        rpm -q nvidia-container-toolkit &>/dev/null 2>&1 && _has_nvidia_toolkit=true
        pacman -Qi nvidia-container-toolkit &>/dev/null 2>&1 && _has_nvidia_toolkit=true

        if [[ "$_has_nvidia_toolkit" == "false" ]]; then
            log_warn "nvidia-container-toolkit is not installed. Attempting to install..."
            local _install_ok=false
            if command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm nvidia-container-toolkit && _install_ok=true
            elif command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y nvidia-container-toolkit && _install_ok=true
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y nvidia-container-toolkit && _install_ok=true
            else
                log_error "Could not auto-install nvidia-container-toolkit (unknown package manager)."
            fi

            if [[ "$_install_ok" == "true" ]]; then
                log_info "nvidia-container-toolkit installed successfully."
                # Configure Docker to use the nvidia runtime and restart
                log_step "Configuring Docker for NVIDIA GPU..."
                if sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null; then
                    sudo systemctl restart docker 2>/dev/null || true
                    # Wait for Docker daemon to be ready
                    local _docker_wait=0
                    while [[ $_docker_wait -lt 15 ]]; do
                        if docker info &>/dev/null; then
                            break
                        fi
                        sleep 1
                        _docker_wait=$((_docker_wait + 1))
                    done
                    if docker info &>/dev/null; then
                        log_info "Docker restarted with NVIDIA runtime."
                    else
                        log_warn "Docker restarted but may not be ready. You may need to restart Docker manually."
                    fi
                else
                    log_warn "nvidia-ctk runtime configure failed. NVIDIA GPU may not work in containers."
                    log_warn "Try: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
                fi
            else
                log_error "nvidia-container-toolkit installation failed."
                log_error "Install it manually, then re-run setup.sh."
                echo ""
                echo "  Arch/CachyOS: sudo pacman -S nvidia-container-toolkit"
                echo "  Debian/Ubuntu: sudo apt install nvidia-container-toolkit"
                echo "  Fedora: sudo dnf install nvidia-container-toolkit"
                echo ""
                log_info "Falling back to software transcoding."
                HW_ACCEL="none"
            fi
        else
            log_info "nvidia-container-toolkit is installed."
        fi
    fi

    echo ""
    log_info "Configuration complete."
    log_info "Generated API keys for Radarr, Sonarr, and Prowlarr."

    # Show confirmation summary
    log_section "Configuration Summary"
    echo -e "  ${BOLD}TorBox API Key:${NC}    ...${TORBOX_API_KEY: -4}"
    echo -e "  ${BOLD}Media Server:${NC}      ${MEDIA_SERVER}"
    echo -e "  ${BOLD}Mount Directory:${NC}   ${MOUNT_DIR}"
    echo -e "  ${BOLD}PUID/PGID:${NC}         ${PUID}:${PGID}"
    echo -e "  ${BOLD}Timezone:${NC}          ${TZ}"
    echo -e "  ${BOLD}HW Acceleration:${NC}   ${HW_ACCEL}"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Proceed with these settings? [Y/n]: " confirm_config
        if [[ "${confirm_config,,}" == "n" ]]; then
            log_info "Setup cancelled."
            exit 0
        fi
    fi
}

# ============================================================================
#  Directory Structure
# ============================================================================

create_directories() {
    log_section "Creating Directory Structure"

    # Directories need more permissive permissions for container access
    local saved_umask
    saved_umask="$(umask)"
    umask 022

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${CONFIG_DIR}"/{prowlarr,radarr,sonarr,seerr,decypharr}
    mkdir -p "${DATA_DIR}"/{media/{movies,tv},downloads/{radarr,sonarr}}

    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        mkdir -p "${CONFIG_DIR}/plex"
    else
        mkdir -p "${CONFIG_DIR}/jellyfin"
    fi

    # Restore restrictive umask for subsequent file creation
    umask "$saved_umask"

    # Create mount point
    sudo mkdir -p "${MOUNT_DIR}"
    # Use -h to avoid following symlinks (defense-in-depth; the gather_config
    # step already rejects symlinked mount paths, but mkdir -p can re-create a
    # symlink at the path if it was removed between validation and here).
    sudo chown -h "${PUID}:${PGID}" "${MOUNT_DIR}" 2>/dev/null || sudo chown "${PUID}:${PGID}" "${MOUNT_DIR}"

    # Ensure mount point supports shared propagation for rclone FUSE mounts
    log_step "Setting up mount propagation..."
    if ! findmnt -n "${MOUNT_DIR}" &>/dev/null; then
        sudo mount --bind "${MOUNT_DIR}" "${MOUNT_DIR}" 2>/dev/null || true
    fi
    sudo mount --make-shared "${MOUNT_DIR}" 2>/dev/null || true
    if findmnt -n -o PROPAGATION "${MOUNT_DIR}" 2>/dev/null | grep -q "shared"; then
        log_info "Mount propagation configured (shared)."
    else
        log_warn "Mount propagation may not be active. Decypharr's FUSE mounts might not be visible to other containers."
        log_warn "If media files aren't visible in Plex/Jellyfin, see the troubleshooting section in README."
    fi

    log_info "Directories created at: ${INSTALL_DIR}"
}

# ============================================================================
#  Generate Decypharr Config
# ============================================================================

generate_decypharr_config() {
    log_step "Generating Decypharr configuration..."

    # Validate user-supplied credentials before interpolating them into JSON —
    # values from DECYPHARR_USER / DECYPHARR_PASS env vars could otherwise
    # break the JSON document (double quotes, backslashes) or inject fields.
    DECYPHARR_USER="${DECYPHARR_USER:-torbox}"
    if [[ ! "$DECYPHARR_USER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
        log_warn "DECYPHARR_USER contains characters unsafe for JSON. Using default 'torbox'."
        DECYPHARR_USER="torbox"
    fi
    if [[ -n "${DECYPHARR_PASS:-}" && ! "$DECYPHARR_PASS" =~ ^[a-zA-Z0-9_./+=-]+$ ]]; then
        log_warn "DECYPHARR_PASS contains characters unsafe for JSON. Regenerating."
        DECYPHARR_PASS=""
    fi

    # If a config already exists, refresh the TorBox API key (and creds if known)
    # instead of skipping — otherwise rotating TORBOX_API_KEY would silently leave
    # Decypharr using the old key, desynchronizing it from .env and the *arr stack.
    if [[ -f "${CONFIG_DIR}/decypharr/config.json" ]]; then
        if command -v jq &>/dev/null; then
            local _tmp="${CONFIG_DIR}/decypharr/config.json.tmp.$$"
            if jq --arg key "${TORBOX_API_KEY}" \
                --arg user "${DECYPHARR_USER}" \
                --arg pass "${DECYPHARR_PASS:-}" \
                '(.debrids[0] // {}).api_key = $key
                   | if $pass != "" then .password = $pass else . end
                   | .username = $user' \
                "${CONFIG_DIR}/decypharr/config.json" >"$_tmp" 2>/dev/null; then
                mv "$_tmp" "${CONFIG_DIR}/decypharr/config.json"
                chmod 600 "${CONFIG_DIR}/decypharr/config.json"
                log_info "Refreshed TorBox API key in existing Decypharr config (other settings preserved)."
            else
                rm -f "$_tmp"
                log_warn "Could not update existing Decypharr config via jq. Old API key retained."
            fi
        else
            log_warn "jq not available — cannot refresh TorBox API key in existing Decypharr config."
            log_warn "If you rotated your TorBox key, edit ${CONFIG_DIR}/decypharr/config.json manually."
        fi
        return 0
    fi

    if [[ -z "${DECYPHARR_PASS:-}" ]]; then
        DECYPHARR_PASS="$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | head -c 12)"
        if [[ -z "$DECYPHARR_PASS" ]]; then
            DECYPHARR_PASS="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12)"
        fi
    fi
    # Final length sanity check — empty/truncated password would lock the user out.
    if [[ -z "$DECYPHARR_PASS" || ${#DECYPHARR_PASS} -lt 8 ]]; then
        log_error "Failed to generate a sufficient Decypharr password. Ensure openssl or /dev/urandom is available."
        exit 1
    fi

    cat >"${CONFIG_DIR}/decypharr/config.json" <<DECYPHARR_EOF
{
  "debrids": [
    {
      "name": "torbox",
      "api_key": "${TORBOX_API_KEY}",
      "folder": "/mnt/remote/torbox/__all__",
      "rate_limit": "55/hour",
      "use_webdav": true
    }
  ],
  "rclone": {
    "enabled": true,
    "mount_path": "/mnt/remote"
  },
  "qbittorrent": {
    "download_folder": "/data/downloads/",
    "categories": ["sonarr", "radarr"]
  },
  "username": "${DECYPHARR_USER}",
  "password": "${DECYPHARR_PASS}",
  "port": "8282",
  "log_level": "info"
}
DECYPHARR_EOF

    chmod 600 "${CONFIG_DIR}/decypharr/config.json"
    log_info "Decypharr config written with pre-seeded credentials."
}

# ============================================================================
#  Generate *arr Config XML (Pre-seed API keys & auth)
# ============================================================================

generate_arr_configs() {
    log_step "Pre-seeding Radarr, Sonarr, and Prowlarr configs..."

    # On re-run, only update the ApiKey line to preserve user settings
    local arr_name arr_dir arr_key
    for arr_name in radarr sonarr prowlarr; do
        arr_dir="${CONFIG_DIR}/${arr_name}/config.xml"
        case "$arr_name" in
            radarr) arr_key="${RADARR_API_KEY}" ;;
            sonarr) arr_key="${SONARR_API_KEY}" ;;
            prowlarr) arr_key="${PROWLARR_API_KEY}" ;;
        esac
        if [[ -f "$arr_dir" ]]; then
            # Validate key is pure hex before using in sed replacement
            if [[ ! "$arr_key" =~ ^[0-9a-f]{32}$ ]]; then
                log_warn "  API key for ${arr_name} is not valid hex. Regenerating."
                arr_key="$(generate_api_key)"
            fi
            sed -i "s|<ApiKey>.*</ApiKey>|<ApiKey>${arr_key}</ApiKey>|" "$arr_dir"
            log_info "  Updated API key in existing ${arr_name} config.xml (other settings preserved)."
        fi
    done

    # Only write fresh config.xml if it doesn't already exist
    # NOTE: Start with DisabledForLocalAddresses so the UI is reachable if auto-config
    # has not run yet. configure_arr_auth() switches to Forms+Enabled via the API.
    if [[ ! -f "${CONFIG_DIR}/radarr/config.xml" ]]; then
        # --- Radarr config.xml ---
        cat >"${CONFIG_DIR}/radarr/config.xml" <<RADARR_XML_EOF
<Config>
  <LogLevel>info</LogLevel>
  <EnableSsl>False</EnableSsl>
  <Port>7878</Port>
  <SslPort>9898</SslPort>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <ApiKey>${RADARR_API_KEY}</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>master</Branch>
  <InstanceName>Radarr</InstanceName>
</Config>
RADARR_XML_EOF
        chmod 600 "${CONFIG_DIR}/radarr/config.xml"
    fi

    if [[ ! -f "${CONFIG_DIR}/sonarr/config.xml" ]]; then
        # --- Sonarr config.xml ---
        cat >"${CONFIG_DIR}/sonarr/config.xml" <<SONARR_XML_EOF
<Config>
  <LogLevel>info</LogLevel>
  <EnableSsl>False</EnableSsl>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <ApiKey>${SONARR_API_KEY}</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>main</Branch>
  <InstanceName>Sonarr</InstanceName>
</Config>
SONARR_XML_EOF
        chmod 600 "${CONFIG_DIR}/sonarr/config.xml"
    fi

    if [[ ! -f "${CONFIG_DIR}/prowlarr/config.xml" ]]; then
        # --- Prowlarr config.xml ---
        cat >"${CONFIG_DIR}/prowlarr/config.xml" <<PROWLARR_XML_EOF
<Config>
  <LogLevel>info</LogLevel>
  <EnableSsl>False</EnableSsl>
  <Port>9696</Port>
  <SslPort>6969</SslPort>
  <UrlBase></UrlBase>
  <BindAddress>*</BindAddress>
  <ApiKey>${PROWLARR_API_KEY}</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>
  <Branch>develop</Branch>
  <InstanceName>Prowlarr</InstanceName>
</Config>
PROWLARR_XML_EOF
        chmod 600 "${CONFIG_DIR}/prowlarr/config.xml"
    fi

    log_info "Pre-seeded config.xml for Radarr, Sonarr, and Prowlarr."
    log_info "  Radarr  API key: $(mask_key "${RADARR_API_KEY}")"
    log_info "  Sonarr  API key: $(mask_key "${SONARR_API_KEY}")"
    log_info "  Prowlarr API key: $(mask_key "${PROWLARR_API_KEY}")"
}

# ============================================================================
#  Generate .env File
# ============================================================================

generate_env_file() {
    log_step "Generating environment file..."

    # Set the compose profile based on media server choice
    local compose_profile="plex"
    if [[ "${MEDIA_SERVER}" == "jellyfin" ]]; then
        compose_profile="jellyfin"
    fi

    cat >"${ENV_FILE}" <<ENV_EOF
# TorBox Media Server - Environment Configuration
# Generated on $(date)

# User/Group IDs (match your host user)
PUID="${PUID}"
PGID="${PGID}"

# Timezone
TZ="${TZ}"

# TorBox
TORBOX_API_KEY="${TORBOX_API_KEY}"

# Paths
CONFIG_DIR="${CONFIG_DIR}"
DATA_DIR="${DATA_DIR}"
MOUNT_DIR="${MOUNT_DIR}"

# Docker Compose Profile (activates only the selected media server)
COMPOSE_PROFILES="${compose_profile}"

# Plex
PLEX_CLAIM="${PLEX_CLAIM:-}"

# *arr API Keys (pre-seeded)
RADARR_API_KEY="${RADARR_API_KEY}"
SONARR_API_KEY="${SONARR_API_KEY}"
PROWLARR_API_KEY="${PROWLARR_API_KEY}"

# Decypharr credentials (pre-seeded)
DECYPHARR_USER="${DECYPHARR_USER:-torbox}"
DECYPHARR_PASS="${DECYPHARR_PASS:-}"
ENV_EOF

    # Preserve existing admin credentials if this is a re-run, or write newly generated ones on fresh install
    # Check each service independently to avoid losing credentials if only some exist
    {
        echo ""
        echo "# Admin Credentials"
        if [[ -n "${EXISTING_RADARR_ADMIN_USER:-}" && -n "${EXISTING_RADARR_ADMIN_PASS:-}" ]]; then
            echo "RADARR_ADMIN_USER=\"${EXISTING_RADARR_ADMIN_USER}\""
            echo "RADARR_ADMIN_PASS=\"${EXISTING_RADARR_ADMIN_PASS}\""
        else
            echo "RADARR_ADMIN_USER=\"${RADARR_ADMIN_USER}\""
            echo "RADARR_ADMIN_PASS=\"${RADARR_ADMIN_PASS}\""
        fi
        if [[ -n "${EXISTING_SONARR_ADMIN_USER:-}" && -n "${EXISTING_SONARR_ADMIN_PASS:-}" ]]; then
            echo "SONARR_ADMIN_USER=\"${EXISTING_SONARR_ADMIN_USER}\""
            echo "SONARR_ADMIN_PASS=\"${EXISTING_SONARR_ADMIN_PASS}\""
        else
            echo "SONARR_ADMIN_USER=\"${SONARR_ADMIN_USER}\""
            echo "SONARR_ADMIN_PASS=\"${SONARR_ADMIN_PASS}\""
        fi
        if [[ -n "${EXISTING_PROWLARR_ADMIN_USER:-}" && -n "${EXISTING_PROWLARR_ADMIN_PASS:-}" ]]; then
            echo "PROWLARR_ADMIN_USER=\"${EXISTING_PROWLARR_ADMIN_USER}\""
            echo "PROWLARR_ADMIN_PASS=\"${EXISTING_PROWLARR_ADMIN_PASS}\""
        else
            echo "PROWLARR_ADMIN_USER=\"${PROWLARR_ADMIN_USER}\""
            echo "PROWLARR_ADMIN_PASS=\"${PROWLARR_ADMIN_PASS}\""
        fi
    } >>"${ENV_FILE}"

    if [[ -n "${EXISTING_RADARR_ADMIN_USER:-}" && -n "${EXISTING_RADARR_ADMIN_PASS:-}" ]]; then
        log_info "  Preserved existing Radarr admin credentials."
    else
        log_info "  Generated new Radarr admin credentials."
    fi
    if [[ -n "${EXISTING_SONARR_ADMIN_USER:-}" && -n "${EXISTING_SONARR_ADMIN_PASS:-}" ]]; then
        log_info "  Preserved existing Sonarr admin credentials."
    else
        log_info "  Generated new Sonarr admin credentials."
    fi
    if [[ -n "${EXISTING_PROWLARR_ADMIN_USER:-}" && -n "${EXISTING_PROWLARR_ADMIN_PASS:-}" ]]; then
        log_info "  Preserved existing Prowlarr admin credentials."
    else
        log_info "  Generated new Prowlarr admin credentials."
    fi

    chmod 600 "${ENV_FILE}"
    log_info "Environment file written (profile: ${compose_profile})."
}

# ============================================================================
#  Generate Docker Compose
# ============================================================================

generate_docker_compose() {
    log_step "Setting up Docker Compose..."

    # Copy static compose file from repo to install directory
    cp "${SCRIPT_DIR}/docker-compose.yml" "${COMPOSE_FILE}"

    # Ensure no ghost overrides remain from previous installations
    rm -f "${INSTALL_DIR}/docker-compose.override.yml"

    # Generate hardware acceleration override (only if needed)
    if [[ "${HW_ACCEL}" == "intel" ]]; then
        cat >"${INSTALL_DIR}/docker-compose.override.yml" <<'HW_OVERRIDE'
# Auto-generated: Intel QuickSync hardware acceleration
# Active media server gets /dev/dri passthrough
services:
  plex:
    devices:
      - /dev/dri:/dev/dri
  jellyfin:
    devices:
      - /dev/dri:/dev/dri
HW_OVERRIDE
        log_info "Hardware acceleration override: Intel QuickSync (/dev/dri)."
    elif [[ "${HW_ACCEL}" == "amd" ]]; then
        cat >"${INSTALL_DIR}/docker-compose.override.yml" <<'HW_OVERRIDE'
# Auto-generated: AMD VAAPI hardware acceleration
# Active media server gets /dev/dri passthrough plus video/render groups.
# Jellyfin/Plex use VAAPI (Mesa) for AMD GPUs.
services:
  plex:
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "video"
      - "render"
  jellyfin:
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "video"
      - "render"
HW_OVERRIDE
        log_info "Hardware acceleration override: AMD VAAPI (/dev/dri + video/render groups)."
    elif [[ "${HW_ACCEL}" == "nvidia" ]]; then
        cat >"${INSTALL_DIR}/docker-compose.override.yml" <<'HW_OVERRIDE'
# Auto-generated: NVIDIA GPU hardware acceleration
# Active media server gets GPU passthrough
services:
  plex:
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
  jellyfin:
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
HW_OVERRIDE
        log_info "Hardware acceleration override: NVIDIA GPU."
    fi

    chmod 600 "${COMPOSE_FILE}"
    log_info "Docker Compose file set up."

    # Validate the Compose file (only if Docker daemon is accessible)
    if docker info &>/dev/null || sudo docker info &>/dev/null; then
        if run_with_spinner "Validating Docker Compose file..." compose_cmd config -q; then
            log_info "Docker Compose file validated successfully."
        else
            log_warn "Docker Compose validation failed. The generated file may have issues."
        fi
    else
        log_warn "Docker daemon not accessible. Skipping Compose validation. Run 'docker compose config' to validate manually."
    fi
}

# ============================================================================
#  Generate Management Script
# ============================================================================

generate_management_script() {
    log_step "Generating management script..."

    cat >"${INSTALL_DIR}/manage.sh" <<'MANAGE_EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
VERSION="__VERSION__"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Service port registry
SVC_ORDER=(decypharr prowlarr byparr radarr sonarr seerr)
declare -A SVC_PORTS=(
    [decypharr]=8282 [prowlarr]=9696 [byparr]=8191
    [radarr]=7878 [sonarr]=8989 [seerr]=5055
)
declare -A SVC_LABELS=(
    [decypharr]="Decypharr" [prowlarr]="Prowlarr" [byparr]="Byparr"
    [radarr]="Radarr" [sonarr]="Sonarr" [seerr]="Seerr"
)

# Safely read a value from .env without executing shell code
env_val() {
    local key="$1"
    # Strip inline comments (everything after an unescaped #) and surrounding quotes
    grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/#.*$//' | tr -d '"' | tr -d "'" | tr -d '\r'
}

COMPOSE_CMD=()
_COMPOSE_SUDO_WARNED=false
MANAGE_EOF

    # Write shared functions inline instead of using declare -f (avoids hidden dependency on setup.sh signatures)
    cat >>"${INSTALL_DIR}/manage.sh" <<'MANAGE_INLINE'
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

detect_compose_cmd() {
    if docker info &>/dev/null; then
        COMPOSE_CMD=(docker compose)
    else
        if [[ "$_COMPOSE_SUDO_WARNED" != "true" ]]; then
            log_warn "Docker socket not accessible in current shell — using sudo."
            _COMPOSE_SUDO_WARNED=true
        fi
        COMPOSE_CMD=(sudo docker compose)
    fi
}

compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    # CD into directory so Docker auto-discovers both docker-compose.yml and docker-compose.override.yml
    (cd "${SCRIPT_DIR}" && exec "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}
MANAGE_INLINE

    cat >>"${INSTALL_DIR}/manage.sh" <<'MANAGE_EOF'

ensure_mount_propagation() {
    local mount_dir
    mount_dir="$(env_val MOUNT_DIR)"
    if [[ -n "${mount_dir}" ]]; then
        echo -e "${YELLOW}Requesting sudo privileges to re-apply FUSE mounts...${NC}"
        # Guard with findmnt to prevent mount stacking. Pass mount_dir as a positional
        # argument to a sudo bash -c so the path is never interpolated into shell code.
        sudo bash -c 'findmnt -n "$1" >/dev/null 2>&1 || mount --bind "$1" "$1"' _ "${mount_dir}" 2>/dev/null || true
        sudo mount --make-shared "${mount_dir}" 2>/dev/null || true
    fi
}

show_help() {
    echo -e "${CYAN}TorBox Media Server - Management${NC}"
    echo ""
    echo "Usage: ./manage.sh <command>"
    echo ""
    echo "Commands:"
    echo "  start       Start all services"
    echo "  stop        Stop all services"
    echo "  restart     Restart all services"
    echo "  status      Show service status"
    echo "  logs        Show logs (follow mode)"
    echo "  logs <svc>  Show logs for a specific service"
    echo "  pull        Pull pinned image versions"
    echo "  update      Pull pinned images and restart"
    echo "  down        Stop and remove containers"
    echo "  urls        Show all service URLs"
    echo "  keys        Show API keys"
    echo "  reset-auth  Push admin passwords from .env into Radarr/Sonarr/Prowlarr"
    echo "  enable      Enable auto-start on boot"
    echo "  disable     Disable auto-start on boot"
    echo "  backup      Back up configs and .env"
    echo "  restore     Restore from a backup (list or specify timestamp)"
    echo "  health      Check health of all services"
    echo "  shell <svc> Open a shell in a service container"
    echo "  version     Show version"
    echo "  help        Show this help"
}

show_urls() {
    local media_server svc
    media_server="$(env_val COMPOSE_PROFILES)"
    [[ -z "$media_server" ]] && media_server="$(env_val MEDIA_SERVER)"
    echo -e "\n${CYAN}━━━━ Service URLs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    for svc in "${SVC_ORDER[@]}"; do
        printf "  %b%-14s%b http://localhost:%s\n" "$BOLD" "${SVC_LABELS[$svc]}" "$NC" "${SVC_PORTS[$svc]}"
    done
    if [[ "${media_server}" == "plex" ]]; then
        printf "  %b%-14s%b http://localhost:32400/web\n" "$BOLD" "Plex" "$NC"
    else
        printf "  %b%-14s%b http://localhost:8096\n" "$BOLD" "Jellyfin" "$NC"
    fi
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}
cmd_keys() {
    local show_secrets=false
    local _radarr_pass _sonarr_pass _prowlarr_pass
    if [[ "$2" == "--show-secrets" ]]; then
        show_secrets=true
    fi

    mask_val() {
        local val="$1"
        if [[ "$show_secrets" == "true" ]]; then
            echo "$val"
        elif [[ ${#val} -gt 8 ]]; then
            echo "${val:0:4}...<hidden>...${val: -4}"
        else
            echo "***<hidden>***"
        fi
    }

    echo -e "\n${CYAN}━━━━ API Keys ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    if [[ "$show_secrets" == "true" ]]; then
        echo -e "  ${YELLOW}WARNING: Sensitive credentials below. Do not share this output.${NC}\n"
    else
        echo -e "  ${YELLOW}Secrets masked. Use './manage.sh keys --show-secrets' to reveal.${NC}\n"
    fi

    echo -e "  ${BOLD}TorBox${NC}    $(mask_val "$(env_val TORBOX_API_KEY)")"
    echo -e "  ${BOLD}Radarr${NC}    $(mask_val "$(env_val RADARR_API_KEY)")"
    echo -e "  ${BOLD}Sonarr${NC}    $(mask_val "$(env_val SONARR_API_KEY)")"
    echo -e "  ${BOLD}Prowlarr${NC}  $(mask_val "$(env_val PROWLARR_API_KEY)")"

    _radarr_pass="$(env_val RADARR_ADMIN_PASS)"
    _sonarr_pass="$(env_val SONARR_ADMIN_PASS)"
    _prowlarr_pass="$(env_val PROWLARR_ADMIN_PASS)"
    if [[ -n "$_radarr_pass" ]]; then
        echo ""
        echo -e "  ${BOLD}Admin Credentials:${NC}"
        echo -e "  ${BOLD}Radarr${NC}    user: $(env_val RADARR_ADMIN_USER)  pass: $(mask_val "${_radarr_pass}")"
        echo -e "  ${BOLD}Sonarr${NC}    user: $(env_val SONARR_ADMIN_USER)  pass: $(mask_val "${_sonarr_pass}")"
        echo -e "  ${BOLD}Prowlarr${NC}  user: $(env_val PROWLARR_ADMIN_USER)  pass: $(mask_val "${_prowlarr_pass}")"
    fi
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

sync_arr_auth() {
    local name="$1" port="$2" api_key_var="$3" user_var="$4" pass_var="$5" api_ver="${6:-v3}"
    local api_key user pass url auth_config auth_id updated

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}jq is required. Install jq and retry.${NC}" >&2
        return 1
    fi

    api_key="$(env_val "$api_key_var")"
    user="$(env_val "$user_var")"
    pass="$(env_val "$pass_var")"
    url="http://localhost:${port}"

    if [[ -z "$api_key" || -z "$user" || -z "$pass" ]]; then
        echo -e "${YELLOW}Skipping ${name}: missing API key or admin credentials in .env${NC}"
        return 1
    fi

    auth_config="$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: $api_key" \
        "${url}/api/${api_ver}/config/host" 2>/dev/null)" || true
    if [[ -z "$auth_config" ]]; then
        echo -e "${YELLOW}Skipping ${name}: service not reachable on port ${port}${NC}"
        return 1
    fi

    auth_id="$(echo "$auth_config" | jq -r '.id' 2>/dev/null)" || true
    if [[ -z "$auth_id" || "$auth_id" == "null" ]]; then
        echo -e "${YELLOW}Skipping ${name}: could not read auth config${NC}"
        return 1
    fi

    updated="$(echo "$auth_config" | jq \
        --arg user "$user" \
        --arg pass "$pass" \
        '.authenticationMethod = "Forms" | .authenticationRequired = "Enabled" | .username = $user | .password = $pass | .passwordConfirmation = $pass' 2>/dev/null)" || true
    if [[ -z "$updated" ]]; then
        echo -e "${YELLOW}Skipping ${name}: could not build auth update${NC}"
        return 1
    fi

    if echo "$updated" | curl -sf --connect-timeout 5 --max-time 15 -X PUT \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        "${url}/api/${api_ver}/config/host/${auth_id}" \
        -d @- -o /dev/null 2>/dev/null; then
        echo -e "${GREEN}✓${NC} ${name} login synced (user: ${user})"
        return 0
    fi

    if echo "$updated" | curl -sf --connect-timeout 5 --max-time 15 -X PUT \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: $api_key" \
        "${url}/api/${api_ver}/config/host" \
        -d @- -o /dev/null 2>/dev/null; then
        echo -e "${GREEN}✓${NC} ${name} login synced (user: ${user})"
        return 0
    fi

    echo -e "${YELLOW}Failed to sync ${name} login${NC}"
    return 1
}

reset_auth_cmd() {
    echo -e "${CYAN}Syncing admin logins from .env to Radarr, Sonarr, and Prowlarr...${NC}"
    echo ""
    sync_arr_auth "Radarr" 7878 RADARR_API_KEY RADARR_ADMIN_USER RADARR_ADMIN_PASS v3 || true
    sync_arr_auth "Sonarr" 8989 SONARR_API_KEY SONARR_ADMIN_USER SONARR_ADMIN_PASS v3 || true
    sync_arr_auth "Prowlarr" 9696 PROWLARR_API_KEY PROWLARR_ADMIN_USER PROWLARR_ADMIN_PASS v1 || true
    echo ""
    echo -e "Use ${BOLD}./manage.sh keys --show-secrets${NC} to view credentials."
}

case "${1:-help}" in
    start)
        echo -e "${GREEN}Starting all services...${NC}"
        ensure_mount_propagation
        compose_cmd up -d --remove-orphans
        show_urls
        ;;
    stop)
        echo -e "${YELLOW}Stopping all services...${NC}"
        compose_cmd stop
        ;;
    restart)
        echo -e "${YELLOW}Restarting all services...${NC}"
        compose_cmd stop
        ensure_mount_propagation
        compose_cmd up -d --remove-orphans
        show_urls
        ;;
    status)
        compose_cmd ps
        ;;
    logs)
        if [[ -n "${2:-}" ]]; then
            compose_cmd logs -f "$2"
        else
            compose_cmd logs -f
        fi
        ;;
    pull)
        echo -e "${GREEN}Pulling pinned images...${NC}"
        compose_cmd pull
        ;;
    update)
        echo -e "${GREEN}Updating all services...${NC}"
        ensure_mount_propagation
        compose_cmd pull
        compose_cmd up -d --remove-orphans
        show_urls
        ;;
    down)
        echo -e "${RED}Stopping and removing containers...${NC}"
        compose_cmd down
        ;;
    urls)
        show_urls
        ;;
    keys)
        cmd_keys "$@"
        ;;
    reset-auth)
        reset_auth_cmd
        ;;
    enable)
        if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
            echo -e "${GREEN}Enabling auto-start on boot...${NC}"
            sudo systemctl enable torbox-media-server 2>/dev/null && \
                echo -e "${GREEN}Auto-start enabled. Services will start automatically on boot.${NC}" || \
                echo -e "${YELLOW}Failed to enable systemd service.${NC}"
        else
            echo -e "${YELLOW}systemd not available on this system.${NC}"
            echo "  Use './manage.sh start' to start services manually."
        fi
        ;;
    disable)
        if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
            echo -e "${YELLOW}Disabling auto-start on boot...${NC}"
            sudo systemctl disable torbox-media-server 2>/dev/null && \
                echo -e "${YELLOW}Auto-start disabled. Use './manage.sh start' to start services manually.${NC}" || \
                echo -e "${YELLOW}Systemd service not found.${NC}"
        else
            echo -e "${YELLOW}systemd not available on this system.${NC}"
        fi
        ;;
    backup)
        backup_dir="$(dirname "${SCRIPT_DIR}")/backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${backup_dir}"
        chmod 700 "${backup_dir}"
        cp -a "${ENV_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -a "${COMPOSE_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -ra "${SCRIPT_DIR}/configs" "${backup_dir}/" 2>/dev/null || true
        echo -e "${GREEN}Backup saved to: ${backup_dir}${NC}"
        ;;
    restore)
        backups_dir="$(dirname "${SCRIPT_DIR}")/backups"
        if [[ ! -d "${backups_dir}" ]]; then
            echo -e "${RED}No backups found. Run 'backup' first to create one.${NC}"
            exit 1
        fi
        target=""
        if [[ -n "${2:-}" ]]; then
            target="${backups_dir}/${2}"
            # Resolve and verify the target is under backups_dir to prevent
            # path traversal (e.g. `./manage.sh restore ../../../etc`).
            target="$(realpath -m "${target}" 2>/dev/null || echo "${target}")"
            case "${target}" in
                "${backups_dir}"/*) ;;
                *)
                    echo -e "${RED}Invalid backup selection.${NC}"
                    exit 1
                    ;;
            esac
        else
            # List available backups and let user choose
            echo -e "${CYAN}Available backups:${NC}"
            i=0
            backup_dirs=()
            for d in "${backups_dir}"/*/; do
                if [[ -d "$d" ]]; then
                    i=$((i + 1))
                    backup_dirs+=("$d")
                    echo "  ${i}) $(basename "$d")"
                fi
            done
            if [[ $i -eq 0 ]]; then
                echo -e "${RED}No backups found.${NC}"
                exit 1
            fi
            read -rp "Select backup number [1-${i}]: " choice
            if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $i ]]; then
                echo -e "${RED}Invalid selection.${NC}"
                exit 1
            fi
            target="${backup_dirs[$((choice - 1))]}"
        fi
        if [[ ! -d "${target}" ]]; then
            echo -e "${RED}Backup not found: ${target}${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Restoring from: $(basename "${target}")${NC}"
        echo -e "${RED}This will overwrite current configuration. Continue?${NC}"
        read -rp "Type 'yes' to confirm: " confirm
        if [[ "${confirm}" != "yes" ]]; then
            echo "Restore cancelled."
            exit 0
        fi
        echo -e "${GREEN}Stopping containers...${NC}"
        compose_cmd down 2>/dev/null || true
        # Restore files
        [[ -f "${target}/.env" ]] && cp -a "${target}/.env" "${ENV_FILE}" && echo "  Restored .env"
        [[ -f "${target}/docker-compose.yml" ]] && cp -a "${target}/docker-compose.yml" "${COMPOSE_FILE}" && echo "  Restored docker-compose.yml"
        [[ -d "${target}/configs" ]] && cp -ra "${target}/configs" "${SCRIPT_DIR}/" && \
            sudo chown -R "$(env_val PUID):$(env_val PGID)" "${SCRIPT_DIR}/configs" "${SCRIPT_DIR}/data" 2>/dev/null && \
            echo "  Restored configs/"
        echo -e "${GREEN}Starting containers...${NC}"
        compose_cmd up -d --remove-orphans
        echo -e "${GREEN}Restore complete.${NC}"
        ;;
    health)
        echo -e "\n${CYAN}━━━━ Service Health ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        compose_cmd ps
        echo ""
        for svc in "${SVC_ORDER[@]}"; do
            if curl -sf --connect-timeout 2 --max-time 5 -o /dev/null "http://localhost:${SVC_PORTS[$svc]}" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} ${SVC_LABELS[$svc]} (port ${SVC_PORTS[$svc]}) — reachable"
            else
                echo -e "  ${RED}✗${NC} ${SVC_LABELS[$svc]} (port ${SVC_PORTS[$svc]}) — not reachable"
            fi
        done
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        ;;
    shell)
        if [[ -z "${2:-}" ]]; then
            echo -e "${YELLOW}Usage: ./manage.sh shell <service-name>${NC}"
            echo "  Available: decypharr prowlarr byparr radarr sonarr seerr plex jellyfin"
            exit 1
        fi
        compose_cmd exec "$2" /bin/bash 2>/dev/null || compose_cmd exec "$2" /bin/sh
        ;;
    version|--version|-v)
        echo "TorBox Media Server Management v${VERSION}"
        ;;
    help|*)
        show_help
        ;;
esac
MANAGE_EOF

    chmod +x "${INSTALL_DIR}/manage.sh"
    sed -i "s/__VERSION__/${VERSION}/" "${INSTALL_DIR}/manage.sh"
    log_info "Management script created: ${INSTALL_DIR}/manage.sh"
}

# ============================================================================
#  Generate Systemd Service (auto-start on boot)
# ============================================================================

generate_systemd_service() {
    log_step "Setting up auto-start on boot..."

    # Skip on non-systemd systems (check for running systemd, not just the binary)
    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl &>/dev/null; then
        log_warn "systemd not detected. Skipping auto-start service creation."
        log_warn "Use './manage.sh start' to start services manually after reboot."
        HAS_SYSTEMD=false
        return 0
    fi
    HAS_SYSTEMD=true

    local service_name="torbox-media-server"
    local service_file="/etc/systemd/system/${service_name}.service"

    # Resolve absolute path for systemd ExecStart (V2 only — V1 deprecated July 2023)
    local docker_bin compose_args
    docker_bin="$(command -v docker)"
    compose_args="compose"
    if ! docker compose version &>/dev/null && ! sudo docker compose version &>/dev/null; then
        log_warn "Docker Compose v2 not detected. Systemd service may not work."
    fi

    sudo tee "${service_file}" >/dev/null <<SYSTEMD_EOF
[Unit]
Description=TorBox Media Server - Mount Propagation & Services
After=local-fs.target network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}

# Step 1: Set up FUSE mount propagation (required for rclone WebDAV in Decypharr)
# Guard with findmnt to prevent mount stacking on repeated restarts
ExecStartPre=/bin/bash -c "findmnt -n '\$MOUNT_DIR' >/dev/null 2>&1 || mount --bind '\$MOUNT_DIR' '\$MOUNT_DIR'"
ExecStartPre=/bin/bash -c "mount --make-shared '\$MOUNT_DIR'"

# Step 2: Start all containers (foreground so systemd tracks the process)
ExecStart=${docker_bin} ${compose_args} --env-file "${ENV_FILE}" up --remove-orphans

# On stop: bring containers down gracefully
ExecStop=${docker_bin} ${compose_args} --env-file "${ENV_FILE}" stop

# Clean up bind mount left by FUSE propagation
ExecStopPost=-/bin/bash -c "umount -l '\$MOUNT_DIR' || true"

Restart=on-failure
RestartSec=10

WorkingDirectory="${INSTALL_DIR}"
TimeoutStartSec=120
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    # Reload systemd and enable the service
    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}.service" 2>/dev/null ||
        log_warn "Could not enable systemd service. Auto-start on boot may not work (non-systemd system?)."

    log_info "Systemd service '${service_name}' created and enabled."
    log_info "Services will auto-start with mount propagation on every boot."
}

# ============================================================================
#  Auto-Configure *arrs via API
#  (download clients, root folders, media management, naming, quality profiles,
#   Prowlarr apps & proxy)
# ============================================================================

# Helper: Configure a Radarr/Sonarr service (download client, root folder, media mgmt, naming, quality)
configure_arr_service() {
    local name="$1" url="$2" api_key="$3" container="$4" port="$5" root_path="$6" naming_updates="$7"
    local internal_url="http://${container}:${port}"
    local cat_field="movieCategory" cat_imported_field="movieImportedCategory"
    local unmonitor_field="autoUnmonitorPreviouslyDownloadedMovies"
    if [[ "$name" == "Sonarr" ]]; then
        cat_field="tvCategory"
        cat_imported_field="tvImportedCategory"
        unmonitor_field="autoUnmonitorPreviouslyDownloadedEpisodes"
    fi

    log_step "Configuring ${name}..."

    # Add download client (Decypharr as qBittorrent mock)
    local existing_dc
    existing_dc=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/downloadclient" 2>/dev/null) || true
    if ! echo "$existing_dc" | grep -q '"name":"Decypharr"' 2>/dev/null && ! echo "$existing_dc" | grep -q '"name": "Decypharr"' 2>/dev/null; then
        local dc_json
        dc_json=$(
            cat <<DCJSON_EOF
{
    "name": "Decypharr",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "protocol": "torrent",
    "enable": true,
    "priority": 1,
    "removeCompletedDownloads": true,
    "removeFailedDownloads": true,
    "fields": [
        {"name": "host", "value": "decypharr"},
        {"name": "port", "value": 8282},
        {"name": "useSsl", "value": false},
        {"name": "username", "value": "${internal_url}"},
        {"name": "password", "value": "${api_key}"},
        {"name": "${cat_field}", "value": "${container}"},
        {"name": "${cat_imported_field}", "value": ""},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": false},
        {"name": "firstAndLastFirst", "value": false}
    ],
    "tags": []
}
DCJSON_EOF
        )
        curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
            "${url}/api/v3/downloadclient?forceSave=true" \
            -d "$dc_json" -o /dev/null && log_info "  Download client 'Decypharr' added to ${name}." ||
            log_warn "  Failed to add download client to ${name}."
    else
        log_info "  ${name} already has Decypharr download client configured."
    fi

    # Add root folder
    local existing_rf
    existing_rf=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/rootfolder" 2>/dev/null) || true
    if ! echo "$existing_rf" | grep -qF "\"${root_path}\"" 2>/dev/null; then
        curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
            "${url}/api/v3/rootfolder" \
            -d '{"path": "'"${root_path}"'"}' -o /dev/null && log_info "  Root folder '${root_path}' added to ${name}." ||
            log_warn "  Failed to add root folder to ${name}."
    else
        log_info "  ${name} already has root folder '${root_path}' configured."
    fi

    # Advanced configuration (requires jq for JSON manipulation)
    if [[ "${HAS_JQ:-false}" == "true" ]]; then
        update_arr_config "${name}" "$url" "$api_key" "config/mediamanagement" \
            ".copyUsingHardlinks = false | .importExtraFiles = true | .extraFileExtensions = \"srt,sub,idx,ass,ssa,nfo\" | .${unmonitor_field} = false | .recycleBin = \"\" | .recycleBinCleanupDays = 0 | .minimumFreeSpaceWhenImporting = 100" &&
            log_info "  Media management configured (hardlinks disabled for debrid)." ||
            log_warn "  Failed to configure media management."

        update_arr_config "${name}" "$url" "$api_key" "config/naming" "${naming_updates}" &&
            log_info "  Naming conventions configured." ||
            log_warn "  Failed to configure naming."

        configure_quality_profiles "${name}" "$url" "$api_key" &&
            log_info "  Quality profiles updated (upgrades enabled)." ||
            log_warn "  Failed to update quality profiles."
    fi

    # Add Plex notification so library updates happen immediately on import
    if [[ "${MEDIA_SERVER}" == "plex" ]]; then
        local existing_notifs
        existing_notifs=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/notification" 2>/dev/null) || true
        if ! echo "$existing_notifs" | grep -q '"implementation":"PlexServer"' 2>/dev/null && ! echo "$existing_notifs" | grep -q '"implementation": "PlexServer"' 2>/dev/null; then
            local plex_token=""
            local plex_prefs="${CONFIG_DIR}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
            if [[ -f "$plex_prefs" ]]; then
                plex_token=$(sed -n 's/.*PlexOnlineToken="\([^"][^"]*\)".*/\1/p' "$plex_prefs" 2>/dev/null) || true
            fi
            if [[ -n "$plex_token" ]]; then
                local on_download_field="onDownload" on_upgrade_field="onUpgrade"
                local on_delete_field="onMovieFileDelete" on_delete_upgrade_field="onMovieFileDeleteForUpgrade"
                local on_rename_field="onRename"
                if [[ "$name" == "Sonarr" ]]; then
                    on_delete_field="onEpisodeFileDelete"
                    on_delete_upgrade_field="onEpisodeFileDeleteForUpgrade"
                fi
                curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
                    "${url}/api/v3/notification" \
                    -d @- -o /dev/null <<EOF && log_info "  Plex notification added to ${name} (instant library updates)." || log_warn "  Failed to add Plex notification to ${name}."
                    {
                        "name": "Plex",
                        "implementation": "PlexServer",
                        "configContract": "PlexServerSettings",
                        "${on_download_field}": true,
                        "${on_upgrade_field}": true,
                        "${on_rename_field}": true,
                        "${on_delete_field}": true,
                        "${on_delete_upgrade_field}": true,
                        "fields": [
                            {"name": "host", "value": "plex"},
                            {"name": "port", "value": 32400},
                            {"name": "useSsl", "value": false},
                            {"name": "authToken", "value": "${plex_token}"},
                            {"name": "updateLibrary", "value": true}
                        ]
                    }
EOF
            else
                log_warn "  Plex token not found — skipping Plex notification for ${name}. You can add it manually in ${name} → Settings → Connect."
            fi
        else
            log_info "  ${name} already has Plex notification configured."
        fi
    fi
}

# Helper: GET a *arr config section, modify fields with jq, PUT it back
update_arr_config() {
    local name="$1" url="$2" api_key="$3" endpoint="$4" jq_updates="$5"
    local config config_id updated

    config=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/${endpoint}" 2>/dev/null) || true
    [[ -z "$config" ]] && {
        log_warn "  Could not retrieve ${name} ${endpoint}."
        return 1
    }

    config_id=$(echo "$config" | jq -r '.id' 2>/dev/null) || true
    [[ -z "$config_id" || "$config_id" == "null" ]] && {
        log_warn "  Could not parse ${name} ${endpoint} ID."
        return 1
    }

    updated=$(echo "$config" | jq "$jq_updates" 2>/dev/null) || true
    [[ -z "$updated" ]] && {
        log_warn "  Could not update ${name} ${endpoint}."
        return 1
    }

    curl -sf --connect-timeout 5 --max-time 15 -X PUT -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
        "${url}/api/v3/${endpoint}/${config_id}" -d "$updated" -o /dev/null 2>/dev/null
}

# Helper: Enable quality profile upgrades on all existing profiles
configure_quality_profiles() {
    local name="$1" url="$2" api_key="$3"

    local profiles
    profiles=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/qualityprofile" 2>/dev/null) || true
    [[ -z "$profiles" || "$profiles" == "[]" ]] && return 0

    local updated_profiles
    updated_profiles=$(echo "$profiles" | jq '[.[] | .upgradeAllowed = true]' 2>/dev/null) || true
    [[ -z "$updated_profiles" || "$updated_profiles" == "[]" ]] && return 1

    local ok=0
    local profile_ids=()
    mapfile -t profile_ids < <(echo "$updated_profiles" | jq -r '.[].id' 2>/dev/null)
    for pid in "${profile_ids[@]}"; do
        local profile_data
        profile_data=$(echo "$updated_profiles" | jq --argjson id "$pid" '.[] | select(.id == $id)' 2>/dev/null) || true
        if curl -sf --connect-timeout 5 --max-time 15 -X PUT \
            -H "Content-Type: application/json" \
            -H "X-Api-Key: ${api_key}" \
            "${url}/api/v3/qualityprofile/${pid}" \
            -d "$profile_data" -o /dev/null 2>/dev/null; then
            ok=$((ok + 1))
        fi
    done
    [[ $ok -gt 0 ]] && return 0 || return 1
}

wait_for_service() {
    local name="$1" url="$2" api_key="$3" max_wait="${4:-90}" api_ver="${5:-v3}"
    local elapsed=0 interval=2
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    log_step "Waiting for ${name} to be ready..."
    while [[ $elapsed -lt $max_wait ]]; do
        if curl -sf --connect-timeout 3 --max-time 10 -o /dev/null -H "X-Api-Key: ${api_key}" "${url}/api/${api_ver}/system/status" 2>/dev/null; then
            printf "\r  %-50s\n" ""
            log_info "${name} is ready. (${elapsed}s)"
            return 0
        fi
        local i=0
        for ((i = 0; i < interval; i++)); do
            printf "\r  %s Waiting for %s... %ds/%ds" "${spin_chars:(elapsed + i)%${#spin_chars}:1}" "$name" "$((elapsed + i))" "$max_wait"
            sleep 1
        done
        elapsed=$((elapsed + interval))
    done
    printf "\r  %-50s\n" ""
    log_warn "${name} did not become ready within ${max_wait}s. Skipping auto-config."
    return 1
}

configure_arrs() {
    log_section "Auto-Configuring Services via API"

    # jq is needed for JSON manipulation in advanced config
    HAS_JQ=false
    if command -v jq &>/dev/null; then
        HAS_JQ=true
    else
        log_warn "jq not found. Advanced config (naming, media management, quality profiles) will be skipped."
    fi

    local radarr_url="http://localhost:${SVC_PORTS[radarr]}"
    local sonarr_url="http://localhost:${SVC_PORTS[sonarr]}"
    local prowlarr_url="http://localhost:${SVC_PORTS[prowlarr]}"

    # Wait for all three services (Prowlarr uses API v1, Radarr/Sonarr use v3)
    local radarr_ready=false sonarr_ready=false prowlarr_ready=false
    if wait_for_service "Radarr" "$radarr_url" "$RADARR_API_KEY" 90 "v3"; then
        radarr_ready=true
        sleep 3 # Allow SQLite database to fully initialize after HTTP readiness
    fi
    if wait_for_service "Sonarr" "$sonarr_url" "$SONARR_API_KEY" 90 "v3"; then
        sonarr_ready=true
        sleep 3
    fi
    if wait_for_service "Prowlarr" "$prowlarr_url" "$PROWLARR_API_KEY" 90 "v1"; then
        prowlarr_ready=true
        sleep 3
    fi

    # --- Radarr ---
    if [[ "$radarr_ready" == "true" ]]; then
        local radarr_naming='.renameMovies = true | .replaceIllegalCharacters = true | .colonReplacementFormat = "dash" | .standardMovieFormat = "{Movie CleanTitle} ({Release Year}) [{Quality Full}]" | .movieFolderFormat = "{Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]"'
        configure_arr_service "Radarr" "$radarr_url" "$RADARR_API_KEY" "radarr" 7878 "/data/media/movies" "$radarr_naming"
    fi

    # --- Sonarr ---
    if [[ "$sonarr_ready" == "true" ]]; then
        local sonarr_naming='.renameEpisodes = true | .replaceIllegalCharacters = true | .colonReplacementFormat = 4 | .standardEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]" | .dailyEpisodeFormat = "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Quality Full}]" | .animeEpisodeFormat = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]" | .seasonFolderFormat = "Season {season:00}" | .seriesFolderFormat = "{Series TitleYear}"'
        configure_arr_service "Sonarr" "$sonarr_url" "$SONARR_API_KEY" "sonarr" 8989 "/data/media/tv" "$sonarr_naming"
    fi

    # --- Prowlarr: Add Radarr & Sonarr as apps, add Byparr as FlareSolverr proxy ---
    if [[ "$prowlarr_ready" == "true" ]]; then
        log_step "Configuring Prowlarr..."

        # Add Byparr as FlareSolverr-compatible indexer proxy
        local existing_proxies
        existing_proxies=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${PROWLARR_API_KEY}" "${prowlarr_url}/api/v1/indexerProxy" 2>/dev/null) || true
        if ! echo "$existing_proxies" | grep -q '"name":"Byparr"' 2>/dev/null && ! echo "$existing_proxies" | grep -q '"name": "Byparr"' 2>/dev/null; then
            curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${PROWLARR_API_KEY}" \
                "${prowlarr_url}/api/v1/indexerProxy?forceSave=true" \
                -d '{
                    "name": "Byparr",
                    "implementation": "FlareSolverr",
                    "configContract": "FlareSolverrSettings",
                    "fields": [
                        {"name": "host", "value": "http://byparr:8191"},
                        {"name": "requestTimeout", "value": 60}
                    ],
                    "tags": []
                }' -o /dev/null && log_info "  Byparr proxy added to Prowlarr." ||
                log_warn "  Failed to add Byparr proxy to Prowlarr."
        else
            log_info "  Prowlarr already has Byparr proxy configured."
        fi

        local existing_apps
        existing_apps=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${PROWLARR_API_KEY}" "${prowlarr_url}/api/v1/applications" 2>/dev/null) || true

        # Add Radarr as an application (check independently)
        if ! echo "$existing_apps" | grep -q '"name":"Radarr"' 2>/dev/null && ! echo "$existing_apps" | grep -q '"name": "Radarr"' 2>/dev/null; then
            curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${PROWLARR_API_KEY}" \
                "${prowlarr_url}/api/v1/applications?forceSave=true" \
                -d '{
                    "name": "Radarr",
                    "implementation": "Radarr",
                    "configContract": "RadarrSettings",
                    "syncLevel": "fullSync",
                    "fields": [
                        {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                        {"name": "baseUrl", "value": "http://radarr:7878"},
                        {"name": "apiKey", "value": "'"${RADARR_API_KEY}"'"},
                        {"name": "syncCategories", "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]}
                    ],
                    "tags": []
                }' -o /dev/null && log_info "  Radarr app added to Prowlarr." ||
                log_warn "  Failed to add Radarr app to Prowlarr."
        else
            log_info "  Prowlarr already has Radarr app configured."
        fi

        # Add Sonarr as an application (check independently)
        if ! echo "$existing_apps" | grep -q '"name":"Sonarr"' 2>/dev/null && ! echo "$existing_apps" | grep -q '"name": "Sonarr"' 2>/dev/null; then
            curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${PROWLARR_API_KEY}" \
                "${prowlarr_url}/api/v1/applications?forceSave=true" \
                -d '{
                    "name": "Sonarr",
                    "implementation": "Sonarr",
                    "configContract": "SonarrSettings",
                    "syncLevel": "fullSync",
                    "fields": [
                        {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                        {"name": "baseUrl", "value": "http://sonarr:8989"},
                        {"name": "apiKey", "value": "'"${SONARR_API_KEY}"'"},
                        {"name": "syncCategories", "value": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]}
                    ],
                    "tags": []
                }' -o /dev/null && log_info "  Sonarr app added to Prowlarr." ||
                log_warn "  Failed to add Sonarr app to Prowlarr."
        else
            log_info "  Prowlarr already has Sonarr app configured."
        fi
    fi

    echo ""
    log_info "Core auto-configuration complete."

    # --- Additional auto-config (each logs its own success/failure) ---
    echo ""
    local _failed=0

    configure_seerr || _failed=$((_failed + 1))

    configure_plex_libraries || _failed=$((_failed + 1))

    if [[ "$prowlarr_ready" == "true" ]]; then
        add_default_indexer || _failed=$((_failed + 1))
    fi

    if [[ "$radarr_ready" == "true" ]]; then
        configure_arr_auth "Radarr" "$radarr_url" "$RADARR_API_KEY" || _failed=$((_failed + 1))
    fi
    if [[ "$sonarr_ready" == "true" ]]; then
        configure_arr_auth "Sonarr" "$sonarr_url" "$SONARR_API_KEY" || _failed=$((_failed + 1))
    fi
    if [[ "$prowlarr_ready" == "true" ]]; then
        configure_arr_auth "Prowlarr" "$prowlarr_url" "$PROWLARR_API_KEY" "v1" || _failed=$((_failed + 1))
    fi

    echo ""
    if [[ $_failed -eq 0 ]]; then
        log_info "All auto-configuration steps completed successfully."
    else
        log_warn "${_failed} auto-config step(s) had warnings. Check the output above for details."
        log_warn "You can fix these manually via the web UI, or re-run ./setup.sh to retry."
    fi
}

# ============================================================================
#  Auto-Configure Seerr via API
# ============================================================================

configure_seerr() {
    log_step "Auto-configuring Seerr..."

    local seerr_url="http://localhost:${SVC_PORTS[seerr]}"
    local max_wait=60 elapsed=0 interval=3
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    # Wait for Seerr API to be ready (hitting / returns HTML before init completes)
    while [[ $elapsed -lt $max_wait ]]; do
        if curl -sf --connect-timeout 3 --max-time 10 -o /dev/null "${seerr_url}/api/v1/status" 2>/dev/null; then
            printf "\r  %-50s\n" ""
            log_info "Seerr is ready. (${elapsed}s)"
            # Give Seerr a moment to fully initialize after API responds
            sleep 3
            break
        fi
        printf "\r  %s Waiting for Seerr... %ds/%ds" "${spin_chars:elapsed/interval%${#spin_chars}:1}" "$elapsed" "$max_wait"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    printf "\r  %-50s\n" ""

    if [[ $elapsed -ge $max_wait ]]; then
        log_warn "Seerr did not become ready within ${max_wait}s. Skipping Seerr auto-config."
        return 1
    fi

    # Get current Seerr Radarr settings
    local radarr_settings
    radarr_settings=$(curl -sf --connect-timeout 5 --max-time 15 "${seerr_url}/api/v1/settings/radarr" 2>/dev/null) || true

    # Check if Radarr is already configured
    if [[ -n "$radarr_settings" ]] && (echo "$radarr_settings" | grep -q '"hostname":"radarr"' 2>/dev/null ||
        echo "$radarr_settings" | grep -q '"hostname": "radarr"' 2>/dev/null); then
        log_info "  Seerr already has Radarr configured."
    else
        # Query Radarr's default quality profile
        local radarr_profile_id=1 radarr_profile_name="HD-1080p"
        local radarr_profiles
        radarr_profiles=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${RADARR_API_KEY}" \
            "http://localhost:${SVC_PORTS[radarr]}/api/v3/qualityprofile" 2>/dev/null) || true
        if [[ -n "$radarr_profiles" ]]; then
            local _id _name
            _id=$(echo "$radarr_profiles" | jq -r '.[0].id // empty' 2>/dev/null) || true
            _name=$(echo "$radarr_profiles" | jq -r '.[0].name // empty' 2>/dev/null) || true
            [[ -n "$_id" ]] && radarr_profile_id="$_id"
            [[ -n "$_name" ]] && radarr_profile_name="$_name"
        fi
        # Add Radarr to Seerr
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            "${seerr_url}/api/v1/settings/radarr" \
            -d '{
                "name": "Radarr",
                "hostname": "radarr",
                "port": 7878,
                "apiKey": "'"${RADARR_API_KEY}"'",
                "useSsl": false,
                "baseUrl": "",
                "activeProfileId": '"${radarr_profile_id}"',
                "activeProfileName": "'"${radarr_profile_name}"'",
                "activeDirectory": "/data/media/movies",
                "is4k": false,
                "minimumAvailability": "released",
                "tags": [],
                "isDefault": true,
                "externalUrl": ""
            }' -o /dev/null 2>/dev/null && log_info "  Radarr added to Seerr (profile: ${radarr_profile_name})." ||
            log_warn "  Failed to add Radarr to Seerr. You can configure it manually."
    fi

    # Get current Seerr Sonarr settings
    local sonarr_settings
    sonarr_settings=$(curl -sf --connect-timeout 5 --max-time 15 "${seerr_url}/api/v1/settings/sonarr" 2>/dev/null) || true

    # Check if Sonarr is already configured
    if [[ -n "$sonarr_settings" ]] && (echo "$sonarr_settings" | grep -q '"hostname":"sonarr"' 2>/dev/null ||
        echo "$sonarr_settings" | grep -q '"hostname": "sonarr"' 2>/dev/null); then
        log_info "  Seerr already has Sonarr configured."
    else
        # Query Sonarr's default quality profile
        local sonarr_profile_id=1 sonarr_profile_name="HD-1080p"
        local sonarr_profiles
        sonarr_profiles=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${SONARR_API_KEY}" \
            "http://localhost:${SVC_PORTS[sonarr]}/api/v3/qualityprofile" 2>/dev/null) || true
        if [[ -n "$sonarr_profiles" ]]; then
            local _id _name
            _id=$(echo "$sonarr_profiles" | jq -r '.[0].id // empty' 2>/dev/null) || true
            _name=$(echo "$sonarr_profiles" | jq -r '.[0].name // empty' 2>/dev/null) || true
            [[ -n "$_id" ]] && sonarr_profile_id="$_id"
            [[ -n "$_name" ]] && sonarr_profile_name="$_name"
        fi
        # Add Sonarr to Seerr
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            "${seerr_url}/api/v1/settings/sonarr" \
            -d '{
                "name": "Sonarr",
                "hostname": "sonarr",
                "port": 8989,
                "apiKey": "'"${SONARR_API_KEY}"'",
                "useSsl": false,
                "baseUrl": "",
                "activeProfileId": '"${sonarr_profile_id}"',
                "activeProfileName": "'"${sonarr_profile_name}"'",
                "activeDirectory": "/data/media/tv",
                "is4k": false,
                "tags": [],
                "isDefault": true,
                "externalUrl": ""
            }' -o /dev/null 2>/dev/null && log_info "  Sonarr added to Seerr (profile: ${sonarr_profile_name})." ||
            log_warn "  Failed to add Sonarr to Seerr. You can configure it manually."
    fi

    # Configure Plex or Jellyfin connection in Seerr
    if [[ "${MEDIA_SERVER}" == "plex" ]]; then
        local plex_token=""
        local plex_prefs="${CONFIG_DIR}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
        if [[ -f "$plex_prefs" ]]; then
            plex_token=$(sed -n 's/.*PlexOnlineToken="\([^"][^"]*\)".*/\1/p' "$plex_prefs" 2>/dev/null) || true
        fi
        if [[ -n "$plex_token" ]]; then
            curl -sf --connect-timeout 5 --max-time 15 -X POST \
                -H "Content-Type: application/json" \
                "${seerr_url}/api/v1/settings/plex" \
                -d '{
                    "name": "Plex",
                    "ip": "plex",
                    "port": 32400,
                    "useSsl": false,
                    "libraries": [],
                    "webAppUrl": "http://localhost:32400/web"
                }' -o /dev/null 2>/dev/null && log_info "  Plex server added to Seerr." ||
                log_warn "  Failed to add Plex to Seerr. You can configure it manually."
        fi
    else
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            "${seerr_url}/api/v1/settings/jellyfin" \
            -d '{
                "name": "Jellyfin",
                "ip": "jellyfin",
                "port": 8096,
                "useSsl": false,
                "externalUrl": "",
                "libraries": []
            }' -o /dev/null 2>/dev/null && log_info "  Jellyfin server added to Seerr." ||
            log_warn "  Failed to add Jellyfin to Seerr. You can configure it manually."
    fi
}

# ============================================================================
#  Auto-Configure Plex Libraries via API
# ============================================================================

configure_plex_libraries() {
    if [[ "${MEDIA_SERVER}" != "plex" ]]; then
        return 0
    fi

    log_step "Auto-configuring Plex libraries..."

    local plex_url="http://localhost:32400"
    local max_wait=90 elapsed=0 interval=3
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    # Wait for Plex to be claimed and ready
    while [[ $elapsed -lt $max_wait ]]; do
        local plex_identity
        plex_identity=$(curl -sf --connect-timeout 3 --max-time 10 "${plex_url}/identity" 2>/dev/null) || true
        if [[ -n "$plex_identity" ]]; then
            # Check if Plex has been claimed (has a token)
            local plex_prefs="${CONFIG_DIR}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
            if [[ -f "$plex_prefs" ]] && grep -q 'PlexOnlineToken=' "$plex_prefs" 2>/dev/null; then
                printf "\r  %-50s\n" ""
                break
            fi
        fi
        printf "\r  %s Waiting for Plex to be claimed... %ds/%ds" "${spin_chars:elapsed/interval%${#spin_chars}:1}" "$elapsed" "$max_wait"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    printf "\r  %-50s\n" ""

    if [[ $elapsed -ge $max_wait ]]; then
        log_warn "Plex was not claimed within ${max_wait}s. Skipping library auto-config."
        log_warn "  Complete the Plex setup wizard, then add libraries manually."
        return 1
    fi

    # Extract Plex token
    local plex_token=""
    local plex_prefs="${CONFIG_DIR}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
    plex_token=$(sed -n 's/.*PlexOnlineToken="\([^"][^"]*\)".*/\1/p' "$plex_prefs" 2>/dev/null) || true

    if [[ -z "$plex_token" ]]; then
        log_warn "  Could not extract Plex token. Skipping library auto-config."
        return 1
    fi

    # Pass Plex token via header directly (avoid writing to /tmp)
    local plex_auth_header="X-Plex-Token: ${plex_token}"

    # Check if libraries already exist
    local existing_libs
    existing_libs=$(curl -sf --connect-timeout 5 --max-time 15 -H "${plex_auth_header}" "${plex_url}/library/sections" 2>/dev/null) || true

    if echo "$existing_libs" | grep -q 'title="Movies"' 2>/dev/null; then
        log_info "  Plex 'Movies' library already exists."
    else
        # Add Movies library
        curl -sf --connect-timeout 5 --max-time 15 -X POST -H "${plex_auth_header}" \
            "${plex_url}/library/sections?name=Movies&type=movie&agent=tv.plex.agents.movie&scanner=Plex%20Movie&language=en&location=%2Fdata%2Fmedia%2Fmovies" \
            -o /dev/null 2>/dev/null && log_info "  Plex 'Movies' library added." ||
            log_warn "  Failed to add Movies library. You can add it manually in Plex."
    fi

    if echo "$existing_libs" | grep -q 'title="TV Shows"' 2>/dev/null; then
        log_info "  Plex 'TV Shows' library already exists."
    else
        # Add TV Shows library
        curl -sf --connect-timeout 5 --max-time 15 -X POST -H "${plex_auth_header}" \
            "${plex_url}/library/sections?name=TV%20Shows&type=show&agent=tv.plex.agents.series&scanner=Plex%20Series&language=en&location=%2Fdata%2Fmedia%2Ftv" \
            -o /dev/null 2>/dev/null && log_info "  Plex 'TV Shows' library added." ||
            log_warn "  Failed to add TV Shows library. You can add it manually in Plex."
    fi

    # Remove expired claim token from .env (token expires in 4 min and is single-use)
    if [[ -f "${ENV_FILE}" ]]; then
        # Use a temp file and explicitly restore 600 perms — the grep+mv pattern
        # would otherwise inherit the default umask (typically 644), leaking
        # every secret in .env (TORBOX_API_KEY, *_ADMIN_PASS, DECYPHARR_PASS).
        grep -v '^PLEX_CLAIM=' "${ENV_FILE}" >"${ENV_FILE}.tmp" 2>/dev/null
        if [[ -s "${ENV_FILE}.tmp" ]]; then
            mv "${ENV_FILE}.tmp" "${ENV_FILE}"
            chmod 600 "${ENV_FILE}"
            log_info "  Plex claim token removed from .env (expired after first use)."
        else
            rm -f "${ENV_FILE}.tmp"
        fi
    fi
}

# ============================================================================
#  Pre-add Default Public Indexer to Prowlarr
# ============================================================================

add_default_indexer() {
    log_step "Adding default indexer to Prowlarr..."

    local prowlarr_url="http://localhost:${SVC_PORTS[prowlarr]}"

    # Check if any indexers already exist
    local existing_indexers
    existing_indexers=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${PROWLARR_API_KEY}" "${prowlarr_url}/api/v1/indexer" 2>/dev/null) || true
    if [[ -n "$existing_indexers" && "$existing_indexers" != "[]" ]]; then
        log_info "  Prowlarr already has indexers configured."
        return 0
    fi

    # Add default public indexer (configurable URL, validated to prevent JSON injection)
    local indexer_url="${TORBOX_INDEXER_URL:-https://1337x.to}"
    if [[ ! "$indexer_url" =~ ^https?://[a-zA-Z0-9._:/-]+$ ]]; then
        log_warn "TORBOX_INDEXER_URL has invalid format (must start with http(s):// and contain only safe chars). Using default."
        indexer_url="https://1337x.to"
    fi
    curl -sf --connect-timeout 5 --max-time 15 -X POST \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${PROWLARR_API_KEY}" \
        "${prowlarr_url}/api/v1/indexer" \
        -d '{
            "name": "1337x",
            "fields": [
                {"name": "baseUrl", "value": "'"${indexer_url}"'"},
                {"name": "apiPath", "value": ""},
                {"name": "apiKey", "value": ""},
                {"name": "queryLimit", "value": 0}
            ],
            "configContract": "1337xSettings",
            "implementation": "1337x",
            "implementationName": "1337x",
            "infoLink": "https://wiki.servarr.com/prowlarr/supported#1337x",
            "protocol": "torrent",
            "supportsRss": true,
            "supportsSearch": true,
            "categories": [
                {"id": 2000, "name": "Movies"},
                {"id": 5000, "name": "TV"}
            ]
        }' -o /dev/null 2>/dev/null && log_info "  Default indexer '1337x' added to Prowlarr (${indexer_url})." ||
        log_warn "  Failed to add default indexer. You can add indexers manually in Prowlarr."
}

# ============================================================================
#  Auto-Configure Authentication for *arr Services
# ============================================================================

configure_arr_auth() {
    local name="$1" url="$2" api_key="$3" api_ver="${4:-v3}"

    log_step "Configuring ${name} authentication..."

    # Check current auth config
    local auth_config
    auth_config=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/${api_ver}/config/host" 2>/dev/null) || true
    [[ -z "$auth_config" ]] && {
        log_warn "  Could not retrieve ${name} auth config."
        return 1
    }

    # Apply credentials from .env regardless of current auth state.
    # The *arr may have AuthenticationRequired=DisabledForLocalAddresses on first boot;
    # even if Forms is already set, the stored username/password may not match .env
    # (e.g. previous setup.sh run that skipped the PUT, or a manual config change).
    # Always push to ensure .env and the service stay in sync.

    # Reuse credentials already generated in gather_config() / read back from .env.
    # Generating NEW credentials here would desynchronize the .env file (which already
    # has the previously-generated pair) from what the *arr service actually accepts.
    local admin_user admin_pass
    case "$name" in
        Radarr)
            admin_user="${RADARR_ADMIN_USER:-admin}"
            admin_pass="${RADARR_ADMIN_PASS:-}"
            ;;
        Sonarr)
            admin_user="${SONARR_ADMIN_USER:-admin}"
            admin_pass="${SONARR_ADMIN_PASS:-}"
            ;;
        Prowlarr)
            admin_user="${PROWLARR_ADMIN_USER:-admin}"
            admin_pass="${PROWLARR_ADMIN_PASS:-}"
            ;;
    esac

    # Fallback: generate fresh credentials if (for any reason) none are set yet.
    if [[ -z "$admin_pass" ]]; then
        admin_pass="$(openssl rand -base64 16 2>/dev/null | tr -d '/+=' | head -c 16)"
        if [[ -z "$admin_pass" ]]; then
            admin_pass="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
        fi
        log_warn "  No pre-generated admin password found for ${name}; generated one on the fly."
        case "$name" in
            Radarr)
                RADARR_ADMIN_USER="$admin_user"
                RADARR_ADMIN_PASS="$admin_pass"
                ;;
            Sonarr)
                SONARR_ADMIN_USER="$admin_user"
                SONARR_ADMIN_PASS="$admin_pass"
                ;;
            Prowlarr)
                PROWLARR_ADMIN_USER="$admin_user"
                PROWLARR_ADMIN_PASS="$admin_pass"
                ;;
        esac
    fi

    # Set auth to Forms with Enabled (always require login)
    local auth_id
    auth_id=$(echo "$auth_config" | jq -r '.id' 2>/dev/null) || true
    [[ -z "$auth_id" || "$auth_id" == "null" ]] && {
        log_warn "  Could not parse ${name} auth config ID."
        return 1
    }

    local updated_auth
    updated_auth=$(echo "$auth_config" | jq \
        --arg user "$admin_user" \
        --arg pass "$admin_pass" \
        '.authenticationMethod = "Forms" | .authenticationRequired = "Enabled" | .username = $user | .password = $pass | .passwordConfirmation = $pass' 2>/dev/null) || true
    [[ -z "$updated_auth" ]] && {
        log_warn "  Could not update ${name} auth config."
        return 1
    }

    if echo "$updated_auth" | curl -sf --connect-timeout 5 --max-time 15 -X PUT \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${api_key}" \
        "${url}/api/${api_ver}/config/host/${auth_id}" \
        -d @- -o /dev/null 2>/dev/null; then
        log_info "  ${name} auth set to Forms (Enabled) with auto-generated credentials."
        local env_key_prefix
        case "$name" in
            Radarr) env_key_prefix="RADARR_ADMIN" ;;
            Sonarr) env_key_prefix="SONARR_ADMIN" ;;
            Prowlarr) env_key_prefix="PROWLARR_ADMIN" ;;
        esac

        # Remove old entries and append new ones
        grep -v "^${env_key_prefix}_USER=\|^${env_key_prefix}_PASS=" "${ENV_FILE}" >"${ENV_FILE}.tmp" 2>/dev/null || true
        echo "${env_key_prefix}_USER=\"${admin_user}\"" >>"${ENV_FILE}.tmp"
        echo "${env_key_prefix}_PASS=\"${admin_pass}\"" >>"${ENV_FILE}.tmp"
        mv "${ENV_FILE}.tmp" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
    else
        log_warn "  Failed to configure ${name} auth."
    fi
}

# ============================================================================
#  Post-Install Configuration Guide
# ============================================================================

print_post_install() {
    log_section "Setup Complete!"

    echo -e "${GREEN}All files have been generated at:${NC} ${INSTALL_DIR}"
    echo ""

    echo -e "${BOLD}━━━━ Service URLs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    print_service_urls

    echo ""
    echo -e "${BOLD}━━━━ Pre-Seeded API Keys ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Radarr${NC}    $(mask_key "${RADARR_API_KEY}")"
    echo -e "  ${BOLD}Sonarr${NC}    $(mask_key "${SONARR_API_KEY}")"
    echo -e "  ${BOLD}Prowlarr${NC}  $(mask_key "${PROWLARR_API_KEY}")"
    echo -e "  ${YELLOW}View full keys with:${NC} cd ${INSTALL_DIR} && ./manage.sh keys"
    echo ""

    if [[ "$SERVICES_STARTED" == "true" && -n "${RADARR_ADMIN_PASS:-}" ]]; then
        echo -e "${BOLD}━━━━ Auto-Generated Admin Credentials ━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${YELLOW}Save these credentials — you will need them to log in.${NC}"
        echo ""
        echo -e "  ${BOLD}Radarr${NC}    Username: ${RADARR_ADMIN_USER}  Password: ${RADARR_ADMIN_PASS}"
        echo -e "  ${BOLD}Sonarr${NC}    Username: ${SONARR_ADMIN_USER}  Password: ${SONARR_ADMIN_PASS}"
        echo -e "  ${BOLD}Prowlarr${NC}  Username: ${PROWLARR_ADMIN_USER}  Password: ${PROWLARR_ADMIN_PASS}"
        echo ""
    fi

    if [[ "$SERVICES_STARTED" == "true" ]]; then
        echo -e "${BOLD}━━━━ Auto-Configured (already done for you) ━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${GREEN}✓${NC} Decypharr config (TorBox API key, WebDAV, rclone mount)"
        echo -e "  ${GREEN}✓${NC} Radarr/Sonarr/Prowlarr API keys pre-seeded in config.xml"
        echo -e "  ${GREEN}✓${NC} Radarr download client (Decypharr as qBittorrent)"
        echo -e "  ${GREEN}✓${NC} Radarr root folder (/data/media/movies)"
        echo -e "  ${GREEN}✓${NC} Radarr media management (hardlinks disabled for debrid)"
        echo -e "  ${GREEN}✓${NC} Radarr naming conventions (Plex/Jellyfin compatible)"
        echo -e "  ${GREEN}✓${NC} Radarr quality profiles (upgrades enabled)"
        echo -e "  ${GREEN}✓${NC} Sonarr download client (Decypharr as qBittorrent)"
        echo -e "  ${GREEN}✓${NC} Sonarr root folder (/data/media/tv)"
        echo -e "  ${GREEN}✓${NC} Sonarr media management (hardlinks disabled for debrid)"
        echo -e "  ${GREEN}✓${NC} Sonarr naming conventions (Plex/Jellyfin compatible)"
        echo -e "  ${GREEN}✓${NC} Sonarr quality profiles (upgrades enabled)"
        echo -e "  ${GREEN}✓${NC} Prowlarr Byparr proxy (FlareSolverr-compatible)"
        echo -e "  ${GREEN}✓${NC} Prowlarr default indexer (1337x)"
        echo -e "  ${GREEN}✓${NC} Prowlarr Radarr app connection"
        echo -e "  ${GREEN}✓${NC} Prowlarr Sonarr app connection"
        echo -e "  ${GREEN}✓${NC} Seerr Radarr & Sonarr connection"
        if [[ "$MEDIA_SERVER" == "plex" ]]; then
            echo -e "  ${GREEN}✓${NC} Radarr Plex notification (instant library updates)"
            echo -e "  ${GREEN}✓${NC} Sonarr Plex notification (instant library updates)"
            echo -e "  ${GREEN}✓${NC} Plex libraries (Movies + TV Shows)"
            echo -e "  ${GREEN}✓${NC} Seerr Plex server connection"
        else
            echo -e "  ${GREEN}✓${NC} Seerr Jellyfin server connection"
        fi
        echo ""
    fi

    echo -e "${BOLD}━━━━ Auto-Start on Boot ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [[ "${HAS_SYSTEMD:-true}" == "true" ]]; then
        echo -e "  ${GREEN}✓${NC} Systemd service ${BOLD}torbox-media-server${NC} installed and enabled."
        echo "    Mount propagation and all containers start automatically on boot."
        echo "    To disable: sudo systemctl disable torbox-media-server"
        echo "    To re-enable: ./manage.sh enable"
    else
        echo -e "  ${YELLOW}⚠${NC} Systemd not available. Auto-start on boot was not configured."
        echo "    Use './manage.sh start' to start services manually after reboot."
    fi
    echo ""

    echo -e "${BOLD}━━━━ Remaining Manual Steps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}1. Decypharr (do first)${NC}"
    echo "   • Open http://localhost:8282"
    echo -e "   • ${GREEN}Credentials pre-seeded ✓${NC}"
    echo -e "   •   Username: ${BOLD}${DECYPHARR_USER:-torbox}${NC}"
    echo -e "   •   Password: ${BOLD}${DECYPHARR_PASS:-<see .env>}${NC}"
    echo -e "   • ${GREEN}TorBox API key pre-configured ✓${NC}"
    echo -e "   • ${GREEN}Rclone Folder set to /mnt/remote/torbox/__all__ ✓${NC}"
    echo -e "   • ${GREEN}WebDAV enabled ✓${NC}"
    echo -e "   • ${GREEN}Rclone mount enabled, path /mnt/remote ✓${NC}"
    echo "   • After logging in, verify the above in Debrid & Rclone tabs"
    echo ""
    echo -e "${CYAN}2. Prowlarr${NC}"
    echo "   • Open http://localhost:9696"
    if [[ "$SERVICES_STARTED" == "true" && -n "${PROWLARR_ADMIN_PASS:-}" ]]; then
        echo -e "   • ${GREEN}Credentials pre-seeded ✓${NC}"
        echo -e "   •   Username: ${BOLD}${PROWLARR_ADMIN_USER}${NC}"
        echo -e "   •   Password: ${BOLD}${PROWLARR_ADMIN_PASS}${NC}"
    else
        echo -e "   • ${YELLOW}Create login credentials (Settings → General → Authentication)${NC}"
    fi
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        echo -e "   • ${GREEN}Byparr proxy already configured ✓${NC}"
        echo -e "   • ${GREEN}Radarr & Sonarr apps already connected ✓${NC}"
        echo -e "   • ${GREEN}Default indexer (1337x) already added ✓${NC}"
    else
        echo "   • Configure Byparr proxy, Radarr/Sonarr apps, and indexers manually (see README)"
    fi
    echo ""
    echo -e "${CYAN}3. Radarr${NC}"
    echo "   • Open http://localhost:7878"
    if [[ "$SERVICES_STARTED" == "true" && -n "${RADARR_ADMIN_PASS:-}" ]]; then
        echo -e "   • ${GREEN}Credentials pre-seeded ✓${NC}"
        echo -e "   •   Username: ${BOLD}${RADARR_ADMIN_USER}${NC}"
        echo -e "   •   Password: ${BOLD}${RADARR_ADMIN_PASS}${NC}"
    else
        echo -e "   • ${YELLOW}Set up authentication (Settings → General → Authentication)${NC}"
    fi
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        echo -e "   • ${GREEN}Download client (Decypharr) already configured ✓${NC}"
        echo -e "   • ${GREEN}Root folder (/data/media/movies) already configured ✓${NC}"
        echo -e "   • ${GREEN}Media management optimized for debrid ✓${NC}"
        echo -e "   • ${GREEN}Naming conventions configured ✓${NC}"
        echo -e "   • ${GREEN}Quality profiles updated (upgrades enabled) ✓${NC}"
    else
        echo "   • Settings → Download Clients → Add → qBittorrent"
        echo "     - Host: decypharr"
        echo "     - Port: 8282"
        echo "     - Username: http://radarr:7878"
        echo "     - Password: (see ./manage.sh keys)"
        echo "     - Category: radarr"
        echo "   • Settings → Media Management → Root Folder: /data/media/movies"
    fi
    echo ""
    echo -e "${CYAN}4. Sonarr${NC}"
    echo "   • Open http://localhost:8989"
    if [[ "$SERVICES_STARTED" == "true" && -n "${SONARR_ADMIN_PASS:-}" ]]; then
        echo -e "   • ${GREEN}Credentials pre-seeded ✓${NC}"
        echo -e "   •   Username: ${BOLD}${SONARR_ADMIN_USER}${NC}"
        echo -e "   •   Password: ${BOLD}${SONARR_ADMIN_PASS}${NC}"
    else
        echo -e "   • ${YELLOW}Set up authentication (Settings → General → Authentication)${NC}"
    fi
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        echo -e "   • ${GREEN}Download client (Decypharr) already configured ✓${NC}"
        echo -e "   • ${GREEN}Root folder (/data/media/tv) already configured ✓${NC}"
        echo -e "   • ${GREEN}Media management optimized for debrid ✓${NC}"
        echo -e "   • ${GREEN}Naming conventions configured ✓${NC}"
        echo -e "   • ${GREEN}Quality profiles updated (upgrades enabled) ✓${NC}"
    else
        echo "   • Settings → Download Clients → Add → qBittorrent"
        echo "     - Host: decypharr"
        echo "     - Port: 8282"
        echo "     - Username: http://sonarr:8989"
        echo "     - Password: (see ./manage.sh keys)"
        echo "     - Category: sonarr"
        echo "   • Settings → Media Management → Root Folder: /data/media/tv"
    fi
    echo ""

    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        echo -e "${CYAN}5. Plex${NC}"
        echo "   • Open http://localhost:32400/web"
        echo "   • Complete initial setup wizard if not yet done"
        if [[ "$SERVICES_STARTED" == "true" ]]; then
            echo -e "   • ${GREEN}Libraries auto-configured (Movies + TV Shows) ✓${NC}"
            echo "   • If libraries are missing, add them manually:"
            echo "     - Movies: /data/media/movies"
            echo "     - TV Shows: /data/media/tv"
        else
            echo "   • Add libraries:"
            echo "     - Movies: /data/media/movies"
            echo "     - TV Shows: /data/media/tv"
        fi
    else
        echo -e "${CYAN}5. Jellyfin${NC}"
        echo "   • Open http://localhost:8096"
        echo "   • Complete initial setup wizard"
        echo "   • Add libraries:"
        echo "     - Movies: /data/media/movies"
        echo "     - TV Shows: /data/media/tv"
    fi

    echo ""
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        echo -e "${CYAN}6. Seerr${NC}"
        echo "   • Open http://localhost:5055"
        if [[ "$MEDIA_SERVER" == "plex" ]]; then
            echo "   • Sign in with your Plex account"
            echo -e "   • ${GREEN}Radarr & Sonarr already connected ✓${NC}"
            echo -e "   • ${GREEN}Plex server already configured ✓${NC}"
        else
            echo "   • Sign in and connect to Jellyfin"
            echo -e "   • ${GREEN}Radarr & Sonarr already connected ✓${NC}"
            echo -e "   • ${GREEN}Jellyfin server already configured ✓${NC}"
        fi
    else
        echo -e "${CYAN}6. Seerr${NC}"
        echo "   • Open http://localhost:5055"
        if [[ "$MEDIA_SERVER" == "plex" ]]; then
            echo "   • Sign in with your Plex account"
            echo -e "   • Connect to Plex using: ${YELLOW}http://plex:32400${NC}"
        else
            echo "   • Sign in and connect to Jellyfin (http://jellyfin:8096)"
        fi
        echo "   • Add Radarr & Sonarr servers"
        echo "     - Radarr: http://radarr:7878 + API key: $(mask_key "${RADARR_API_KEY}")"
        echo "     - Sonarr: http://sonarr:8989 + API key: $(mask_key "${SONARR_API_KEY}")"
    fi
    echo ""

    echo -e "${BOLD}━━━━ Important Notes ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [[ "$SERVICES_STARTED" == "true" && -n "${RADARR_ADMIN_PASS:-}" ]]; then
        echo -e "  ${GREEN}✓  Authentication is enabled on all services.${NC}"
        echo "     Auto-generated credentials were printed above. Change them in each service's"
        echo "     Settings → General → Security after first login."
        echo ""
    else
        echo -e "  ${RED}⚠  Authentication is NOT yet configured on Radarr/Sonarr/Prowlarr.${NC}"
        echo "     Set up credentials in each service's Settings → General → Authentication."
        echo ""
    fi
    echo ""
    if [[ "${HAS_SYSTEMD:-true}" == "true" ]]; then
        echo -e "  ${GREEN}✓  Auto-start on boot is enabled.${NC}"
        echo "     A systemd service (torbox-media-server) handles mount propagation"
        echo "     and starts all containers automatically when your computer boots."
        echo "     To disable: sudo systemctl disable torbox-media-server"
        echo ""
    fi

    echo -e "${BOLD}━━━━ Management ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  cd ${INSTALL_DIR}"
    echo "  ./manage.sh start    # Start all services"
    echo "  ./manage.sh stop     # Stop all services"
    echo "  ./manage.sh status   # Check status"
    echo "  ./manage.sh logs     # View logs"
    echo "  ./manage.sh update   # Pull pinned & restart"
    echo "  ./manage.sh urls     # Show service URLs"
    echo ""

    echo -e "${BOLD}━━━━ Architecture Overview ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  User → Seerr (request) → Radarr/Sonarr (search & manage)"
    echo "    ↓"
    echo "  Prowlarr (indexers + Byparr) → finds torrents"
    echo "    ↓"
    echo "  Radarr/Sonarr → sends torrent to Decypharr (mock qBittorrent)"
    echo "    ↓"
    echo "  Decypharr → TorBox API (cloud download, instant if cached)"
    echo "    ↓"
    echo "  Decypharr mounts TorBox WebDAV via rclone → symlinks files"
    echo "    ↓"
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        echo "  Plex reads symlinked files → streams to your devices"
    else
        echo "  Jellyfin reads symlinked files → streams to your devices"
    fi
    echo ""
    echo -e "  ${YELLOW}No media is stored locally — everything streams from TorBox!${NC}"
    echo ""
}

# ============================================================================
#  Start Services
# ============================================================================

# SERVICES_STARTED is declared once at the top of the file (line 16).

# Globals for re-run detection (set by check_existing_installation)
EXISTING_RADARR_API_KEY=""
EXISTING_SONARR_API_KEY=""
EXISTING_PROWLARR_API_KEY=""
EXISTING_TORBOX_API_KEY=""
EXISTING_RADARR_ADMIN_USER=""
EXISTING_RADARR_ADMIN_PASS=""
EXISTING_SONARR_ADMIN_USER=""
EXISTING_SONARR_ADMIN_PASS=""
EXISTING_PROWLARR_ADMIN_USER=""
EXISTING_PROWLARR_ADMIN_PASS=""
EXISTING_COMPOSE_PROFILES=""

check_existing_installation() {
    if [[ -f "${SETUP_COMPLETE_FILE}" ]]; then
        log_section "Existing Installation Detected"
        log_warn "A previous installation was found at: ${INSTALL_DIR}"
        echo ""
        echo "  Re-running will regenerate Docker Compose, configs, and systemd service."
        echo "  Your existing API keys will be PRESERVED to avoid breaking integrations."
        echo ""
        local rerun=""
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            rerun="y"
        else
            read -rp "Continue with re-configuration? [y/N]: " rerun
        fi
        if [[ "${rerun,,}" != "y" ]]; then
            log_info "Setup cancelled. Your existing installation is unchanged."
            exit 0
        fi

        # Back up existing generated files before overwriting
        local backup_ts
        backup_ts="$(date +%Y%m%d_%H%M%S)"
        for bf in "${ENV_FILE}" "${COMPOSE_FILE}" "${CONFIG_DIR}/decypharr/config.json"; do
            if [[ -f "$bf" ]]; then
                cp "$bf" "${bf}.bak.${backup_ts}"
            fi
        done
        log_info "Backed up existing config files (.bak.${backup_ts})."

        # Safely extract existing API keys using grep+cut (not source)
        EXISTING_RADARR_API_KEY=$(grep '^RADARR_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SONARR_API_KEY=$(grep '^SONARR_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PROWLARR_API_KEY=$(grep '^PROWLARR_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_TORBOX_API_KEY=$(grep '^TORBOX_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_COMPOSE_PROFILES=$(grep '^COMPOSE_PROFILES=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true

        # Extract existing admin credentials
        EXISTING_RADARR_ADMIN_USER=$(grep '^RADARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_RADARR_ADMIN_PASS=$(grep '^RADARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SONARR_ADMIN_USER=$(grep '^SONARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SONARR_ADMIN_PASS=$(grep '^SONARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PROWLARR_ADMIN_USER=$(grep '^PROWLARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PROWLARR_ADMIN_PASS=$(grep '^PROWLARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true

        # Extract existing Decypharr credentials
        DECYPHARR_USER=$(grep "^DECYPHARR_USER=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "\"" | tr -d "'") || true
        DECYPHARR_PASS=$(grep "^DECYPHARR_PASS=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "\"" | tr -d "'") || true

        # Validate extracted API keys are valid 32-char hex; regenerate if corrupted
        if [[ -n "$EXISTING_RADARR_API_KEY" && ! "$EXISTING_RADARR_API_KEY" =~ ^[0-9a-f]{32}$ ]]; then
            log_warn "Corrupted API key detected for Radarr. Will regenerate."
            EXISTING_RADARR_API_KEY=""
        fi
        if [[ -n "$EXISTING_SONARR_API_KEY" && ! "$EXISTING_SONARR_API_KEY" =~ ^[0-9a-f]{32}$ ]]; then
            log_warn "Corrupted API key detected for Sonarr. Will regenerate."
            EXISTING_SONARR_API_KEY=""
        fi
        if [[ -n "$EXISTING_PROWLARR_API_KEY" && ! "$EXISTING_PROWLARR_API_KEY" =~ ^[0-9a-f]{32}$ ]]; then
            log_warn "Corrupted API key detected for Prowlarr. Will regenerate."
            EXISTING_PROWLARR_API_KEY=""
        fi

        if [[ -n "$EXISTING_RADARR_API_KEY" ]]; then
            log_info "Existing API keys loaded and will be preserved."
        fi
        echo ""
    elif [[ -f "${ENV_FILE}" && ! -f "${SETUP_COMPLETE_FILE}" ]]; then
        # .env exists but .setup_complete doesn't — previous run was interrupted.
        # In interactive mode, ask the user what to do; in non-interactive mode,
        # default to a fresh install (preserves prior behavior).
        log_section "Incomplete Installation Detected"
        log_warn "A previous setup was interrupted before completion."
        local fresh_install="y"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Start fresh (deletes partial install)? [Y/n]: " fresh_install
        fi
        if [[ "${fresh_install,,}" != "n" ]]; then
            log_warn "Starting fresh (incomplete state will be cleaned up)."
            rm -rf "${INSTALL_DIR}"
        else
            log_info "Keeping partial install. Re-run will attempt to continue from generated configs."
            # Treat the existing .env as the source of truth so re-generated
            # configs use the same API keys / admin creds as the partial install.
            EXISTING_TORBOX_API_KEY=$(grep '^TORBOX_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_RADARR_API_KEY=$(grep '^RADARR_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_SONARR_API_KEY=$(grep '^SONARR_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_PROWLARR_API_KEY=$(grep '^PROWLARR_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_RADARR_ADMIN_USER=$(grep '^RADARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_RADARR_ADMIN_PASS=$(grep '^RADARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_SONARR_ADMIN_USER=$(grep '^SONARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_SONARR_ADMIN_PASS=$(grep '^SONARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_PROWLARR_ADMIN_USER=$(grep '^PROWLARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_PROWLARR_ADMIN_PASS=$(grep '^PROWLARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            EXISTING_COMPOSE_PROFILES=$(grep '^COMPOSE_PROFILES=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
            DECYPHARR_USER=$(grep "^DECYPHARR_USER=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "\"" | tr -d "'") || true
            DECYPHARR_PASS=$(grep "^DECYPHARR_PASS=" "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "\"" | tr -d "'") || true
        fi
        echo ""
    fi
}

start_services() {
    log_section "Starting Services"

    local start_now="y"
    if [[ -n "${TORBOX_START_SERVICES:-}" ]]; then
        if [[ "${TORBOX_START_SERVICES}" == "false" ]]; then
            start_now="n"
        fi
    elif [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Start all services now? [Y/n]: " start_now
    fi
    if [[ "${start_now,,}" != "n" ]]; then
        log_step "Starting Docker containers (first run downloads ~5-8 GB of images, this may take several minutes)..."
        if ! compose_cmd up -d --remove-orphans; then
            log_error "Failed to start services. Check your internet connection and disk space."
            log_error "Try running: cd ${INSTALL_DIR} && docker compose --env-file .env -f docker-compose.yml up -d"
            # Return non-zero so main() knows services didn't start — configs are
            # already written, so we DO want .setup_complete to be touched (the
            # install is structurally complete), but we should not silently
            # pretend the services are up.
            return 1
        fi
        echo ""
        log_info "All services starting! Give them 30-60 seconds to initialize."
        SERVICES_STARTED=true
    else
        echo ""
        log_info "You can start services later with:"
        echo "  cd ${INSTALL_DIR} && ./manage.sh start"
        log_info "Once started, re-run this script or configure services manually."
        SERVICES_STARTED=false
    fi
}

# ============================================================================
#  Main
# ============================================================================

NON_INTERACTIVE=false

main() {
    # Parse command-line flags (moved to the very beginning)
    for arg in "$@"; do
        case "$arg" in
            -y | --yes | --non-interactive) NON_INTERACTIVE=true ;;
            -d | --dry-run) DRY_RUN=true ;;
            -h | --help)
                echo "TorBox Media Server Setup v${VERSION}"
                echo "Usage: ./setup.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  -y, --yes, --non-interactive  Use defaults for all prompts"
                echo "  -d, --dry-run                 Preview changes without applying them"
                echo "  -h, --help                    Show this help"
                echo ""
                echo "Environment variables for non-interactive mode:"
                echo "  TORBOX_API_KEY        TorBox API key (required)"
                echo "  TORBOX_MEDIA_SERVER   'plex' or 'jellyfin' (default: plex)"
                echo "  TORBOX_PLEX_CLAIM     Plex claim token (optional)"
                echo "  TORBOX_MOUNT_DIR      Mount directory (default: /mnt/torbox-media)"
                echo "  TORBOX_HW_ACCEL       'intel', 'nvidia', 'amd', or 'none' (auto-detects if unset)"
                echo "  TORBOX_INSTALL_DIR   Custom install directory (default: ./torbox-media-server)"
                echo "  SYNC_AUTH_ONLY       Set to 'true' to only re-sync admin credentials to running *arrs"
                echo "  TORBOX_START_SERVICES 'true' or 'false' (default: true)"
                exit 0
                ;;
            -v | --version)
                echo "TorBox Media Server Setup v${VERSION}"
                exit 0
                ;;
        esac
    done

    # Warn if running as root (PUID/PGID would default to 0:0, usually undesirable)
    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root. Container PUID/PGID will default to 0:0."
        log_warn "Consider running as a regular user instead."
        echo ""
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Continue as root? [y/N]: " run_as_root
            if [[ "${run_as_root,,}" != "y" ]]; then
                log_info "Re-run as a regular user: ./setup.sh"
                exit 0
            fi
        fi
    fi

    print_banner

    # Quick credential-sync mode: skip full setup, just push .env credentials
    # into the running *arr services. Useful after a CasaOS first-boot where
    # the *arrs started before setup.sh could configure auth.
    if [[ "${SYNC_AUTH_ONLY:-false}" == "true" ]]; then
        log_step "SYNC_AUTH_ONLY mode — re-syncing admin credentials from .env"
        load_env_if_present
        configure_arrs
        log_info "Auth sync complete."
        exit 0
    fi

    check_existing_installation
    if [[ "$DRY_RUN" == "true" ]]; then
        check_dependencies --warn-only
    else
        check_dependencies
    fi
    gather_config
    check_port_conflicts

    if [[ "$DRY_RUN" == "true" ]]; then
        log_section "Dry Run — Preview of Actions"
        echo ""
        log_info "The following actions WOULD be taken (no changes made):"
        echo ""
        echo "  1. Create directories:"
        echo "     mkdir -p ${INSTALL_DIR}"
        echo "     mkdir -p ${CONFIG_DIR}/{prowlarr,radarr,sonarr,seerr,decypharr}"
        echo "     mkdir -p ${DATA_DIR}/{media/{movies,tv},downloads/{radarr,sonarr}}"
        if [[ "$MEDIA_SERVER" == "plex" ]]; then
            echo "     mkdir -p ${CONFIG_DIR}/plex"
        else
            echo "     mkdir -p ${CONFIG_DIR}/jellyfin"
        fi
        echo "     sudo mkdir -p ${MOUNT_DIR}"
        echo ""
        echo "  2. Generate configs:"
        echo "     ${CONFIG_DIR}/decypharr/config.json (TorBox API key, WebDAV, rclone)"
        echo "     ${CONFIG_DIR}/radarr/config.xml (API key: $(mask_key "${RADARR_API_KEY:-pending}"))"
        echo "     ${CONFIG_DIR}/sonarr/config.xml (API key: $(mask_key "${SONARR_API_KEY:-pending}"))"
        echo "     ${CONFIG_DIR}/prowlarr/config.xml (API key: $(mask_key "${PROWLARR_API_KEY:-pending}"))"
        echo ""
        echo "  3. Generate files:"
        echo "     ${ENV_FILE}"
        echo "     ${COMPOSE_FILE}"
        echo "     ${INSTALL_DIR}/manage.sh"
        echo ""
        echo "  4. Set up systemd service: torbox-media-server"
        echo ""
        echo "  5. Start Docker containers:"
        echo "     decypharr, prowlarr, byparr, radarr, sonarr, seerr, ${MEDIA_SERVER}"
        echo ""
        echo "  6. Auto-configure via API (download clients, root folders, naming, etc.)"
        echo ""
        log_info "Re-run without --dry-run to apply these changes."
        exit 0
    fi

    create_directories
    generate_decypharr_config
    generate_arr_configs
    generate_env_file
    generate_docker_compose
    generate_management_script
    generate_systemd_service

    # Fix ownership for custom PUID/PGID (after all config files are generated)
    if [[ "${PUID}" != "$(id -u)" || "${PGID}" != "$(id -g)" ]]; then
        log_step "Applying custom PUID/PGID ownership to config and data directories..."
        sudo chown -R "${PUID}:${PGID}" "${CONFIG_DIR}" "${DATA_DIR}"
    fi

    # start_services may fail (e.g. docker daemon down, port conflict). Don't
    # abort the whole setup — configs are already written, so we still mark the
    # install complete and let the user start services manually via manage.sh.
    # However, log a clear warning so the user knows the install is incomplete.
    if ! start_services; then
        log_warn "Services failed to start. Configs are saved — resolve the error above,"
        log_warn "then run: cd ${INSTALL_DIR} && ./manage.sh start"
    fi
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        configure_arrs
    fi
    print_post_install

    # Mark installation as complete for safe re-run detection
    touch "${SETUP_COMPLETE_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
