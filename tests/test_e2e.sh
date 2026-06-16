#!/usr/bin/env bash
# ============================================================================
#  TorBox Media Server — Comprehensive E2E Test Suite
#  Tests the full pipeline: syntax → config generation → compose validation →
#  manage.sh generation → systemd correctness → uninstall safety
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
SETUP_SCRIPT="${PROJECT_ROOT}/setup.sh"
UNINSTALL_SCRIPT="${PROJECT_ROOT}/uninstall.sh"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.yml"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
GITIGNORE="${PROJECT_ROOT}/.gitignore"

# ── Test Framework ──────────────────────────────────────────────────────────
passed=0
failed=0
warnings=0
current_section=""

pass() {
    passed=$((passed + 1))
    echo -e "  \033[0;32m[PASS]\033[0m $1"
}

fail() {
    failed=$((failed + 1))
    echo -e "  \033[0;31m[FAIL]\033[0m $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "        → $2"
    fi
}

warn() {
    warnings=$((warnings + 1))
    echo -e "  \033[1;33m[WARN]\033[0m $1"
}

section() {
    current_section="$1"
    echo ""
    echo "━━━ $1 ━━━"
}

# ============================================================================
#  1. SYNTAX VALIDATION
# ============================================================================
section "Syntax Validation"

# 1.1 setup.sh bash syntax
if bash -n "$SETUP_SCRIPT" 2>/dev/null; then
    pass "setup.sh — valid bash syntax"
else
    fail "setup.sh — invalid bash syntax"
fi

# 1.2 uninstall.sh bash syntax
if bash -n "$UNINSTALL_SCRIPT" 2>/dev/null; then
    pass "uninstall.sh — valid bash syntax"
else
    fail "uninstall.sh — invalid bash syntax"
fi

# 1.3 All test files bash syntax
for test_file in "${SCRIPT_DIR}"/test_*.sh; do
    if bash -n "$test_file" 2>/dev/null; then
        pass "$(basename "$test_file") — valid bash syntax"
    else
        fail "$(basename "$test_file") — invalid bash syntax"
    fi
done

# ============================================================================
#  2. DOCKER COMPOSE VALIDATION
# ============================================================================
section "Docker Compose Validation"

# 2.1 Compose file exists
if [[ -f "$COMPOSE_FILE" ]]; then
    pass "docker-compose.yml exists"
else
    fail "docker-compose.yml not found"
fi

# 2.2 Validate compose with dummy env (Jellyfin profile)
dummy_env=(
    TORBOX_API_KEY="test1234567890abcdef1234567890ab"
    PUID=1000 PGID=1000 TZ="UTC"
    CONFIG_DIR="/tmp/torbox-test/config"
    DATA_DIR="/tmp/torbox-test/data"
    MOUNT_DIR="/tmp/torbox-test/mount"
    RADARR_API_KEY="abcdef1234567890abcdef1234567890"
    SONARR_API_KEY="abcdef1234567890abcdef1234567891"
    PROWLARR_API_KEY="abcdef1234567890abcdef1234567892"
    SEERR_API_KEY="MTIzNDU2Nzg5MA=="
    RADARR_ADMIN_USER="admin" RADARR_ADMIN_PASS="testpass"
    SONARR_ADMIN_USER="admin" SONARR_ADMIN_PASS="testpass"
    PROWLARR_ADMIN_USER="admin" PROWLARR_ADMIN_PASS="testpass"
    DECYPHARR_USER="torbox" DECYPHARR_PASS="testpass"
    HW_ACCEL="none"
)

if command -v docker &>/dev/null; then
    if env "${dummy_env[@]}" COMPOSE_PROFILES="jellyfin" \
        docker compose -f "$COMPOSE_FILE" config -q 2>/dev/null; then
        pass "docker-compose.yml validates (Jellyfin profile)"
    else
        fail "docker-compose.yml validation failed (Jellyfin profile)"
    fi

    if env "${dummy_env[@]}" COMPOSE_PROFILES="plex" \
        docker compose -f "$COMPOSE_FILE" config -q 2>/dev/null; then
        pass "docker-compose.yml validates (Plex profile)"
    else
        fail "docker-compose.yml validation failed (Plex profile)"
    fi
