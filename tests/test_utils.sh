#!/usr/bin/env bash

# Shared test utilities for TorBox Media Server test suites
# Source this file from individual test files.

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

passed=0
failed=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; failed=$((failed + 1)); }

# Source functions directly from setup.sh to ensure tests match implementation
SETUP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup.sh"
if [[ -f "$SETUP_SCRIPT" ]]; then
    # shellcheck disable=SC1090  # dynamic sourcing from process substitution is intentional — extracting functions from setup.sh
    source <(sed -n '/^generate_api_key() {/,/^}/p' "$SETUP_SCRIPT")
    # shellcheck disable=SC1090
    source <(sed -n '/^mask_key() /,/^}/p' "$SETUP_SCRIPT" 2>/dev/null || true)
    # Inline mask_key since it's a one-liner in setup.sh:
    # shellcheck disable=SC1090
    source <(grep '^mask_key() ' "$SETUP_SCRIPT")
else
    echo "Error: setup.sh not found at $SETUP_SCRIPT"
    exit 1
fi

print_summary() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}$passed passed${NC}  ${RED}$failed failed${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ $failed -eq 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "\n${RED}$failed test(s) failed.${NC}"
        return 1
    fi
}
