#!/usr/bin/env bash

# Comprehensive test suite for TorBox Media Server setup functions
# Tests key functions extracted from setup.sh without side effects.

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

passed=0
failed=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; failed=$((failed + 1)); }

# ============================================================================
#  Function: mask_key
# ============================================================================

mask_key() {
    local k="$1"
    if [[ ${#k} -gt 4 ]]; then
        echo "${k:0:4}...${k: -4}"
    else
        echo "$k"
    fi
}

test_mask_key_normal() {
    local result
    result=$(mask_key "abcdef1234567890abcdef1234567890")
    if [[ "$result" == "abcd...7890" ]]; then
        pass "mask_key masks 32-char key correctly"
    else
        fail "mask_key expected 'abcd...7890', got '$result'"
    fi
}

test_mask_key_short() {
    local result
    result=$(mask_key "ab")
    if [[ "$result" == "ab" ]]; then
        pass "mask_key returns short keys unchanged"
    else
        fail "mask_key short key expected 'ab', got '$result'"
    fi
}

test_mask_key_exact_4() {
    local result
    result=$(mask_key "abcd")
    if [[ "$result" == "abcd" ]]; then
        pass "mask_key returns 4-char keys unchanged"
    else
        fail "mask_key 4-char expected 'abcd', got '$result'"
    fi
}

test_mask_key_5_chars() {
    local result
    result=$(mask_key "abcde")
    if [[ "$result" == "abcd...bcde" ]]; then
        pass "mask_key masks 5-char key correctly"
    else
        fail "mask_key 5-char expected 'abcd...bcde', got '$result'"
    fi
}

# ============================================================================
#  Function: port conflict regex precision
# ============================================================================

test_port_regex_no_partial_match() {
    # Port 828 should NOT match in output containing port 8282
    local ss_output="LISTEN  0  128  0.0.0.0:8282  0.0.0.0:*"
    local port=828
    if echo "$ss_output" | grep -qE ":${port}[[:space:]]"; then
        fail "Port regex should not match partial port 828 in 8282"
    else
        pass "Port regex correctly rejects partial port match (828 vs 8282)"
    fi
}

test_port_regex_exact_match() {
    local ss_output="LISTEN  0  128  0.0.0.0:8282  0.0.0.0:*"
    local port=8282
    if echo "$ss_output" | grep -qE ":${port}[[:space:]]"; then
        pass "Port regex matches exact port 8282"
    else
        fail "Port regex should match exact port 8282"
    fi
}

test_port_regex_no_false_positive_828() {
    # Port 8282 should NOT match when checking for port 828
    local ss_output="tcp  LISTEN  0  128  0.0.0.0:8282  0.0.0.0:*"
    local port=828
    if echo "$ss_output" | grep -qE ":${port}[[:space:]]"; then
        fail "Port regex should not match 8282 when searching for port 828"
    else
        pass "Port regex rejects 8282 when searching for port 828"
    fi
}

test_port_regex_jellyfin_not_plex() {
    # Port 8096 should match, not 32400
    local ss_output="tcp  LISTEN  0  128  0.0.0.0:8096  0.0.0.0:*"
    if echo "$ss_output" | grep -qE ":8096[[:space:]]"; then
        pass "Port regex matches Jellyfin port 8096"
    else
        fail "Port regex should match port 8096"
    fi
    if echo "$ss_output" | grep -qE ":32400[[:space:]]"; then
        fail "Port regex should not match 32400 when not in ss output"
    else
        pass "Port regex correctly rejects 32400 when not present"
    fi
}

# ============================================================================
#  Function: API key validation regex
# ============================================================================

test_api_key_regex_valid() {
    local key="abc123def456ghi789jkl012mno345pq"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        pass "API key regex accepts valid alphanumeric key"
    else
        fail "API key regex should accept alphanumeric key"
    fi
}

test_api_key_regex_with_dots() {
    local key="abc.123.def.456"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        pass "API key regex accepts key with dots"
    else
        fail "API key regex should accept dots"
    fi
}

test_api_key_regex_with_hyphens() {
    local key="abc-123-def-456"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        pass "API key regex accepts key with hyphens"
    else
        fail "API key regex should accept hyphens"
    fi
}

test_api_key_regex_rejects_spaces() {
    local key="abc 123 def"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject spaces"
    else
        pass "API key regex rejects keys with spaces"
    fi
}

test_api_key_regex_rejects_special() {
    local key="abc;rm -rf /"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject shell metacharacters"
    else
        pass "API key regex rejects shell metacharacters"
    fi
}

test_api_key_regex_rejects_backtick() {
    local key='abc`whoami`'
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject backticks"
    else
        pass "API key regex rejects backticks"
    fi
}

test_api_key_regex_rejects_dollar() {
    local key='abc$(id)'
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject dollar signs"
    else
        pass "API key regex rejects dollar signs"
    fi
}

# ============================================================================
#  Function: mount path validation regex
# ============================================================================

test_mount_path_regex_valid() {
    local path="/mnt/torbox-media"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        fail "Mount path regex should accept valid path"
    else
        pass "Mount path regex accepts valid path"
    fi
}

test_mount_path_regex_rejects_spaces() {
    local path="/mnt/tor box media"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        pass "Mount path regex rejects spaces"
    else
        fail "Mount path regex should reject spaces"
    fi
}

test_mount_path_regex_rejects_special() {
    local path="/mnt/torbox;rm -rf"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        pass "Mount path regex rejects shell metacharacters"
    else
        fail "Mount path regex should reject special characters"
    fi
}

test_mount_path_regex_accepts_underscores() {
    local path="/mnt/torbox_media/test-dir"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        fail "Mount path regex should accept underscores and hyphens"
    else
        pass "Mount path regex accepts underscores and hyphens"
    fi
}

# ============================================================================
#  Function: env_val extraction (from .env files)
# ============================================================================

test_env_val_extraction() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo 'RADARR_API_KEY="abcdef123456"' > "$tmpdir/test.env"
    local result
    result=$(grep '^RADARR_API_KEY=' "$tmpdir/test.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ "$result" == "abcdef123456" ]]; then
        pass "env_val extracts quoted key correctly"
    else
        fail "env_val expected 'abcdef123456', got '$result'"
    fi
    rm -rf "$tmpdir"
}

test_env_val_no_quotes() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo 'RADARR_API_KEY=abcdef123456' > "$tmpdir/test.env"
    local result
    result=$(grep '^RADARR_API_KEY=' "$tmpdir/test.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ "$result" == "abcdef123456" ]]; then
        pass "env_val extracts unquoted key correctly"
    else
        fail "env_val expected 'abcdef123456', got '$result'"
    fi
    rm -rf "$tmpdir"
}

test_env_val_single_quotes() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "MOUNT_DIR='/mnt/torbox-media'" > "$tmpdir/test.env"
    local result
    result=$(grep '^MOUNT_DIR=' "$tmpdir/test.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ "$result" == "/mnt/torbox-media" ]]; then
        pass "env_val extracts single-quoted value correctly"
    else
        fail "env_val expected '/mnt/torbox-media', got '$result'"
    fi
    rm -rf "$tmpdir"
}

test_env_val_missing_key() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo 'OTHER_KEY=value' > "$tmpdir/test.env"
    local result
    result=$(grep '^RADARR_API_KEY=' "$tmpdir/test.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
    if [[ -z "$result" ]]; then
        pass "env_val returns empty for missing key"
    else
        fail "env_val should be empty for missing key, got '$result'"
    fi
    rm -rf "$tmpdir"
}

# ============================================================================
#  Function: API key hex validation (used in re-run .env validation)
# ============================================================================

test_hex_key_validation_valid() {
    local key="abcdef1234567890abcdef1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        pass "Hex validation accepts valid 32-char hex key"
    else
        fail "Hex validation should accept valid hex key"
    fi
}

test_hex_key_validation_too_short() {
    local key="abcdef1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        fail "Hex validation should reject short key"
    else
        pass "Hex validation rejects short key"
    fi
}

test_hex_key_validation_uppercase() {
    local key="ABCDEF1234567890ABCDEF1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        fail "Hex validation should reject uppercase key (lowercase only)"
    else
        pass "Hex validation rejects uppercase hex"
    fi
}

test_hex_key_validation_with_letters() {
    local key="ghijkl1234567890ghijkl1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        fail "Hex validation should reject non-hex letters"
    else
        pass "Hex validation rejects non-hex letters (g-z)"
    fi
}

# ============================================================================
#  Function: docker-compose image references (pinned versions)
# ============================================================================

test_image_versions_not_latest() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    if [[ ! -f "$setup_file" ]]; then
        setup_file="${script_dir}/setup.sh"
    fi
    if [[ ! -f "$setup_file" ]]; then
        echo -e "${CYAN}[SKIP]${NC} Cannot find setup.sh to check image versions"
        return
    fi
    # Check that no IMAGE_* variable uses :latest
    if grep -qE 'IMAGE_.*:latest' "$setup_file" 2>/dev/null; then
        fail "Found Docker images using :latest tag"
    else
        pass "No Docker images use :latest tag"
    fi
}

# ============================================================================
#  Function: docker-compose volume mounts (Decypharr read-only)
# ============================================================================

test_decypharr_config_mount_readonly() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    if [[ ! -f "$setup_file" ]]; then
        setup_file="${script_dir}/setup.sh"
    fi
    if [[ ! -f "$setup_file" ]]; then
        echo -e "${CYAN}[SKIP]${NC} Cannot find setup.sh to check Decypharr mount"
        return
    fi
    # Check that the Decypharr config volume uses file-level :ro mount
    if grep -q 'config.json:/app/config.json:ro' "$setup_file"; then
        pass "Decypharr config.json is mounted as read-only file"
    else
        fail "Decypharr config should use file-level :ro mount"
    fi
}

# ============================================================================
#  Run all tests
# ============================================================================

echo -e "${CYAN}Running TorBox Media Server test suite...${NC}"
echo ""

echo "--- mask_key tests ---"
test_mask_key_normal
test_mask_key_short
test_mask_key_exact_4
test_mask_key_5_chars

echo ""
echo "--- Port regex precision tests ---"
test_port_regex_no_partial_match
test_port_regex_exact_match
test_port_regex_no_false_positive_828
test_port_regex_jellyfin_not_plex

echo ""
echo "--- API key regex validation tests ---"
test_api_key_regex_valid
test_api_key_regex_with_dots
test_api_key_regex_with_hyphens
test_api_key_regex_rejects_spaces
test_api_key_regex_rejects_special
test_api_key_regex_rejects_backtick
test_api_key_regex_rejects_dollar

echo ""
echo "--- Mount path regex tests ---"
test_mount_path_regex_valid
test_mount_path_regex_rejects_spaces
test_mount_path_regex_rejects_special
test_mount_path_regex_accepts_underscores

echo ""
echo "--- .env extraction tests ---"
test_env_val_extraction
test_env_val_no_quotes
test_env_val_single_quotes
test_env_val_missing_key

echo ""
echo "--- Hex key validation tests ---"
test_hex_key_validation_valid
test_hex_key_validation_too_short
test_hex_key_validation_uppercase
test_hex_key_validation_with_letters

echo ""
echo "--- Docker compose template tests ---"
test_image_versions_not_latest
test_decypharr_config_mount_readonly

echo ""
echo "--- Feature detection tests ---"

test_yes_flag_support() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${script_dir}/setup.sh"
    if grep -q '\-\-yes\|--non-interactive' "$setup_file"; then
        pass "--yes/--non-interactive flag is supported"
    else
        fail "--yes/--non-interactive flag not found in setup.sh"
    fi
}

