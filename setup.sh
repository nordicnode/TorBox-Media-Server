#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  TorBox Media Server - All-in-One Setup Script
#  Automated setup for a debrid-powered media server using Docker
#
#  Components: Prowlarr, Byparr, Decypharr, Seerr,
#              Radarr, Sonarr, rclone/FUSE mount, Plex or Jellyfin
#
#  Designed for CachyOS (Arch-based) but works on most Linux distros.
# ============================================================================

VERSION="1.0.0"
DRY_RUN=false

trap 'cleanup_on_interrupt' INT TERM

cleanup_on_interrupt() {
    echo ""
    # If setup never completed (.env not written), remove partial installation
    if [[ ! -f "${ENV_FILE}" && -d "${INSTALL_DIR}" ]]; then
        log_warn "Setup interrupted before completion. Cleaning up partial installation..."
        rm -rf "${INSTALL_DIR}"
        log_info "Partial installation removed. Re-run setup.sh to start fresh."
    elif [[ -f "${ENV_FILE}" && ! -f "${SETUP_COMPLETE_FILE}" ]]; then
        # .env exists but setup_complete doesn't — install was interrupted mid-config
        log_warn "Setup interrupted during configuration. Cleaning up incomplete installation..."
        rm -rf "${INSTALL_DIR}"
        log_info "Incomplete installation removed. Re-run setup.sh to start fresh."
    else
        log_warn "Setup interrupted. Re-run to continue where you left off."
    fi
    exit 130
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/torbox-media-server"
CONFIG_DIR="${INSTALL_DIR}/configs"
DATA_DIR="${INSTALL_DIR}/data"
MOUNT_DIR="/mnt/torbox-media"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SETUP_COMPLETE_FILE="${INSTALL_DIR}/.setup_complete"

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
    cat << 'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║           TorBox Media Server - All-in-One Setup            ║
  ║                                                             ║
  ║   Prowlarr · Byparr · Decypharr · Seerr                    ║
  ║   Radarr · Sonarr · rclone/FUSE · Plex/Jellyfin            ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} ${BOLD}$*${NC}"; }
