#!/usr/bin/env bash
set -euo pipefail
umask 077

# ============================================================================
#  TorBox Media Server - All-in-One Setup Script
#  Automated setup for a debrid-powered media server using Docker
#
#  Components: Prowlarr, Byparr, Decypharr, Seerr,
#              Radarr, Sonarr, rclone/FUSE mount, Plex or Jellyfin
#
#  Designed for CachyOS (Arch-based) but works on most Linux distros.
# ============================================================================

trap 'echo ""; log_warn "Setup interrupted. Re-run to continue where you left off."; exit 130' INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/torbox-media-server"
CONFIG_DIR="${INSTALL_DIR}/configs"
DATA_DIR="${INSTALL_DIR}/data"
MOUNT_DIR="/mnt/torbox-media"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

# Generate deterministic-length API keys (32-char hex, matching *arr format)
generate_api_key() {
    local key=""
    key=$(openssl rand -hex 16 2>/dev/null) \
        || key=$(xxd -p -l 16 /dev/urandom 2>/dev/null) \
        || key=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \t\n') \
        || key=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \t\n')
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
    if docker info &>/dev/null 2>&1; then
        if docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD=(docker compose)
        else
            COMPOSE_CMD=(docker-compose)
        fi
    else
        if [[ "$_COMPOSE_SUDO_WARNED" != "true" ]]; then
            log_warn "Docker socket not accessible in current shell — using sudo."
            _COMPOSE_SUDO_WARNED=true
        fi
        if sudo docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD=(sudo docker compose)
        else
            COMPOSE_CMD=(sudo docker-compose)
        fi
    fi
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

    if ! docker compose version &>/dev/null 2>&1; then
        if ! command -v docker-compose &>/dev/null; then
            missing+=("docker-compose")
        fi
    fi

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
        read -rp "Install missing dependencies automatically? [Y/n]: " install_deps
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
    if ! docker info &>/dev/null 2>&1; then
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
                if sudo docker info &>/dev/null 2>&1; then
                    printf "\r  %-50s\r" ""
                    break
                fi
                printf "\r  %s Waiting for Docker daemon... %ds/15s" "${spin_chars:docker_wait%${#spin_chars}:1}" "$docker_wait"
                sleep 1
                docker_wait=$((docker_wait + 1))
            done
            printf "\r  %-50s\r" ""
        fi
        if ! sudo docker info &>/dev/null 2>&1; then
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
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        ports_to_check+=(32400)
        port_names+=("Plex")
    elif [[ "$MEDIA_SERVER" == "jellyfin" ]]; then
        ports_to_check+=(8096 8920)
        port_names+=("Jellyfin" "Jellyfin HTTPS")
    fi
    local conflicts=false
    for i in "${!ports_to_check[@]}"; do
        local port_in_use=false
        if command -v ss &>/dev/null; then
            ss -tlnp 2>/dev/null | grep -q ":${ports_to_check[$i]} " 2>/dev/null && port_in_use=true
        elif command -v netstat &>/dev/null; then
            netstat -tlnp 2>/dev/null | grep -q ":${ports_to_check[$i]} " 2>/dev/null && port_in_use=true
        fi
        if [[ "$port_in_use" == "true" ]]; then
            log_warn "Port ${ports_to_check[$i]} (${port_names[$i]}) is already in use."
            conflicts=true
        fi
    done
    if [[ "$conflicts" == "true" ]]; then
        log_warn "Some ports are in use. Services using those ports may fail to start."
        log_warn "Stop the conflicting processes or change the ports in docker-compose.yml after setup."
        read -rp "Continue anyway? [Y/n]: " continue_anyway
        if [[ "${continue_anyway,,}" == "n" ]]; then
            log_error "Setup cancelled. Free the conflicting ports and re-run."
            exit 1
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
    if [[ -n "${EXISTING_TORBOX_API_KEY:-}" ]]; then
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

    PLEX_CLAIM=""
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        echo ""
        echo -e "${BOLD}Plex Claim Token${NC} (optional, for first-time setup)"
        echo "  Get your claim token from: https://www.plex.tv/claim/"
        echo "  Press Enter to skip."
        read -rp "  Plex claim token: " PLEX_CLAIM
        PLEX_CLAIM="${PLEX_CLAIM:-}"
        if [[ -n "$PLEX_CLAIM" && ! "$PLEX_CLAIM" =~ ^claim-[a-zA-Z0-9_-]+$ ]]; then
            log_error "Invalid Plex claim token format. Tokens start with 'claim-' followed by alphanumeric characters."
            log_error "Please copy it directly from https://www.plex.tv/claim/"
            exit 1
        fi
    fi

    echo ""

    # Mount directory
    echo -e "${BOLD}Mount Directory${NC}"
    echo "  This is where TorBox media will be mounted on your filesystem."
    echo "  Default: ${MOUNT_DIR}"
    while true; do
        read -rp "  Mount path [${MOUNT_DIR}]: " custom_mount
        MOUNT_DIR="${custom_mount:-$MOUNT_DIR}"
        if [[ "$MOUNT_DIR" != /* ]]; then
            log_error "Mount path must be an absolute path (start with /)."
            MOUNT_DIR="/mnt/torbox-media"
            continue
        fi
        # Block system directory prefixes
        local blocked=false
        for prefix in /etc /usr /var /tmp /proc /sys /dev /boot /sbin /bin /lib /run; do
            if [[ "$MOUNT_DIR" == "$prefix" || "$MOUNT_DIR" == "$prefix"/* ]]; then
                log_error "'${MOUNT_DIR}' is under a system directory. Please choose a dedicated path."
                MOUNT_DIR="/mnt/torbox-media"
                blocked=true
                break
            fi
        done
        [[ "$blocked" == "true" ]] && continue
        # Reject unsafe characters in mount path
        if [[ "$MOUNT_DIR" =~ [^a-zA-Z0-9_./-] ]]; then
            log_error "Mount path contains unsafe characters. Use only alphanumeric, dots, hyphens, underscores, and slashes."
            MOUNT_DIR="/mnt/torbox-media"
            continue
        fi
        break
    done

    echo ""

    # User/Group IDs
    PUID="$(id -u)"
    PGID="$(id -g)"
    echo -e "${BOLD}User/Group IDs${NC}"
    echo "  Detected: PUID=${PUID}, PGID=${PGID}"
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

    # Timezone
    TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')"
    echo ""
    echo -e "${BOLD}Timezone${NC}: ${TZ}"
    read -rp "  Use this timezone? [Y/n]: " use_tz
    if [[ "${use_tz,,}" == "n" ]]; then
        while true; do
            read -rp "  Enter timezone (e.g., America/New_York): " TZ
            # Validate against known timezones if timedatectl is available
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

    # Hardware Acceleration
    echo -e "${BOLD}Hardware Acceleration (for media transcoding)${NC}"
    echo "  1) Intel QuickSync (recommended - uses integrated GPU, power-efficient)"
    echo "  2) NVIDIA NVENC (uses discrete GPU, requires nvidia-container-toolkit)"
    echo "  3) None (software transcoding only)"
    echo ""
    while true; do
        read -rp "  Choose hardware acceleration [1/2/3]: " hw_choice
        case "$hw_choice" in
            1) HW_ACCEL="intel"; break ;;
            2) HW_ACCEL="nvidia"; break ;;
            3) HW_ACCEL="none"; break ;;
            *) log_error "Please enter 1, 2, or 3." ;;
        esac
    done

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
    read -rp "Proceed with these settings? [Y/n]: " confirm_config
    if [[ "${confirm_config,,}" == "n" ]]; then
        log_info "Setup cancelled."
        exit 0
    fi
}

# ============================================================================
#  Directory Structure
# ============================================================================

create_directories() {
    log_section "Creating Directory Structure"

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${CONFIG_DIR}"/{prowlarr,radarr,sonarr,seerr,decypharr}
    mkdir -p "${DATA_DIR}"/{media/{movies,tv},downloads/{radarr,sonarr}}

    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        mkdir -p "${CONFIG_DIR}/plex"
    else
        mkdir -p "${CONFIG_DIR}/jellyfin"
    fi

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
  "port": "8282",
  "log_level": "info"
}
DECYPHARR_EOF

    chmod 600 "${CONFIG_DIR}/decypharr/config.json"
    log_info "Decypharr config written."
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

# Mount paths
MOUNT_DIR="${MOUNT_DIR}"

# Media Server
MEDIA_SERVER="${MEDIA_SERVER}"

# Plex
PLEX_CLAIM="${PLEX_CLAIM:-}"

# *arr API Keys (pre-seeded)
RADARR_API_KEY="${RADARR_API_KEY}"
SONARR_API_KEY="${SONARR_API_KEY}"
PROWLARR_API_KEY="${PROWLARR_API_KEY}"
ENV_EOF

    chmod 600 "${ENV_FILE}"
    log_info "Environment file written."
}

# ============================================================================
#  Generate Docker Compose
# ============================================================================

generate_docker_compose() {
    log_step "Generating Docker Compose file..."

    cat > "${COMPOSE_FILE}" << 'COMPOSE_HEADER'
# ============================================================================
#  TorBox Media Server - Docker Compose
#  Auto-generated setup script
# ============================================================================

networks:
  media-network:
    driver: bridge

services:
COMPOSE_HEADER

    # --- Decypharr ---
    cat >> "${COMPOSE_FILE}" << COMPOSE_EOF
  # ── Decypharr ──────────────────────────────────────────────────
  # Mocks qBittorrent API for Radarr/Sonarr, connects to TorBox,
  # handles WebDAV mounting via built-in rclone, and creates symlinks.
  decypharr:
    image: cy01/blackhole:latest
    container_name: decypharr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8282:8282"
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - UMASK=002
    volumes:
      - "${CONFIG_DIR}/decypharr:/app"
      - "${MOUNT_DIR}:/mnt/remote:rshared"
      - "${DATA_DIR}:/data"
    devices:
      - /dev/fuse:/dev/fuse:rwm
    cap_add:
      - SYS_ADMIN
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8282"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    security_opt:
      # Harmless on systems without AppArmor (e.g. CachyOS)
      - apparmor:unconfined

  # ── Prowlarr ───────────────────────────────────────────────────
  # Indexer manager - feeds search results to Radarr & Sonarr.
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:9696:9696"
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - byparr
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:9696/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/prowlarr:/config"

  # ── Byparr ────────────────────────────────────────────────────
  # Cloudflare bypass proxy (Byparr - drop-in FlareSolverr replacement).
  byparr:
    image: ghcr.io/thephaseless/byparr:latest
    container_name: byparr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8191:8191"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - TZ=\${TZ}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8191"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  # ── Radarr ─────────────────────────────────────────────────────
  # Movie management - searches, grabs, and organizes movies.
  # Uses Decypharr as its download client (qBittorrent mock).
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:7878:7878"
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - decypharr
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:7878/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/radarr:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"

  # ── Sonarr ─────────────────────────────────────────────────────
  # TV show management - searches, grabs, and organizes series.
  # Uses Decypharr as its download client (qBittorrent mock).
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8989:8989"
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      - decypharr
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8989/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/sonarr:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"

  # ── Seerr ───────────────────────────────────────────────────────
  # Media request & discovery frontend. Users request movies/shows
  # which get sent to Radarr/Sonarr automatically.
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    user: "\${PUID}:\${PGID}"
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:5055:5055"
    environment:
      - TZ=\${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:5055"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/seerr:/app/config"

COMPOSE_EOF

    # --- Media Server ---
    local NVIDIA_ENV=""
    if [[ "${HW_ACCEL}" == "nvidia" ]]; then
        NVIDIA_ENV=$'\n      - NVIDIA_VISIBLE_DEVICES=all\n      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility'
    fi

    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        cat >> "${COMPOSE_FILE}" << COMPOSE_PLEX
  # ── Plex ───────────────────────────────────────────────────────
  # Media server - streams your library to any device.
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "32400:32400"
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
      - VERSION=docker
      - PLEX_CLAIM=\${PLEX_CLAIM:-}${NVIDIA_ENV}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:32400/identity"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    volumes:
      - "${CONFIG_DIR}/plex:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE_PLEX

        # Inject hardware acceleration for Plex
        if [[ "${HW_ACCEL}" == "intel" ]]; then
            cat >> "${COMPOSE_FILE}" << COMPOSE_PLEX_HW
    devices:
      - /dev/dri:/dev/dri
COMPOSE_PLEX_HW
        elif [[ "${HW_ACCEL}" == "nvidia" ]]; then
            cat >> "${COMPOSE_FILE}" << COMPOSE_PLEX_HW
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
COMPOSE_PLEX_HW
        fi
    else
        cat >> "${COMPOSE_FILE}" << COMPOSE_JELLYFIN
  # ── Jellyfin ───────────────────────────────────────────────────
  # Free & open-source media server - streams your library to any device.
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8096:8096"
      - "127.0.0.1:8920:8920"
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}${NVIDIA_ENV}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8096/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/jellyfin:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSE_JELLYFIN

        # Inject hardware acceleration for Jellyfin
        if [[ "${HW_ACCEL}" == "intel" ]]; then
            cat >> "${COMPOSE_FILE}" << COMPOSE_JF_HW
    devices:
      - /dev/dri:/dev/dri
COMPOSE_JF_HW
        elif [[ "${HW_ACCEL}" == "nvidia" ]]; then
            cat >> "${COMPOSE_FILE}" << COMPOSE_JF_HW
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
COMPOSE_JF_HW
        fi
    fi

    chmod 600 "${COMPOSE_FILE}"
    log_info "Docker Compose file written."

    # Validate the generated Compose file
    detect_compose_cmd
    if run_with_spinner "Validating Docker Compose file..." "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" config -q; then
        log_info "Docker Compose file validated successfully."
    else
        log_warn "Docker Compose validation failed. The generated file may have issues."
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

compose_cmd() {
    local -a cmd
    if docker info &>/dev/null 2>&1; then
        if docker compose version &>/dev/null 2>&1; then
            cmd=(docker compose)
        else
            cmd=(docker-compose)
        fi
    else
        if sudo docker compose version &>/dev/null 2>&1; then
            cmd=(sudo docker compose)
        else
            cmd=(sudo docker-compose)
        fi
    fi
    "${cmd[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

ensure_mount_propagation() {
    local mount_dir
    mount_dir="$(env_val MOUNT_DIR)"
    if [[ -n "${mount_dir}" ]]; then
        echo -e "${YELLOW}Requesting sudo privileges to re-apply FUSE mounts...${NC}"
        sudo mount --bind "${mount_dir}" "${mount_dir}" 2>/dev/null || true
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
    echo "  pull        Pull latest images"
    echo "  update      Pull latest images and restart"
    echo "  down        Stop and remove containers"
    echo "  urls        Show all service URLs"
    echo "  keys        Show API keys"
    echo "  enable      Enable auto-start on boot"
    echo "  disable     Disable auto-start on boot"
    echo "  backup      Back up configs and .env"
    echo "  health      Check health of all services"
    echo "  shell <svc> Open a shell in a service container"
    echo "  help        Show this help"
}

show_urls() {
    local media_server svc
    media_server="$(env_val MEDIA_SERVER)"
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
        echo -e "${GREEN}Pulling latest images...${NC}"
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
        echo -e "  ${BOLD}TorBox${NC}    $(env_val TORBOX_API_KEY)"
        echo -e "  ${BOLD}Radarr${NC}    $(env_val RADARR_API_KEY)"
        echo -e "  ${BOLD}Sonarr${NC}    $(env_val SONARR_API_KEY)"
        echo -e "  ${BOLD}Prowlarr${NC}  $(env_val PROWLARR_API_KEY)"
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        ;;
    enable)
        echo -e "${GREEN}Enabling auto-start on boot...${NC}"
        sudo systemctl enable torbox-media-server 2>/dev/null && \
            echo -e "${GREEN}Auto-start enabled. Services will start automatically on boot.${NC}" || \
            echo -e "${YELLOW}Systemd service not found. Re-run setup.sh to create it.${NC}"
        ;;
    disable)
        echo -e "${YELLOW}Disabling auto-start on boot...${NC}"
        sudo systemctl disable torbox-media-server 2>/dev/null && \
            echo -e "${YELLOW}Auto-start disabled. Use './manage.sh start' to start services manually.${NC}" || \
            echo -e "${YELLOW}Systemd service not found.${NC}"
        ;;
    backup)
        backup_dir="${SCRIPT_DIR}/backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${backup_dir}"
        cp -a "${ENV_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -a "${COMPOSE_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -ra "${SCRIPT_DIR}/configs" "${backup_dir}/" 2>/dev/null || true
        echo -e "${GREEN}Backup saved to: ${backup_dir}${NC}"
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
    help|*)
        show_help
        ;;
esac
MANAGE_EOF

    chmod +x "${INSTALL_DIR}/manage.sh"
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

    # Resolve absolute path to docker binary (required by systemd)
    local docker_bin
    docker_bin="$(command -v docker)"
    local compose_args="compose"
    if ! docker compose version &>/dev/null 2>&1; then
        docker_bin="$(command -v docker-compose)"
        compose_args=""
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
# Prefixed with - to tolerate already-mounted state (idempotent)
ExecStartPre=-$(command -v mount) --bind "${MOUNT_DIR}" "${MOUNT_DIR}"
ExecStartPre=-$(command -v mount) --make-shared "${MOUNT_DIR}"

# Step 2: Start all containers (foreground so systemd tracks the process)
ExecStart=${docker_bin} ${compose_args} --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up --remove-orphans

# On stop: bring containers down gracefully
ExecStop=${docker_bin} ${compose_args} --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" stop

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

    # Advanced configuration (requires python3 for JSON manipulation)
    if [[ "${HAS_PYTHON3:-false}" == "true" ]]; then
        update_arr_config "${name}" "$url" "$api_key" "config/mediamanagement" "
c['copyUsingHardlinks'] = False
c['importExtraFiles'] = True
c['extraFileExtensions'] = 'srt,sub,idx,ass,ssa,nfo'
c['${unmonitor_field}'] = False
c['recycleBin'] = ''
c['recycleBinCleanupDays'] = 0
c['minimumFreeSpaceWhenImporting'] = 100
" && log_info "  Media management configured (hardlinks disabled for debrid)." \
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

# Helper: GET a *arr config section, modify fields with python3, PUT it back
update_arr_config() {
    local name="$1" url="$2" api_key="$3" endpoint="$4" python_updates="$5"
    local config config_id updated

    config=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/${endpoint}" 2>/dev/null) || true
    [[ -z "$config" ]] && { log_warn "  Could not retrieve ${name} ${endpoint}."; return 1; }

    config_id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$config" 2>/dev/null) || true
    [[ -z "$config_id" ]] && { log_warn "  Could not parse ${name} ${endpoint} ID."; return 1; }

    updated=$(python3 -c "
import json, sys
c = json.loads(sys.argv[1])
${python_updates}
print(json.dumps(c))
" "$config" 2>/dev/null) || true
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

    python3 -c "
import json, sys, urllib.request
profiles = json.loads(sys.argv[1])
url = sys.argv[2]
api_key = sys.argv[3]
ok = 0
for p in profiles:
    p['upgradeAllowed'] = True
    req = urllib.request.Request(
        url + '/api/v3/qualityprofile/' + str(p['id']),
        data=json.dumps(p).encode(),
        headers={'Content-Type': 'application/json', 'X-Api-Key': api_key},
        method='PUT'
    )
    try:
        urllib.request.urlopen(req)
        ok += 1
    except Exception:
        pass
sys.exit(0 if ok > 0 else 1)
" "$profiles" "$url" "$api_key" 2>/dev/null
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

    # python3 is needed for JSON manipulation in advanced config
    local HAS_PYTHON3=false
    if command -v python3 &>/dev/null; then
        HAS_PYTHON3=true
    else
        log_warn "python3 not found. Advanced config (naming, media management, quality profiles) will be skipped."
    fi

    local radarr_url="http://localhost:${SVC_PORTS[radarr]}"
    local sonarr_url="http://localhost:${SVC_PORTS[sonarr]}"
    local prowlarr_url="http://localhost:${SVC_PORTS[prowlarr]}"

    # Wait for all three services (Prowlarr uses API v1, Radarr/Sonarr use v3)
    local radarr_ready=false sonarr_ready=false prowlarr_ready=false
    wait_for_service "Radarr" "$radarr_url" "$RADARR_API_KEY" 90 "v3" && radarr_ready=true
    wait_for_service "Sonarr" "$sonarr_url" "$SONARR_API_KEY" 90 "v3" && sonarr_ready=true
    wait_for_service "Prowlarr" "$prowlarr_url" "$PROWLARR_API_KEY" 90 "v1" && prowlarr_ready=true

    # --- Radarr ---
    if [[ "$radarr_ready" == "true" ]]; then
        local radarr_naming="
c['renameMovies'] = True
c['replaceIllegalCharacters'] = True
c['colonReplacementFormat'] = 'dash'
c['standardMovieFormat'] = '{Movie CleanTitle} ({Release Year}) [{Quality Full}]'
c['movieFolderFormat'] = '{Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]'
"
        configure_arr_service "Radarr" "$radarr_url" "$RADARR_API_KEY" "radarr" 7878 "/data/media/movies" "$radarr_naming"
    fi

    # --- Sonarr ---
    if [[ "$sonarr_ready" == "true" ]]; then
        local sonarr_naming="
c['renameEpisodes'] = True
c['replaceIllegalCharacters'] = True
c['colonReplacementFormat'] = 4
c['standardEpisodeFormat'] = '{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]'
c['dailyEpisodeFormat'] = '{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Quality Full}]'
c['animeEpisodeFormat'] = '{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Full}]'
c['seasonFolderFormat'] = 'Season {season:00}'
c['seriesFolderFormat'] = '{Series TitleYear}'
"
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
    log_info "Auto-configuration complete."
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
        echo -e "  ${GREEN}✓${NC} Prowlarr → Radarr app connection"
        echo -e "  ${GREEN}✓${NC} Prowlarr → Sonarr app connection"
        if [[ "$MEDIA_SERVER" == "plex" ]]; then
        echo -e "  ${GREEN}✓${NC} Radarr → Plex notification (instant library updates)"
        echo -e "  ${GREEN}✓${NC} Sonarr → Plex notification (instant library updates)"
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
    echo -e "   • ${YELLOW}Set up credentials on first launch${NC}"
    echo -e "   • ${GREEN}TorBox API key pre-configured ✓${NC}"
    echo -e "   • ${GREEN}Rclone Folder set to /mnt/remote/torbox/__all__ ✓${NC}"
    echo -e "   • ${GREEN}WebDAV enabled ✓${NC}"
    echo -e "   • ${GREEN}Rclone mount enabled, path /mnt/remote ✓${NC}"
    echo "   • After creating credentials, verify the above in Debrid & Rclone tabs"
    echo ""
    echo -e "${CYAN}2. Prowlarr${NC}"
    echo "   • Open http://localhost:9696"
    echo -e "   • ${YELLOW}Set up authentication (Settings → General → Authentication)${NC}"
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        echo -e "   • ${GREEN}Byparr proxy already configured ✓${NC}"
        echo -e "   • ${GREEN}Radarr & Sonarr apps already connected ✓${NC}"
    else
        echo "   • Add FlareSolverr proxy: Settings → Indexers → Add → FlareSolverr"
        echo "     - Tag: flaresolverr"
        echo "     - Host: http://byparr:8191"
        echo "   • Add Radarr & Sonarr as apps: Settings → Apps → Add"
        echo "     - Radarr: http://radarr:7878  (API key: $(mask_key "${RADARR_API_KEY}"))"
        echo "     - Sonarr: http://sonarr:8989  (API key: $(mask_key "${SONARR_API_KEY}"))"
    fi
    echo "   • Add indexers (torrent sites) you want to use"
    echo ""
    echo -e "${CYAN}3. Radarr${NC}"
    echo "   • Open http://localhost:7878"
    echo -e "   • ${YELLOW}Set up authentication (Settings → General → Authentication)${NC}"
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
    echo -e "   • ${YELLOW}Set up authentication (Settings → General → Authentication)${NC}"
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
        echo "   • Complete initial setup wizard"
        echo "   • Add libraries:"
        echo "     - Movies: /data/media/movies"
        echo "     - TV Shows: /data/media/tv"
    else
        echo -e "${CYAN}5. Jellyfin${NC}"
        echo "   • Open http://localhost:8096"
        echo "   • Complete initial setup wizard"
        echo "   • Add libraries:"
        echo "     - Movies: /data/media/movies"
        echo "     - TV Shows: /data/media/tv"
    fi

    echo ""
    echo -e "${CYAN}6. Seerr${NC}"
    echo "   • Open http://localhost:5055"
    echo "   • Supports both Plex and Jellyfin"
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        echo "   • Sign in with your Plex account"
        echo -e "   • Connect to Plex using: ${YELLOW}http://plex:32400${NC}"
        echo "     Plex is on the same Docker network — use the container name."
    else
        echo "   • Sign in and connect to Jellyfin (http://jellyfin:8096)"
    fi
    echo "   • Add Radarr & Sonarr servers"
    echo "     - Radarr: http://radarr:7878 + API key: $(mask_key "${RADARR_API_KEY}")"
    echo "     - Sonarr: http://sonarr:8989 + API key: $(mask_key "${SONARR_API_KEY}")"
    echo ""

    echo -e "${BOLD}━━━━ Important Notes ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  Authentication is disabled for local addresses by default.${NC}"
    echo "     This allows API auto-configuration to work on first launch."
    echo "     Set up credentials in each service's Settings → General → Authentication."
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
    echo "  ./manage.sh update   # Pull latest & restart"
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

check_existing_installation() {
    if [[ -f "${ENV_FILE}" ]]; then
        log_section "Existing Installation Detected"
        log_warn "A previous installation was found at: ${INSTALL_DIR}"
        echo ""
        echo "  Re-running will regenerate Docker Compose, configs, and systemd service."
        echo "  Your existing API keys will be PRESERVED to avoid breaking integrations."
        echo ""
        read -rp "Continue with re-configuration? [y/N]: " rerun
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

        if [[ -n "$EXISTING_RADARR_API_KEY" ]]; then
            log_info "Existing API keys loaded and will be preserved."
        fi
        echo ""
    fi
}

start_services() {
    log_section "Starting Services"

    read -rp "Start all services now? [Y/n]: " start_now
    if [[ "${start_now,,}" != "n" ]]; then
        log_step "Starting Docker containers (first run downloads ~5-8 GB of images, this may take several minutes)..."
        cd "${INSTALL_DIR}"

        detect_compose_cmd

        if ! "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d --remove-orphans; then
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

main() {
    # Warn if running as root (PUID/PGID would default to 0:0, usually undesirable)
    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root. Container PUID/PGID will default to 0:0."
        log_warn "Consider running as a regular user instead."
        echo ""
        read -rp "Continue as root? [y/N]: " run_as_root
        if [[ "${run_as_root,,}" != "y" ]]; then
            log_info "Re-run as a regular user: ./setup.sh"
            exit 0
        fi
    fi

    print_banner
    check_existing_installation
    check_dependencies
    gather_config
    check_port_conflicts
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
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
