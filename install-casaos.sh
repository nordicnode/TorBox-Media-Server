#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# CasaOS one-click installer for TorBox Media Server
#
# This script is designed to be used as a CasaOS "custom app" installer.
# It clones the repo, runs setup.sh in non-interactive mode, and kicks
# off a credential sync so the *arr services get their admin passwords
# even when CasaOS starts containers before setup finishes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nordicnode/TorBox-Media-Server/main/install-casaos.sh | bash
#
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_URL="https://github.com/nordicnode/TorBox-Media-Server.git"
INSTALL_BASE="/DATA/AppData/torbox-media-server"
REPO_DIR="${INSTALL_BASE}/repo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Preflight ────────────────────────────────────────────────────────────────
if ! command -v git &>/dev/null; then
    log_error "git is required. Install it and re-run."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    log_error "docker is required. Install it and re-run."
    exit 1
fi

# ── Clone or update ───────────────────────────────────────────────────────────
if [[ -d "${REPO_DIR}/.git" ]]; then
    log_info "Updating existing repo at ${REPO_DIR}..."
    git -C "${REPO_DIR}" pull --ff-only || {
        log_warn "Could not fast-forward — resetting to main."
        git -C "${REPO_DIR}" fetch origin
        git -C "${REPO_DIR}" reset --hard origin/main
    }
else
    log_info "Cloning TorBox Media Server repo..."
    rm -rf "${REPO_DIR}"
    git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
fi

# ── Run setup.sh ─────────────────────────────────────────────────────────────
export TORBOX_INSTALL_DIR="${INSTALL_BASE}"
export TORBOX_START_SERVICES=true

log_info "Running setup.sh in non-interactive mode..."
cd "${REPO_DIR}"
bash setup.sh -y

# ── Credential sync ──────────────────────────────────────────────────────────
# CasaOS may start containers before setup.sh finishes configuring auth.
# Run a quick SYNC_AUTH_ONLY pass to re-push .env credentials into the *arrs.
log_info "Syncing admin credentials into running *arr services..."
SYNC_AUTH_ONLY=true bash setup.sh -y

log_info "CasaOS install complete!"
log_info "Manage services: cd ${TORBOX_INSTALL_DIR} && ./manage.sh"