log_section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }
mask_key()    { local k="$1"; if [[ ${#k} -gt 4 ]]; then echo "${k:0:4}...${k: -4}"; else echo "$k"; fi; }

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
    local msg="$1"; shift
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local tmpfile; tmpfile=$(mktemp)
    "$@" > "$tmpfile" 2>&1 &
    local pid=$! i=0
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
    (cd "${INSTALL_DIR}" && "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}

# ============================================================================
#  Dependency Checks
# ============================================================================

check_dependencies() {
    log_section "Checking Dependencies"

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

    if ! command -v timedatectl &>/dev/null; then
        missing+=("timedatectl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
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
        ports_to_check+=(8096 8920)
        port_names+=("Jellyfin" "Jellyfin HTTPS")
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
        if echo "$network_stats" | grep -qE ":${ports_to_check[$i]}[[:space:]]"; then
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
                    sudo pacman -S --noconfirm docker docker-compose
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose)
                    sudo pacman -S --noconfirm docker-compose
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
                timedatectl)
                    sudo pacman -S --noconfirm systemd
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
                timedatectl)
                    sudo apt-get install -y systemd
                    ;;
            esac
        done
    elif command -v dnf &>/dev/null; then
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    sudo dnf install -y docker docker-compose
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose)
                    sudo dnf install -y docker-compose
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
                timedatectl)
                    sudo dnf install -y systemd-udev
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
                1) MEDIA_SERVER="plex"; break ;;
                2) MEDIA_SERVER="jellyfin"; break ;;
                *) log_error "Please enter 1 or 2." ;;
            esac
        done
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
    # Block system directory prefixes
    for prefix in /etc /usr /var /tmp /proc /sys /dev /boot /sbin /bin /lib /run; do
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

    # Timezone
    TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')"
    echo ""
    echo -e "${BOLD}Timezone${NC}: ${TZ}"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "  Use this timezone? [Y/n]: " use_tz
        if [[ "${use_tz,,}" == "n" ]]; then
            while true; do
                read -rp "  Enter timezone (e.g., America/New_York): " TZ
                if timedatectl list-timezones 2>/dev/null | grep -qx "$TZ"; then
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

    echo ""

    # Hardware Acceleration — auto-detect, then prompt only if ambiguous
    echo -e "${BOLD}Hardware Acceleration${NC}"
    if [[ -n "${TORBOX_HW_ACCEL:-}" ]]; then
        HW_ACCEL="${TORBOX_HW_ACCEL}"
        log_info "Using hardware acceleration from TORBOX_HW_ACCEL env var: ${HW_ACCEL}"
    else
        local detected_intel=false detected_nvidia=false
        if [[ -d /dev/dri ]]; then
            detected_intel=true
        fi
        if command -v nvidia-smi &>/dev/null || [[ -e /dev/nvidia0 ]]; then
            detected_nvidia=true
        fi

        if [[ "$detected_intel" == "true" && "$detected_nvidia" == "false" ]]; then
            HW_ACCEL="intel"
            log_info "Auto-detected Intel QuickSync (/dev/dri)."
        elif [[ "$detected_nvidia" == "true" && "$detected_intel" == "false" ]]; then
            HW_ACCEL="nvidia"
            log_info "Auto-detected NVIDIA GPU."
        elif [[ "$detected_intel" == "true" && "$detected_nvidia" == "true" ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                HW_ACCEL="intel"
                log_info "Both GPUs detected. Non-interactive: defaulting to Intel QuickSync."
            else
                echo "  Both Intel and NVIDIA GPUs detected."
                echo "  1) Intel QuickSync (recommended - uses integrated GPU, power-efficient)"
                echo "  2) NVIDIA NVENC (uses discrete GPU, requires nvidia-container-toolkit)"
                echo ""
                while true; do
                    read -rp "  Choose hardware acceleration [1/2]: " hw_choice
                    case "$hw_choice" in
                        1) HW_ACCEL="intel"; break ;;
                        2) HW_ACCEL="nvidia"; break ;;
                        *) log_error "Please enter 1 or 2." ;;
                    esac
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
                echo "  3) NVIDIA NVENC (if you have discrete GPU)"
                echo ""
                while true; do
                    read -rp "  Choose hardware acceleration [1/2/3]: " hw_choice
                    case "$hw_choice" in
                        1) HW_ACCEL="none"; break ;;
                        2) HW_ACCEL="intel"; break ;;
                        3) HW_ACCEL="nvidia"; break ;;
                        *) log_error "Please enter 1, 2, or 3." ;;
                    esac
                done
            fi
        fi
    fi

    # Verify nvidia-container-toolkit is installed if NVIDIA is selected
    if [[ "${HW_ACCEL}" == "nvidia" ]]; then
        if ! command -v nvidia-container-runtime &>/dev/null && \
           ! dpkg -l nvidia-container-toolkit &>/dev/null && \
           ! rpm -q nvidia-container-toolkit &>/dev/null && \
           ! pacman -Qi nvidia-container-toolkit &>/dev/null; then
            log_error "NVIDIA GPU detected but nvidia-container-toolkit is not installed."
            log_error "Docker cannot use NVIDIA GPUs without the container toolkit."
            echo ""
            echo "  Install it with:"
            echo "    Arch/CachyOS: sudo pacman -S nvidia-container-toolkit"
            echo "    Debian/Ubuntu: sudo apt install nvidia-container-toolkit"
            echo "    Fedora: sudo dnf install nvidia-container-toolkit"
            echo ""
            log_info "Falling back to software transcoding."
            HW_ACCEL="none"
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
    sudo chown "${PUID}:${PGID}" "${MOUNT_DIR}"

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

    if [[ -f "${CONFIG_DIR}/decypharr/config.json" ]]; then
        log_info "Decypharr config already exists. Preserving user customizations."
        return 0
    fi

    # Generate credentials for Decypharr web UI
    DECYPHARR_USER="torbox"
    DECYPHARR_PASS="$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | head -c 12)"
    if [[ -z "$DECYPHARR_PASS" ]]; then
        DECYPHARR_PASS="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12)"
    fi

    cat > "${CONFIG_DIR}/decypharr/config.json" << DECYPHARR_EOF
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
            radarr)   arr_key="${RADARR_API_KEY}" ;;
            sonarr)   arr_key="${SONARR_API_KEY}" ;;
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
    if [[ ! -f "${CONFIG_DIR}/radarr/config.xml" ]]; then
    # --- Radarr config.xml ---
    cat > "${CONFIG_DIR}/radarr/config.xml" << RADARR_XML_EOF
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
    cat > "${CONFIG_DIR}/sonarr/config.xml" << SONARR_XML_EOF
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
    cat > "${CONFIG_DIR}/prowlarr/config.xml" << PROWLARR_XML_EOF
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

    local decypharr_image="${EXISTING_DECYPHARR_IMAGE:-${DECYPHARR_IMAGE:-cy01/blackhole:latest}}"
    local prowlarr_image="${EXISTING_PROWLARR_IMAGE:-${PROWLARR_IMAGE:-lscr.io/linuxserver/prowlarr:latest}}"
    local byparr_image="${EXISTING_BYPARR_IMAGE:-${BYPARR_IMAGE:-ghcr.io/thephaseless/byparr:latest}}"
    local radarr_image="${EXISTING_RADARR_IMAGE:-${RADARR_IMAGE:-lscr.io/linuxserver/radarr:latest}}"
    local sonarr_image="${EXISTING_SONARR_IMAGE:-${SONARR_IMAGE:-lscr.io/linuxserver/sonarr:latest}}"
    local seerr_image="${EXISTING_SEERR_IMAGE:-${SEERR_IMAGE:-ghcr.io/seerr-team/seerr:latest}}"
    local plex_image="${EXISTING_PLEX_IMAGE:-${PLEX_IMAGE:-lscr.io/linuxserver/plex:latest}}"
    local jellyfin_image="${EXISTING_JELLYFIN_IMAGE:-${JELLYFIN_IMAGE:-lscr.io/linuxserver/jellyfin:latest}}"

    # Set the compose profile based on media server choice
    local compose_profile="plex"
    if [[ "${MEDIA_SERVER}" == "jellyfin" ]]; then
        compose_profile="jellyfin"
    fi

    cat > "${ENV_FILE}" << ENV_EOF
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
DECYPHARR_IMAGE="${decypharr_image}"
PROWLARR_IMAGE="${prowlarr_image}"
BYPARR_IMAGE="${byparr_image}"
RADARR_IMAGE="${radarr_image}"
SONARR_IMAGE="${sonarr_image}"
SEERR_IMAGE="${seerr_image}"
PLEX_IMAGE="${plex_image}"
JELLYFIN_IMAGE="${jellyfin_image}"
ENV_EOF

    # Preserve existing admin credentials if this is a re-run
    if [[ -n "${EXISTING_RADARR_ADMIN_USER:-}" ]]; then
        cat >> "${ENV_FILE}" << ADMIN_EOF