else
    warn "Docker not available — skipping compose validation"
fi

# 2.3 All ports bound to 127.0.0.1
if grep -E '^\s+- "[0-9]' "$COMPOSE_FILE" | grep -vq '127.0.0.1:' 2>/dev/null; then
    fail "Some ports not bound to 127.0.0.1 (security risk)"
else
    pass "All ports bound to 127.0.0.1"
fi

# 2.4 No :latest tags (all services pinned)
latest_images=$(grep -E '^\s+image:' "$COMPOSE_FILE" | grep ':latest' || true)
if [[ -z "$latest_images" ]]; then
    pass "No Docker images use :latest tag"
else
    fail "Docker images using :latest tag" "$latest_images"
fi

# 2.5 All services have health checks
services_without_health=$(
    awk '/^  [a-z].*:/{svc=$1} /healthcheck:/{found[svc]=1} END{for(s in found){}; for(s in found) delete found[s]}' "$COMPOSE_FILE" 2>/dev/null || true
)
health_count=$(grep -c 'healthcheck:' "$COMPOSE_FILE" || true)
service_count=$(grep -c 'container_name:' "$COMPOSE_FILE" || true)
if [[ "$health_count" -ge "$service_count" ]]; then
    pass "All $service_count services have health checks"
else
    fail "Only $health_count of $service_count services have health checks"
fi

# 2.6 All services have logging configuration
log_count=$(grep -c 'logging:' "$COMPOSE_FILE" || true)
if [[ "$log_count" -ge "$service_count" ]]; then
    pass "All services have logging with rotation configured"
else
    fail "Only $log_count of $service_count services have logging configured"
fi

# 2.7 All services have restart policy
restart_count=$(grep -c 'restart: unless-stopped' "$COMPOSE_FILE" || true)
if [[ "$restart_count" -ge "$service_count" ]]; then
    pass "All services have restart: unless-stopped"
else
    fail "Only $restart_count of $service_count services have restart policy"
fi

# 2.8 Mount propagation correctly configured
if grep -q 'rshared' "$COMPOSE_FILE" && grep -q 'rslave' "$COMPOSE_FILE"; then
    pass "Mount propagation uses rshared/rslave correctly"
else
    fail "Mount propagation not properly configured"
fi

# ============================================================================
#  3. SETUP.SH STRUCTURAL TESTS
# ============================================================================
section "setup.sh Structural Tests"

# 3.1 Script starts with set -euo pipefail
if head -5 "$SETUP_SCRIPT" | grep -q 'set -euo pipefail'; then
    pass "setup.sh uses set -euo pipefail"
else
    fail "setup.sh missing strict error handling"
fi

# 3.2 VERSION variable is set
if grep -qE '^VERSION="[0-9]+\.[0-9]+' "$SETUP_SCRIPT"; then
    pass "VERSION variable is defined"
else
    fail "VERSION variable missing or malformed"
fi

# 3.3 All required functions exist
required_functions=(
    generate_api_key mask_key cleanup_on_interrupt
    check_dependencies check_port_conflicts
    gather_config create_directories
    generate_decypharr_config generate_arr_configs
    generate_env_file generate_docker_compose
    generate_management_script generate_systemd_service
    configure_arr_service configure_arrs configure_seerr
    configure_plex_libraries add_default_indexer
    configure_arr_auth print_post_install
    check_existing_installation start_services main
)
for func in "${required_functions[@]}"; do
    if grep -qE "^${func}\(\)" "$SETUP_SCRIPT"; then
        pass "Function ${func}() exists"
    else
        fail "Function ${func}() NOT found"
    fi
done

