#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  TorBox Media Server - Uninstall Script
#  Removes all containers, configs, data, and systemd service.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/torbox-media-server"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SERVICE_NAME="torbox-media-server"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Safely read a value from .env without executing shell code
env_val() {
    local key="$1"
    grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

# Detect the correct docker compose command
COMPOSE_CMD=()
detect_compose_cmd() {
    if docker info &>/dev/null; then
        if docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD=(docker compose)
        else
            COMPOSE_CMD=(docker-compose)
        fi
    else
        if sudo docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD=(sudo docker compose)
        else
            COMPOSE_CMD=(sudo docker-compose)
        fi
    fi
}

compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

echo -e "${CYAN}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║           TorBox Media Server - Uninstall                   ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

if [[ ! -d "${INSTALL_DIR}" ]]; then
    log_error "Installation directory not found: ${INSTALL_DIR}"
    log_error "Nothing to uninstall."
    exit 1
fi

echo -e "${YELLOW}This will remove:${NC}"
echo "  - All Docker containers and the media-network"
echo "  - Systemd auto-start service (${SERVICE_NAME})"
echo "  - Installation directory: ${INSTALL_DIR}"
echo "  - Mount point and propagation"
echo ""
echo -e "${RED}Your TorBox account and cloud-stored media are NOT affected.${NC}"
echo ""
read -rp "Are you sure you want to uninstall? [y/N]: " confirm
if [[ "${confirm,,}" != "y" ]]; then
    log_info "Uninstall cancelled."
    exit 0
fi

echo ""

# Step 1: Stop and remove containers
log_info "Stopping and removing Docker containers..."
if [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]]; then
    compose_cmd down --remove-orphans 2>/dev/null || {
        log_warn "Docker compose down failed. Attempting manual cleanup..."
        # Try to stop containers by name
        for svc in decypharr prowlarr byparr radarr sonarr seerr plex jellyfin; do
            docker rm -f "$svc" 2>/dev/null || true
        done
    }
else
    log_warn "Missing .env or docker-compose.yml. Skipping compose down."
    for svc in decypharr prowlarr byparr radarr sonarr seerr plex jellyfin; do
        docker rm -f "$svc" 2>/dev/null || true
    done
fi

# Remove the Docker network if it exists
docker network rm torbox-media-server_media-network 2>/dev/null || true

# Step 2: Remove systemd service
log_info "Removing systemd service..."
if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    log_info "Systemd service '${SERVICE_NAME}' removed."
else
    log_warn "systemd not detected. Skipping service removal."
fi

# Step 3: Unmount and remove mount point
log_info "Cleaning up mount propagation..."
MOUNT_DIR="$(env_val MOUNT_DIR)"
if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
    # Unmount any FUSE mounts inside the mount directory
    if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
        sudo umount "${MOUNT_DIR}" 2>/dev/null || true
    fi
    # Also try to unmount the bind mount
    sudo umount "${MOUNT_DIR}" 2>/dev/null || true
    sudo rmdir "${MOUNT_DIR}" 2>/dev/null || {
        log_warn "Could not remove mount directory ${MOUNT_DIR} (may not be empty)."
    }
fi

# Step 4: Remove installation directory
log_info "Removing installation directory..."
rm -rf "${INSTALL_DIR}"
log_info "Removed: ${INSTALL_DIR}"

# Step 5: Optionally remove Docker images
echo ""
read -rp "Remove Docker images to free ~5-8 GB of disk space? [y/N]: " remove_images
if [[ "${remove_images,,}" == "y" ]]; then
    log_info "Removing Docker images..."
    for img in \
        cy01/blackhole \
        lscr.io/linuxserver/prowlarr \
        ghcr.io/thephaseless/byparr \
        lscr.io/linuxserver/radarr \
        lscr.io/linuxserver/sonarr \
        ghcr.io/seerr-team/seerr \
        lscr.io/linuxserver/plex \
        lscr.io/linuxserver/jellyfin \
    ; do
        docker rmi "$img" 2>/dev/null && log_info "  Removed: $img" || true
    done
    log_info "Docker images removed."
else
    log_info "Docker images kept. Remove them later with: docker rmi <image-name>"
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""
echo "Your TorBox account and cloud-stored media are unaffected."
echo "To reinstall, run: ./setup.sh"