# Admin Credentials (Preserved)
RADARR_ADMIN_USER="${EXISTING_RADARR_ADMIN_USER}"
RADARR_ADMIN_PASS="${EXISTING_RADARR_ADMIN_PASS}"
SONARR_ADMIN_USER="${EXISTING_SONARR_ADMIN_USER}"
SONARR_ADMIN_PASS="${EXISTING_SONARR_ADMIN_PASS}"
PROWLARR_ADMIN_USER="${EXISTING_PROWLARR_ADMIN_USER}"
PROWLARR_ADMIN_PASS="${EXISTING_PROWLARR_ADMIN_PASS}"
ADMIN_EOF
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
        cat > "${INSTALL_DIR}/docker-compose.override.yml" << 'HW_OVERRIDE'
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
    elif [[ "${HW_ACCEL}" == "nvidia" ]]; then
        cat > "${INSTALL_DIR}/docker-compose.override.yml" << 'HW_OVERRIDE'
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

    cat > "${INSTALL_DIR}/manage.sh" << 'MANAGE_EOF'
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
    grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

COMPOSE_CMD=()
_COMPOSE_SUDO_WARNED=false
MANAGE_EOF

    # Write shared functions inline instead of using declare -f (avoids hidden dependency on setup.sh signatures)
    cat >> "${INSTALL_DIR}/manage.sh" << 'MANAGE_INLINE'
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
    (cd "${SCRIPT_DIR}" && "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}
MANAGE_INLINE

    cat >> "${INSTALL_DIR}/manage.sh" << 'MANAGE_EOF'

ensure_mount_propagation() {
    local mount_dir
    mount_dir="$(env_val MOUNT_DIR)"
    if [[ -n "${mount_dir}" ]]; then
        echo -e "${YELLOW}Requesting sudo privileges to re-apply FUSE mounts...${NC}"
        # Guard with findmnt to prevent mount stacking
        sudo bash -c "findmnt -n '${mount_dir}' >/dev/null 2>&1 || mount --bind '${mount_dir}' '${mount_dir}'" 2>/dev/null || true
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
        echo -e "\n${CYAN}━━━━ API Keys ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        echo -e "  ${YELLOW}WARNING: Sensitive credentials below. Do not share this output.${NC}\n"
        echo -e "  ${BOLD}TorBox${NC}    $(env_val TORBOX_API_KEY)"
        echo -e "  ${BOLD}Radarr${NC}    $(env_val RADARR_API_KEY)"
        echo -e "  ${BOLD}Sonarr${NC}    $(env_val SONARR_API_KEY)"
        echo -e "  ${BOLD}Prowlarr${NC}  $(env_val PROWLARR_API_KEY)"
        _radarr_pass="$(env_val RADARR_ADMIN_PASS)"
        _sonarr_pass="$(env_val SONARR_ADMIN_PASS)"
        _prowlarr_pass="$(env_val PROWLARR_ADMIN_PASS)"
        if [[ -n "$_radarr_pass" ]]; then
            echo ""
            echo -e "  ${BOLD}Admin Credentials:${NC}"
            echo -e "  ${BOLD}Radarr${NC}    user: $(env_val RADARR_ADMIN_USER)  pass: ${_radarr_pass}"
            echo -e "  ${BOLD}Sonarr${NC}    user: $(env_val SONARR_ADMIN_USER)  pass: ${_sonarr_pass}"
            echo -e "  ${BOLD}Prowlarr${NC}  user: $(env_val PROWLARR_ADMIN_USER)  pass: ${_prowlarr_pass}"
        fi
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
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
        backup_dir="${SCRIPT_DIR}/backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${backup_dir}"
        chmod 700 "${backup_dir}"
        cp -a "${ENV_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -a "${COMPOSE_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -ra "${SCRIPT_DIR}/configs" "${backup_dir}/" 2>/dev/null || true
        echo -e "${GREEN}Backup saved to: ${backup_dir}${NC}"
        ;;
    restore)
        backups_dir="${SCRIPT_DIR}/backups"
        if [[ ! -d "${backups_dir}" ]]; then
            echo -e "${RED}No backups found. Run 'backup' first to create one.${NC}"
            exit 1
        fi
        target=""
        if [[ -n "${2:-}" ]]; then
            target="${backups_dir}/${2}"
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

    sudo tee "${service_file}" > /dev/null << SYSTEMD_EOF
[Unit]
Description=TorBox Media Server - Mount Propagation & Services
After=local-fs.target network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple

# Step 1: Set up FUSE mount propagation (required for rclone WebDAV in Decypharr)
# Guard with findmnt to prevent mount stacking on repeated restarts
ExecStartPre=/bin/bash -c 'findmnt -n "${MOUNT_DIR}" >/dev/null 2>&1 || mount --bind "${MOUNT_DIR}" "${MOUNT_DIR}"'
ExecStartPre=/bin/bash -c 'mount --make-shared "${MOUNT_DIR}"'

# Step 2: Start all containers (foreground so systemd tracks the process)
ExecStart=${docker_bin} ${compose_args} --env-file "${ENV_FILE}" up --remove-orphans

# On stop: bring containers down gracefully
ExecStop=${docker_bin} ${compose_args} --env-file "${ENV_FILE}" stop

# Clean up bind mount left by FUSE propagation
ExecStopPost=-/bin/bash -c 'umount -l "${MOUNT_DIR}" || true'

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
    sudo systemctl enable "${service_name}.service" 2>/dev/null \
        || log_warn "Could not enable systemd service. Auto-start on boot may not work (non-systemd system?)."

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
        dc_json=$(cat << DCJSON_EOF
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
            -d "$dc_json" -o /dev/null && log_info "  Download client 'Decypharr' added to ${name}." \
            || log_warn "  Failed to add download client to ${name}."
    else
        log_info "  ${name} already has Decypharr download client configured."
    fi

    # Add root folder
    local existing_rf
    existing_rf=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/rootfolder" 2>/dev/null) || true
    if ! echo "$existing_rf" | grep -qF "\"${root_path}\"" 2>/dev/null; then
        curl -sf --connect-timeout 5 --max-time 15 -X POST -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
            "${url}/api/v3/rootfolder" \
            -d '{"path": "'"${root_path}"'"}' -o /dev/null && log_info "  Root folder '${root_path}' added to ${name}." \
            || log_warn "  Failed to add root folder to ${name}."
    else
        log_info "  ${name} already has root folder '${root_path}' configured."
    fi

    # Advanced configuration (requires jq for JSON manipulation)
    if [[ "${HAS_JQ:-false}" == "true" ]]; then
        update_arr_config "${name}" "$url" "$api_key" "config/mediamanagement" \
            ".copyUsingHardlinks = false | .importExtraFiles = true | .extraFileExtensions = \"srt,sub,idx,ass,ssa,nfo\" | .${unmonitor_field} = false | .recycleBin = \"\" | .recycleBinCleanupDays = 0 | .minimumFreeSpaceWhenImporting = 100" \
            && log_info "  Media management configured (hardlinks disabled for debrid)." \
          || log_warn "  Failed to configure media management."

        update_arr_config "${name}" "$url" "$api_key" "config/naming" "${naming_updates}" \
            && log_info "  Naming conventions configured." \
            || log_warn "  Failed to configure naming."

        configure_quality_profiles "${name}" "$url" "$api_key" \
            && log_info "  Quality profiles updated (upgrades enabled)." \
            || log_warn "  Failed to update quality profiles."
    fi

    # Add Plex notification so library updates happen immediately on import
    if [[ "${MEDIA_SERVER}" == "plex" ]]; then
        local existing_notifs
        existing_notifs=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/notification" 2>/dev/null) || true
        if ! echo "$existing_notifs" | grep -q '"implementation":"PlexServer"' 2>/dev/null && ! echo "$existing_notifs" | grep -q '"implementation": "PlexServer"' 2>/dev/null; then
            local plex_token=""
            local plex_prefs="${CONFIG_DIR}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
            if [[ -f "$plex_prefs" ]]; then
                plex_token=$(grep -oP 'PlexOnlineToken="\K[^"]+' "$plex_prefs" 2>/dev/null) || true
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
                    -d '{
                        "name": "Plex",
                        "implementation": "PlexServer",
                        "configContract": "PlexServerSettings",
                        "'"$on_download_field"'": true,
                        "'"$on_upgrade_field"'": true,
                        "'"$on_rename_field"'": true,
                        "'"$on_delete_field"'": true,
                        "'"$on_delete_upgrade_field"'": true,
                        "fields": [
                            {"name": "host", "value": "plex"},
                            {"name": "port", "value": 32400},
                            {"name": "useSsl", "value": false},
                            {"name": "authToken", "value": "'"$plex_token"'"},
                            {"name": "updateLibrary", "value": true}
                        ]
                    }' -o /dev/null && log_info "  Plex notification added to ${name} (instant library updates)." \
                    || log_warn "  Failed to add Plex notification to ${name}."
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
    [[ -z "$config" ]] && { log_warn "  Could not retrieve ${name} ${endpoint}."; return 1; }

    config_id=$(echo "$config" | jq -r '.id' 2>/dev/null) || true
    [[ -z "$config_id" || "$config_id" == "null" ]] && { log_warn "  Could not parse ${name} ${endpoint} ID."; return 1; }

    updated=$(echo "$config" | jq "$jq_updates" 2>/dev/null) || true
    [[ -z "$updated" ]] && { log_warn "  Could not update ${name} ${endpoint}."; return 1; }

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
    local profile_ids
    profile_ids=$(echo "$updated_profiles" | jq -r '.[].id' 2>/dev/null) || true
    for pid in $profile_ids; do
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
        printf "\r  %s Waiting for %s... %ds/%ds" "${spin_chars:elapsed/interval%${#spin_chars}:1}" "$name" "$elapsed" "$max_wait"
        sleep "$interval"
        elapsed=$((elapsed + interval))
        [[ $interval -lt 5 ]] && interval=$((interval + 1))
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
        sleep 3  # Allow SQLite database to fully initialize after HTTP readiness
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
                }' -o /dev/null && log_info "  Byparr proxy added to Prowlarr." \
                || log_warn "  Failed to add Byparr proxy to Prowlarr."
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
                }' -o /dev/null && log_info "  Radarr app added to Prowlarr." \
                || log_warn "  Failed to add Radarr app to Prowlarr."
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
                }' -o /dev/null && log_info "  Sonarr app added to Prowlarr." \
                || log_warn "  Failed to add Sonarr app to Prowlarr."
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
        configure_arr_auth "Prowlarr" "$prowlarr_url" "$PROWLARR_API_KEY" || _failed=$((_failed + 1))
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

    # Wait for Seerr to be ready
    while [[ $elapsed -lt $max_wait ]]; do
        if curl -sf --connect-timeout 3 --max-time 10 -o /dev/null "${seerr_url}" 2>/dev/null; then
            printf "\r  %-50s\n" ""
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

    # Get current Seerr settings
    local seerr_settings
    seerr_settings=$(curl -sf --connect-timeout 5 --max-time 15 "${seerr_url}/api/v1/settings/main" 2>/dev/null) || true
    [[ -z "$seerr_settings" ]] && { log_warn "  Could not retrieve Seerr settings."; return 1; }

    # Check if Radarr is already configured
    if echo "$seerr_settings" | grep -q '"hostname":"radarr"' 2>/dev/null || \
       echo "$seerr_settings" | grep -q '"hostname": "radarr"' 2>/dev/null; then
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
            }' -o /dev/null 2>/dev/null && log_info "  Radarr added to Seerr (profile: ${radarr_profile_name})." \
            || log_warn "  Failed to add Radarr to Seerr. You can configure it manually."
    fi

    # Check if Sonarr is already configured
    if echo "$seerr_settings" | grep -q '"hostname":"sonarr"' 2>/dev/null || \
       echo "$seerr_settings" | grep -q '"hostname": "sonarr"' 2>/dev/null; then
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
            }' -o /dev/null 2>/dev/null && log_info "  Sonarr added to Seerr (profile: ${sonarr_profile_name})." \
            || log_warn "  Failed to add Sonarr to Seerr. You can configure it manually."
    fi

    # Configure Plex or Jellyfin connection in Seerr
    if [[ "${MEDIA_SERVER}" == "plex" ]]; then
        local plex_token=""
        local plex_prefs="${CONFIG_DIR}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
        if [[ -f "$plex_prefs" ]]; then
            plex_token=$(grep -oP 'PlexOnlineToken="\K[^"]+' "$plex_prefs" 2>/dev/null) || true
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
                }' -o /dev/null 2>/dev/null && log_info "  Plex server added to Seerr." \
                || log_warn "  Failed to add Plex to Seerr. You can configure it manually."
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
            }' -o /dev/null 2>/dev/null && log_info "  Jellyfin server added to Seerr." \
            || log_warn "  Failed to add Jellyfin to Seerr. You can configure it manually."
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
    plex_token=$(grep -oP 'PlexOnlineToken="\K[^"]+' "$plex_prefs" 2>/dev/null) || true

    if [[ -z "$plex_token" ]]; then
        log_warn "  Could not extract Plex token. Skipping library auto-config."
        return 1
    fi

    # Check if libraries already exist
    local existing_libs
    existing_libs=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Plex-Token: ${plex_token}" "${plex_url}/library/sections" 2>/dev/null) || true

    if echo "$existing_libs" | grep -q 'title="Movies"' 2>/dev/null; then
        log_info "  Plex 'Movies' library already exists."
    else
        # Add Movies library
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "X-Plex-Token: ${plex_token}" \
            "${plex_url}/library/sections?name=Movies&type=movie&agent=tv.plex.agents.movie&scanner=Plex%20Movie&language=en&location=%2Fdata%2Fmedia%2Fmovies" \
            -o /dev/null 2>/dev/null && log_info "  Plex 'Movies' library added." \
            || log_warn "  Failed to add Movies library. You can add it manually in Plex."
    fi

    if echo "$existing_libs" | grep -q 'title="TV Shows"' 2>/dev/null; then
        log_info "  Plex 'TV Shows' library already exists."
    else
        # Add TV Shows library
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "X-Plex-Token: ${plex_token}" \
            "${plex_url}/library/sections?name=TV%20Shows&type=show&agent=tv.plex.agents.series&scanner=Plex%20Series&language=en&location=%2Fdata%2Fmedia%2Ftv" \
            -o /dev/null 2>/dev/null && log_info "  Plex 'TV Shows' library added." \
            || log_warn "  Failed to add TV Shows library. You can add it manually in Plex."
    fi

    # Remove expired claim token from .env (token expires in 4 min and is single-use)
    if [[ -f "${ENV_FILE}" ]]; then
        local env_tmp
        env_tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
        if grep -v '^PLEX_CLAIM=' "${ENV_FILE}" > "${env_tmp}"; then
            mv "${env_tmp}" "${ENV_FILE}"
            log_info "  Plex claim token removed from .env (expired after first use)."
        else
            rm -f "${env_tmp}"
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

    # Add 1337x as a default public indexer
    curl -sf --connect-timeout 5 --max-time 15 -X POST \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${PROWLARR_API_KEY}" \
        "${prowlarr_url}/api/v1/indexer" \
        -d '{
            "name": "1337x",
            "fields": [
                {"name": "baseUrl", "value": "https://1337x.to"},
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
        }' -o /dev/null 2>/dev/null && log_info "  Default indexer '1337x' added to Prowlarr." \
        || log_warn "  Failed to add default indexer. You can add indexers manually in Prowlarr."
}