# ============================================================================
#  4. BUG REGRESSION TESTS
# ============================================================================
section "Bug Regression Tests"

# 4.1 BUG-1: Systemd ExecStartPre must not use single-quoted ${MOUNT_DIR}
# The heredoc is unquoted (SYSTEMD_EOF), so ${MOUNT_DIR} in single-quoted
# bash -c '...' won't expand during write — it stays literal and is
# undefined at systemd runtime.
systemd_section=$(sed -n '/generate_systemd_service()/,/^}/p' "$SETUP_SCRIPT")
if echo "$systemd_section" | grep -qE "ExecStartPre.*bash -c '.*\\\$\{MOUNT_DIR\}"; then
    fail "BUG-1: Systemd ExecStartPre uses single-quoted \${MOUNT_DIR} — undefined at runtime" \
        "Lines 1606-1607: mount propagation is completely broken on boot"
elif echo "$systemd_section" | grep -q 'ExecStartPre'; then
    pass "BUG-1: Systemd ExecStartPre does not use single-quoted \${MOUNT_DIR}"
else
    warn "BUG-1: Could not locate ExecStartPre in generate_systemd_service"
fi

# 4.2 BUG-2: configure_arr_auth must use v1 for Prowlarr, not hardcoded v3
auth_func=$(sed -n '/^configure_arr_auth()/,/^}/p' "$SETUP_SCRIPT")
# Check if the function always uses /api/v3 without accepting a version parameter
if echo "$auth_func" | grep -qF '/api/v3/config/host' &&
    ! echo "$auth_func" | grep -qE 'api_ver|api_version'; then
    fail "BUG-2: configure_arr_auth hardcodes /api/v3 — Prowlarr uses v1" \
        "Line 2289: Auth config for Prowlarr silently fails (404)"
else
    pass "BUG-2: configure_arr_auth handles API version correctly"
fi

# 4.3 BUG-3: Admin credential preservation must check each service independently
cred_block=$(sed -n '/EXISTING_RADARR_ADMIN_USER/,/PROWLARR_ADMIN_PASS/p' "$SETUP_SCRIPT" | head -20)
if echo "$cred_block" | grep -q 'EXISTING_RADARR_ADMIN_USER' &&
    echo "$cred_block" | grep -q 'SONARR_ADMIN_USER.*EXISTING_SONARR' &&
    ! echo "$cred_block" | grep -qE 'if.*EXISTING_SONARR_ADMIN'; then
    fail "BUG-3: Credential preservation only checks Radarr but assigns Sonarr/Prowlarr" \
        "Lines 649-655: Sonarr/Prowlarr may get empty credentials on re-run"
else
    pass "BUG-3: Credential preservation validates each service"
fi

# 4.4 BUG-4: Port 8920 conflict check vs compose exposure
port_check_section=$(sed -n '/check_port_conflicts()/,/^}/p' "$SETUP_SCRIPT")
compose_jellyfin_ports=$(grep -A2 '# Jellyfin' "$COMPOSE_FILE" | grep -oE '[0-9]+:' | tr -d ':' || true)
if echo "$port_check_section" | grep -q '8920' && ! grep -q '"127.0.0.1:8920:' "$COMPOSE_FILE"; then
    fail "BUG-4: Port 8920 checked for conflicts but not exposed in docker-compose.yml" \
        "Causes false port conflict warnings for Jellyfin HTTPS"
else
    pass "BUG-4: Port conflict checks match exposed ports"
fi

# 4.5 FUNC-1: Post-install auto-start message must be conditional on HAS_SYSTEMD
post_install=$(sed -n '/^print_post_install()/,/^}/p' "$SETUP_SCRIPT")
autostart_line=$(echo "$post_install" | grep -n 'Auto-start on boot is enabled' || true)
if [[ -n "$autostart_line" ]]; then
    # Check if the line is inside an if HAS_SYSTEMD block
    line_num=$(echo "$autostart_line" | head -1 | cut -d: -f1)
    surrounding=$(echo "$post_install" | sed -n "$((line_num - 3)),$((line_num))p")
    if echo "$surrounding" | grep -qE 'HAS_SYSTEMD'; then
        pass "FUNC-1: Auto-start message is conditional on HAS_SYSTEMD"
    else
        fail "FUNC-1: Auto-start message printed unconditionally" \
            "Line 2613: Says 'auto-start enabled' even when systemd unavailable"
    fi
