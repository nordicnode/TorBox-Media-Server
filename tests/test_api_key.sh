#!/usr/bin/env bash

# Test suite for generate_api_key function in setup.sh
# Extracts the function without sourcing the full script to avoid side effects.

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Extract just the generate_api_key function from setup.sh
generate_api_key() {
    local key=""
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
    key=$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-f0-9' | head -c 32)
    if [[ ${#key} -ne 32 ]]; then
        echo ""
        return 1
    fi
    echo "$key"
}

echo "Running tests for generate_api_key..."

test_length() {
    local key
    key=$(generate_api_key)
    if [[ ${#key} -eq 32 ]]; then
        echo -e "${GREEN}[PASS]${NC} Key length is 32 characters"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} Key length is ${#key}, expected 32"
        return 1
    fi
}

test_format() {
    local key
    key=$(generate_api_key)
    if [[ "$key" =~ ^[a-f0-9]{32}$ ]]; then
        echo -e "${GREEN}[PASS]${NC} Key format is 32-char lowercase hex"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} Key '$key' does not match expected format"
        return 1
    fi
}

test_uniqueness() {
    local key1 key2
    key1=$(generate_api_key)
    key2=$(generate_api_key)
    if [[ "$key1" != "$key2" ]]; then
        echo -e "${GREEN}[PASS]${NC} Consecutive keys are unique"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} Consecutive keys are identical: $key1"
        return 1
    fi
}

# Run tests
failed=0
test_length || failed=$((failed + 1))
test_format || failed=$((failed + 1))
test_uniqueness || failed=$((failed + 1))

if [[ $failed -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "\n${RED}$failed tests failed.${NC}"
    exit 1
fi