# ============================================================================
#  Auto-Configure Authentication for *arr Services
# ============================================================================

configure_arr_auth() {
    local name="$1" url="$2" api_key="$3"

    log_step "Configuring ${name} authentication..."

    # Check current auth config
    local auth_config
    auth_config=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/config/host" 2>/dev/null) || true
    [[ -z "$auth_config" ]] && { log_warn "  Could not retrieve ${name} auth config."; return 1; }

    # Check if auth is already set to Forms
    if echo "$auth_config" | grep -q '"authenticationMethod":"Forms"' 2>/dev/null || \
       echo "$auth_config" | grep -q '"authenticationMethod": "Forms"' 2>/dev/null; then
        log_info "  ${name} already has Forms authentication configured."
        return 0
    fi

    # Generate admin credentials
    local admin_user="admin"
    local admin_pass
    admin_pass="$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | head -c 12)"
    if [[ -z "$admin_pass" ]]; then
        admin_pass="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12)"
    fi

    # Store credentials globally for post-install display
    case "$name" in
        Radarr)   RADARR_ADMIN_USER="$admin_user"; RADARR_ADMIN_PASS="$admin_pass" ;;
        Sonarr)   SONARR_ADMIN_USER="$admin_user"; SONARR_ADMIN_PASS="$admin_pass" ;;
        Prowlarr) PROWLARR_ADMIN_USER="$admin_user"; PROWLARR_ADMIN_PASS="$admin_pass" ;;
    esac

    # Set auth to Forms with Enabled (always require login)
    local auth_id
    auth_id=$(echo "$auth_config" | jq -r '.id' 2>/dev/null) || true
    [[ -z "$auth_id" || "$auth_id" == "null" ]] && { log_warn "  Could not parse ${name} auth config ID."; return 1; }

    local updated_auth
    updated_auth=$(echo "$auth_config" | jq \
        --arg user "$admin_user" \
        --arg pass "$admin_pass" \
        '.authenticationMethod = "Forms" | .authenticationRequired = "Enabled" | .username = $user | .password = $pass' 2>/dev/null) || true
    [[ -z "$updated_auth" ]] && { log_warn "  Could not update ${name} auth config."; return 1; }

    curl -sf --connect-timeout 5 --max-time 15 -X PUT \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${api_key}" \
        "${url}/api/v3/config/host/${auth_id}" \
        -d "$updated_auth" -o /dev/null 2>/dev/null && {
            log_info "  ${name} auth set to Forms (Enabled) with auto-generated credentials."
            local env_key
            case "$name" in
                Radarr)   env_key="RADARR_ADMIN_USER" ;;
                Sonarr)   env_key="SONARR_ADMIN_USER" ;;
                Prowlarr) env_key="PROWLARR_ADMIN_USER" ;;
                *)        { log_warn "  Unsupported service name: ${name}"; return 1; } ;;
            esac

            # Remove old entries and append new ones
            local env_tmp
            env_tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
            if grep -v "^${env_key}_USER=\\|^${env_key}_PASS=" "${ENV_FILE}" > "${env_tmp}" 2>/dev/null; then
                echo "${env_key}_USER=\"${admin_user}\"" >> "${env_tmp}"
                echo "${env_key}_PASS=\"${admin_pass}\"" >> "${env_tmp}"
                mv "${env_tmp}" "${ENV_FILE}"
            else
                rm -f "${env_tmp}"
            fi
            chmod 600 "${ENV_FILE}"
        } || log_warn "  Failed to configure ${name} auth."
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

    if [[ "$SERVICES_STARTED" == "true" && ( -n "${RADARR_ADMIN_PASS:-}" || -n "${SONARR_ADMIN_PASS:-}" || -n "${PROWLARR_ADMIN_PASS:-}" ) ]]; then
        echo -e "${BOLD}━━━━ Auto-Generated Admin Credentials ━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${YELLOW}Save these credentials — you will need them to log in.${NC}"
        echo ""
        echo -e "  ${BOLD}Radarr${NC}    Username: ${RADARR_ADMIN_USER:-<not set>}  Password: ${RADARR_ADMIN_PASS:-<not set>}"
        echo -e "  ${BOLD}Sonarr${NC}    Username: ${SONARR_ADMIN_USER:-<not set>}  Password: ${SONARR_ADMIN_PASS:-<not set>}"
        echo -e "  ${BOLD}Prowlarr${NC}  Username: ${PROWLARR_ADMIN_USER:-<not set>}  Password: ${PROWLARR_ADMIN_PASS:-<not set>}"
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
    echo -e "  ${GREEN}✓  Auto-start on boot is enabled.${NC}"
    echo "     A systemd service (torbox-media-server) handles mount propagation"
    echo "     and starts all containers automatically when your computer boots."
    echo "     To disable: sudo systemctl disable torbox-media-server"
    echo ""

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
    echo "  ${YELLOW}No media is stored locally — everything streams from TorBox!${NC}"
    echo ""
}