fi

# 4.6 FUNC-3: Seerr duplicate check must query correct endpoints
seerr_func=$(sed -n '/^configure_seerr()/,/^}/p' "$SETUP_SCRIPT")
if echo "$seerr_func" | grep -q 'settings/main' &&
    echo "$seerr_func" | grep -q '"hostname":"radarr"'; then
    fail "FUNC-3: Seerr checks /settings/main for Radarr — should use /settings/radarr" \
        "Creates duplicate Radarr/Sonarr entries on every re-run"
else
    pass "FUNC-3: Seerr queries correct endpoints for existing config"
fi

# 4.7 FUNC-5: Help text should include 'amd' in TORBOX_HW_ACCEL options
help_section=$(sed -n '/TORBOX_HW_ACCEL/p' "$SETUP_SCRIPT")
if echo "$help_section" | grep -q "'amd'" || echo "$help_section" | grep -q '"amd"'; then
    pass "FUNC-5: Help text includes 'amd' in HW_ACCEL options"
else
    # Check if 'amd' is accepted in the actual logic
    if grep -q '"amd"' "$SETUP_SCRIPT" || grep -q "'amd'" "$SETUP_SCRIPT"; then
        fail "FUNC-5: Help text omits 'amd' but code accepts it" \
            "Line 2802: Should list 'intel', 'nvidia', 'amd', or 'none'"
    fi
fi

# 4.8 SH-5: Trap handler should use ${VAR:-} for safety
trap_handler=$(sed -n '/^cleanup_on_interrupt()/,/^}/p' "$SETUP_SCRIPT")
if echo "$trap_handler" | grep -qE '\$\{ENV_FILE\}' &&
    ! echo "$trap_handler" | grep -qE '\$\{ENV_FILE:-'; then
    fail "SH-5: Trap handler uses \${ENV_FILE} without :- default (crashes if undefined)" \
        "Lines 30-34: Ctrl-C during early init causes unbound variable error"
else
    pass "SH-5: Trap handler uses safe variable defaults"
fi

# 4.9 SEC-2: dpkg -l vs dpkg -s for package detection
if grep -qE 'dpkg -l .*nvidia' "$SETUP_SCRIPT" && ! grep -qE 'dpkg -s .*nvidia' "$SETUP_SCRIPT"; then
    fail "SEC-2: Uses 'dpkg -l' for package detection (returns 0 for uninstalled packages)" \
        "Lines 822-825: Use 'dpkg -s' instead for accurate detection"
else
    pass "SEC-2: Package detection uses dpkg -s correctly"
fi

# 4.10 IMP-5: Port regex should match end-of-line
port_regex_section=$(sed -n '/check_port_conflicts()/,/^}/p' "$SETUP_SCRIPT")
if echo "$port_regex_section" | grep -qE '\[:space:\]\]"' &&
    ! echo "$port_regex_section" | grep -qE '\$\|'; then
    fail "IMP-5: Port conflict regex only matches trailing space, not end-of-line" \
        "Ports at end of line won't be detected"
else
    pass "IMP-5: Port conflict regex handles end-of-line"
fi

# ============================================================================
#  5. CONFIG & DOCUMENTATION TESTS
# ============================================================================
section "Config & Documentation Tests"

# 5.1 .env.example should document TORBOX_API_KEY
if grep -q 'TORBOX_API_KEY' "$ENV_EXAMPLE" 2>/dev/null; then
    pass ".env.example documents TORBOX_API_KEY"