test_hw_auto_detect() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${script_dir}/setup.sh"
    if grep -q 'detected_intel' "$setup_file" && grep -q 'detected_nvidia' "$setup_file"; then
        pass "Hardware acceleration auto-detection is implemented"
    else
        fail "Hardware acceleration auto-detection not found"
    fi
}

test_seerr_auto_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${script_dir}/setup.sh"
    if grep -q 'configure_seerr' "$setup_file"; then
        pass "Seerr auto-configuration function exists"
    else
        fail "Seerr auto-configuration not found"
    fi
}

test_plex_library_auto_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${script_dir}/setup.sh"
    if grep -q 'configure_plex_libraries' "$setup_file"; then
        pass "Plex library auto-configuration function exists"
    else
        fail "Plex library auto-configuration not found"
    fi
}

test_default_indexer() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local setup_file="${script_dir}/../setup.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${script_dir}/setup.sh"
    if grep -q 'add_default_indexer' "$setup_file"; then
        pass "Default indexer function exists"
    else
        fail "Default indexer function not found"
    fi
}

test_yes_flag_support
test_hw_auto_detect
test_seerr_auto_config
test_plex_library_auto_config
test_default_indexer

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GREEN}$passed passed${NC}  ${RED}$failed failed${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ $failed -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}$failed test(s) failed.${NC}"
    exit 1
fi