# ============================================================================
#  Start Services
# ============================================================================

SERVICES_STARTED=false

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
EXISTING_DECYPHARR_IMAGE=""
EXISTING_PROWLARR_IMAGE=""
EXISTING_BYPARR_IMAGE=""
EXISTING_RADARR_IMAGE=""
EXISTING_SONARR_IMAGE=""
EXISTING_SEERR_IMAGE=""
EXISTING_PLEX_IMAGE=""
EXISTING_JELLYFIN_IMAGE=""

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
        EXISTING_DECYPHARR_IMAGE=$(grep '^DECYPHARR_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PROWLARR_IMAGE=$(grep '^PROWLARR_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_BYPARR_IMAGE=$(grep '^BYPARR_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_RADARR_IMAGE=$(grep '^RADARR_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SONARR_IMAGE=$(grep '^SONARR_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SEERR_IMAGE=$(grep '^SEERR_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PLEX_IMAGE=$(grep '^PLEX_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_JELLYFIN_IMAGE=$(grep '^JELLYFIN_IMAGE=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true

        # Migrate old legacy image references to current defaults
        case "${EXISTING_DECYPHARR_IMAGE}" in
            ghcr.io/sirrobot01/decypharr:v2.2) EXISTING_DECYPHARR_IMAGE="" ;;
        esac
        case "${EXISTING_PROWLARR_IMAGE}" in
            lscr.io/linuxserver/prowlarr:2.1.3) EXISTING_PROWLARR_IMAGE="" ;;
        esac
        case "${EXISTING_BYPARR_IMAGE}" in
            ghcr.io/thephaseless/byparr:1.2.2) EXISTING_BYPARR_IMAGE="" ;;
        esac
        case "${EXISTING_RADARR_IMAGE}" in
            lscr.io/linuxserver/radarr:5.22.4) EXISTING_RADARR_IMAGE="" ;;
        esac
        case "${EXISTING_SONARR_IMAGE}" in
            lscr.io/linuxserver/sonarr:4.0.14) EXISTING_SONARR_IMAGE="" ;;
        esac
        case "${EXISTING_SEERR_IMAGE}" in
            ghcr.io/seerr-team/seerr:2.4.1) EXISTING_SEERR_IMAGE="" ;;
        esac
        case "${EXISTING_JELLYFIN_IMAGE}" in
            lscr.io/linuxserver/jellyfin:10.10.7) EXISTING_JELLYFIN_IMAGE="" ;;
        esac

        # Extract existing admin credentials
        EXISTING_RADARR_ADMIN_USER=$(grep '^RADARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_RADARR_ADMIN_PASS=$(grep '^RADARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SONARR_ADMIN_USER=$(grep '^SONARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_SONARR_ADMIN_PASS=$(grep '^SONARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PROWLARR_ADMIN_USER=$(grep '^PROWLARR_ADMIN_USER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
        EXISTING_PROWLARR_ADMIN_PASS=$(grep '^PROWLARR_ADMIN_PASS=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true

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
        # .env exists but .setup_complete doesn't — previous run was interrupted
        log_section "Incomplete Installation Detected"
        log_warn "A previous setup was interrupted before completion."
        log_warn "Starting fresh (incomplete state will be cleaned up)."
        echo ""
        rm -rf "${INSTALL_DIR}"
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
        if ! (cd "${INSTALL_DIR}" && compose_cmd up -d --remove-orphans); then
            log_error "Failed to start services. Check your internet connection and disk space."
            log_error "Try running: cd ${INSTALL_DIR} && docker compose --env-file .env -f docker-compose.yml up -d"
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
            -y|--yes|--non-interactive) NON_INTERACTIVE=true ;;
            -d|--dry-run) DRY_RUN=true ;;
            -h|--help)
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
                echo "  TORBOX_HW_ACCEL       'intel', 'nvidia', or 'none' (auto-detects if unset)"
                echo "  TORBOX_START_SERVICES 'true' or 'false' (default: true)"
                exit 0
                ;;
            -v|--version)
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
    check_existing_installation
    check_dependencies
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

    start_services
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