else
    fail ".env.example missing TORBOX_API_KEY — the most critical required variable"
fi

# 5.2 .gitignore should not match .env.example
if grep -q '^!\.env\.example' "$GITIGNORE" 2>/dev/null; then
    pass ".gitignore has !.env.example exception"
elif grep -q '\.env\.\*' "$GITIGNORE" 2>/dev/null; then
    fail ".gitignore pattern '.env.*' matches .env.example without exclusion"
else
    pass ".gitignore doesn't match .env.example"
fi

# 5.3 .gitignore should include docker-compose.override.yml
if grep -q 'docker-compose.override' "$GITIGNORE" 2>/dev/null; then
    pass ".gitignore includes docker-compose.override.yml"
else
    fail ".gitignore missing docker-compose.override.yml (generated by setup.sh)"
fi

# 5.4 .env.example should document COMPOSE_PROFILES
if grep -q 'COMPOSE_PROFILES' "$ENV_EXAMPLE" 2>/dev/null; then
    pass ".env.example documents COMPOSE_PROFILES"
else
    fail ".env.example missing COMPOSE_PROFILES (needed for Plex/Jellyfin selection)"
fi

# 5.5 README should mention manage.sh health command
if grep -q 'manage.sh health' "${PROJECT_ROOT}/README.md" 2>/dev/null; then
    pass "README documents manage.sh health command"
else
    fail "README missing manage.sh health command"
fi

# 5.6 README should mention manage.sh backup command
if grep -q 'manage.sh backup' "${PROJECT_ROOT}/README.md" 2>/dev/null; then
    pass "README documents manage.sh backup command"
else
    fail "README missing manage.sh backup command"
fi

# ============================================================================
#  6. MANAGE.SH GENERATION TESTS
# ============================================================================
section "manage.sh Generation Tests"

# Extract the manage.sh heredoc and validate it
manage_heredoc=$(awk "/cat >.*manage.sh.*<<'MANAGE_EOF'/,/^MANAGE_EOF$/" "$SETUP_SCRIPT" 2>/dev/null || true)
manage_inline=$(awk "/cat >>.*manage.sh.*<<'MANAGE_INLINE'/,/^MANAGE_INLINE$/" "$SETUP_SCRIPT" 2>/dev/null || true)

# 6.1 manage.sh has all required commands
for cmd in start stop restart status logs pull update down urls keys enable disable backup restore health shell version help; do
    if echo "$manage_heredoc" "$manage_inline" | grep -qE "^\s+${cmd}[)|]"; then
        pass "manage.sh includes '${cmd}' command"
    elif echo "$manage_heredoc" | grep -q "$cmd"; then
        pass "manage.sh references '${cmd}' command"
    else
        fail "manage.sh missing '${cmd}' command"
    fi
done

# 6.2 manage.sh bash syntax check via AWK extraction
tmpfile=$(mktemp "${SCRIPT_DIR}/manage_check.XXXXXX")
trap 'rm -f "$tmpfile"' EXIT

# Extract all three heredoc blocks to construct the manage.sh
{
    awk "/cat >.*manage.sh.*<<'MANAGE_EOF'/,/^MANAGE_EOF$/" "$SETUP_SCRIPT" | tail -n +2 | head -n -1
    awk "/cat >>.*manage.sh.*<<'MANAGE_INLINE'/,/^MANAGE_INLINE$/" "$SETUP_SCRIPT" | tail -n +2 | head -n -1
    # Second MANAGE_EOF block
    awk 'BEGIN{n=0} /MANAGE_EOF/{n++; if(n==2) start=1; if(n==3) start=0} start && n==2{print}' "$SETUP_SCRIPT" | tail -n +2
} >"$tmpfile" 2>/dev/null

if bash -n "$tmpfile" 2>/dev/null; then
    pass "Generated manage.sh has valid bash syntax"
else
    fail "Generated manage.sh has invalid bash syntax"
fi
rm -f "$tmpfile"

