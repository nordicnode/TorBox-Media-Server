#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  TorBox Media Server - Uninstall Script
#  Removes all containers, configs, data, and systemd service.
# ============================================================================

NON_INTERACTIVE=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--non-interactive) NON_INTERACTIVE=true ;;
    esac
done

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
    # Use grep and cut to avoid sourcing the file; strip quotes and carriage returns
    grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'\' | tr -d '\r'
}

# Detect the correct docker compose command
COMPOSE_CMD=()
DOCKER_CMD=()
detect_compose_cmd() {
    if docker info &>/dev/null; then
        COMPOSE_CMD=(docker compose)
        DOCKER_CMD=(docker)
    else
        COMPOSE_CMD=(sudo docker compose)
        DOCKER_CMD=(sudo docker)
    fi
}

compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    # CD into directory so Docker auto-discovers both docker-compose.yml and docker-compose.override.yml
    (cd "${INSTALL_DIR}" && "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
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
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    read -rp "Are you sure you want to uninstall? [y/N]: " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
fi

echo ""

# Step 1: Stop and remove containers
log_info "Stopping and removing Docker containers..."
if [[ ${#DOCKER_CMD[@]} -eq 0 ]]; then
    detect_compose_cmd
fi

if [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" ]]; then
    compose_cmd down --remove-orphans 2>/dev/null || {
        log_warn "Docker compose down failed. Attempting manual cleanup..."
        for svc in decypharr prowlarr byparr radarr sonarr seerr plex jellyfin; do
            "${DOCKER_CMD[@]}" rm -f "$svc" 2>/dev/null || true
        done
    }
else
    log_warn "Missing .env or docker-compose.yml. Skipping compose down."
    for svc in decypharr prowlarr byparr radarr sonarr seerr plex jellyfin; do
        "${DOCKER_CMD[@]}" rm -f "$svc" 2>/dev/null || true
    done
fi

# Remove the Docker network (dynamically computed from project directory name)
project_name="$(basename "${INSTALL_DIR}")"
"${DOCKER_CMD[@]}" network rm "${project_name}_media-network" 2>/dev/null || true

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
    # Unmount all nested mounts (deepest first) using findmnt
    while read -r mount_point; do
        sudo umount -l "$mount_point" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET "${MOUNT_DIR}" 2>/dev/null | sort -r)
    # Unmount the FUSE mount itself
    if mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
        sudo umount -l "${MOUNT_DIR}" 2>/dev/null || true
    fi
    # Unmount the bind mount
    sudo umount -l "${MOUNT_DIR}" 2>/dev/null || true
    sudo rmdir "${MOUNT_DIR}" 2>/dev/null || {
        log_warn "Could not remove mount directory ${MOUNT_DIR} (may not be empty)."
    }
fi

# Step 4: Read images before deleting directory (for optional cleanup later)
_images=()
if [[ -f "${COMPOSE_FILE}" ]]; then
    while IFS= read -r img; do
        [[ -n "$img" ]] && _images+=("$img")
    done < <(grep 'image:' "${COMPOSE_FILE}" | awk '{print $2}')
fi

# Step 5: Remove installation directory
log_info "Removing installation directory..."
rm -rf "${INSTALL_DIR}"
log_info "Removed: ${INSTALL_DIR}"

# Step 6: Optionally remove Docker images
echo ""
if [[ "$NON_INTERACTIVE" == "true" ]]; then
    remove_images="n"
else
    read -rp "Remove Docker images to free ~5-8 GB of disk space? [y/N]: " remove_images
fi
if [[ "${remove_images,,}" == "y" ]]; then
    log_info "Removing Docker images..."
    if [[ ${#DOCKER_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    local_removed=0
    if [[ ${#_images[@]} -gt 0 ]]; then
        for img in "${_images[@]}"; do
            if "${DOCKER_CMD[@]}" rmi "$img" 2>/dev/null; then
                log_info "  Removed: $img"
                local_removed=$((local_removed + 1))
            fi
        done
    fi
    if [[ $local_removed -gt 0 ]]; then
        log_info "Removed ${local_removed} Docker image(s)."
    else
        log_warn "No images were removed (they may have already been cleaned up)."
    fi
else
    log_info "Docker images kept. Remove them later with: docker rmi <image-name>"
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""
echo "Your TorBox account and cloud-stored media are unaffected."
echo "To reinstall, run: ./setup.sh"