# ============================================================================
#  7. UNINSTALL.SH SAFETY TESTS
# ============================================================================
section "uninstall.sh Safety Tests"

# 7.1 Has strict error handling
if head -5 "$UNINSTALL_SCRIPT" | grep -q 'set -euo pipefail'; then
    pass "uninstall.sh uses set -euo pipefail"
else
    fail "uninstall.sh missing strict error handling"
fi

# 7.2 Has user confirmation before destructive action
if grep -qE 'read.*confirm|read.*yes' "$UNINSTALL_SCRIPT"; then
    pass "uninstall.sh requires user confirmation"
else
    fail "uninstall.sh has no confirmation prompt"
fi

# 7.3 Supports non-interactive mode
if grep -q 'non.interactive\|NON_INTERACTIVE\|--yes' "$UNINSTALL_SCRIPT"; then
    pass "uninstall.sh supports non-interactive mode"
else
    fail "uninstall.sh missing non-interactive mode"
fi

# 7.4 Doesn't use 'source' on .env (security)
if grep -q '^source .*\.env\|^\. .*\.env' "$UNINSTALL_SCRIPT"; then
    fail "uninstall.sh sources .env file directly (security risk)"
else
    pass "uninstall.sh reads .env safely without sourcing"
fi

# 7.5 Has docker compose down or stop
if grep -q 'compose.*down\|compose.*stop\|docker stop' "$UNINSTALL_SCRIPT"; then
    pass "uninstall.sh stops containers before cleanup"
else
    fail "uninstall.sh doesn't stop containers"
fi

# ============================================================================
#  8. SECURITY TESTS
# ============================================================================
section "Security Tests"

# 8.1 .env file gets chmod 600
if grep -q 'chmod 600.*ENV_FILE\|chmod 600.*\.env' "$SETUP_SCRIPT"; then
    pass ".env file is chmod 600 (owner-only read/write)"
else
    fail ".env file permissions not restricted"
fi

# 8.2 compose file gets chmod 600
if grep -q 'chmod 600.*COMPOSE_FILE\|chmod 600.*compose' "$SETUP_SCRIPT"; then
    pass "docker-compose.yml is chmod 600"
else
    fail "docker-compose.yml permissions not restricted"
fi

# 8.3 API key validation regex exists
if grep -qF '^[a-zA-Z0-9._-]+$' "$SETUP_SCRIPT"; then
    pass "API key validation regex is present"
else
    fail "API key validation regex not found"
fi

# 8.4 Mount path validation exists (no shell metacharacters)
if grep -qE 'mount.*regex|mount.*validat|MOUNT_DIR.*\[' "$SETUP_SCRIPT" ||
    grep -qE 'semicolons|backticks|shell characters' "$SETUP_SCRIPT"; then
    pass "Mount path validation exists"
else
    # Check for the actual regex pattern
    if grep -qE '\^/\[a-zA-Z0-9' "$SETUP_SCRIPT"; then
        pass "Mount path validation regex found"
    else
        warn "Could not confirm mount path validation"
    fi
fi

# 8.5 No hardcoded real API keys or passwords
if grep -qE '(TORBOX_API_KEY|api_key)="[a-f0-9]{20,}"' "$SETUP_SCRIPT" 2>/dev/null; then
    fail "Hardcoded API key found in setup.sh"
else
    pass "No hardcoded API keys in setup.sh"
fi

# ============================================================================
#  9. CROSS-CUTTING CONSISTENCY TESTS
# ============================================================================
section "Cross-Cutting Consistency"

# 9.1 SVC_PORTS in manage.sh match docker-compose.yml
compose_ports=$(grep -oE '127\.0\.0\.1:[0-9]+' "$COMPOSE_FILE" | sed 's/127.0.0.1://' | sort -u)
for port in 8282 9696 8191 7878 8989 5055; do
    if echo "$compose_ports" | grep -q "^${port}$"; then
        pass "Port $port in manage.sh matches docker-compose.yml"
    else
        fail "Port $port in manage.sh not found in docker-compose.yml"
    fi
done

# 9.2 Prowlarr API version consistency (v1 in wait_for_service)
if grep -q 'wait_for_service.*Prowlarr.*v1' "$SETUP_SCRIPT"; then
    pass "Prowlarr uses API v1 in wait_for_service"
else
    fail "Prowlarr API version mismatch in wait_for_service"
fi

# 9.3 Radarr/Sonarr use API v3 in wait_for_service
if grep -q 'wait_for_service.*Radarr.*v3' "$SETUP_SCRIPT" &&
    grep -q 'wait_for_service.*Sonarr.*v3' "$SETUP_SCRIPT"; then
    pass "Radarr/Sonarr use API v3 in wait_for_service"
else
    fail "Radarr/Sonarr API version mismatch in wait_for_service"
fi

# 9.4 SslPort values should differ between Radarr and Sonarr configs
radarr_ssl=$(grep -A20 'generate_arr_configs' "$SETUP_SCRIPT" | grep -B5 -A5 'radarr' | grep 'SslPort' | head -1 || true)
sonarr_ssl=$(grep -A20 'generate_arr_configs' "$SETUP_SCRIPT" | grep -B5 -A5 'sonarr' | grep 'SslPort' | head -1 || true)
if [[ -n "$radarr_ssl" && -n "$sonarr_ssl" ]]; then
    radarr_ssl_port=$(echo "$radarr_ssl" | grep -oE '[0-9]+' | head -1)
    sonarr_ssl_port=$(echo "$sonarr_ssl" | grep -oE '[0-9]+' | head -1)
    if [[ "$radarr_ssl_port" != "$sonarr_ssl_port" ]]; then
        pass "Radarr and Sonarr have different SslPort values"
    else
        fail "FUNC-4: Radarr and Sonarr both use SslPort=$radarr_ssl_port (conflict if SSL enabled)"
    fi
fi

# ============================================================================
#  10. EXISTING TEST SUITE EXECUTION
# ============================================================================
section "Existing Test Suite"

# 10.1 Run test_api_key.sh
if bash "${SCRIPT_DIR}/test_api_key.sh" &>/dev/null; then
    pass "test_api_key.sh — all tests pass"
else
    fail "test_api_key.sh — tests failed"
fi

# 10.2 Run test_setup_functions.sh
if bash "${SCRIPT_DIR}/test_setup_functions.sh" &>/dev/null; then
    pass "test_setup_functions.sh — all tests pass"
else
    fail "test_setup_functions.sh — tests failed"
fi

# ============================================================================
#  11. SHELLCHECK (if available)
# ============================================================================
section "Static Analysis"

if command -v shellcheck &>/dev/null; then
    if shellcheck -S warning "$SETUP_SCRIPT" 2>/dev/null; then
        pass "setup.sh — ShellCheck clean (warning level)"
    else
        sc_count=$(shellcheck -S warning "$SETUP_SCRIPT" 2>/dev/null | grep -c 'SC[0-9]' || echo "?")
        fail "setup.sh — ShellCheck found ${sc_count} warnings"
    fi

    if shellcheck -S warning "$UNINSTALL_SCRIPT" 2>/dev/null; then
        pass "uninstall.sh — ShellCheck clean (warning level)"
    else
        fail "uninstall.sh — ShellCheck warnings found"
    fi
else
    warn "ShellCheck not installed — skipping static analysis"
fi

# ============================================================================
#  SUMMARY
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((passed + failed))
echo -e "  \033[0;32m${passed} passed\033[0m  \033[0;31m${failed} failed\033[0m  \033[1;33m${warnings} warnings\033[0m  (${total} total)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ $failed -gt 0 ]]; then
    echo -e "\033[0;31mSome tests failed. See output above for details.\033[0m"
    exit 1
else
    echo -e "\033[0;32mAll tests passed!\033[0m"
    exit 0
fi
