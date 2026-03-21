#!/usr/bin/env bash

# Test suite for generate_api_key function in setup.sh

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Source the script to test its functions
# We need to mock some variables that setup.sh expects to be defined
export SCRIPT_DIR="."
export INSTALL_DIR="./torbox-media-server"
export CONFIG_DIR="./torbox-media-server/configs"
export DATA_DIR="./torbox-media-server/data"
export MOUNT_DIR="/mnt/torbox-media"
export ENV_FILE="./torbox-media-server/.env"
export COMPOSE_FILE="./torbox-media-server/docker-compose.yml"

source ./setup.sh

echo "Running tests for generate_api_key..."

test_length() {
    local key=$(generate_api_key)
    if [[ ${#key} -eq 32 ]]; then
        echo -e "${GREEN}[PASS]${NC} Key length is 32 characters"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} Key length is ${#key}, expected 32"
        return 1
    fi
}

test_format() {
    local key=$(generate_api_key)
    if [[ "$key" =~ ^[a-f0-9]{32}$ ]]; then
        echo -e "${GREEN}[PASS]${NC} Key format is 32-char lowercase hex"
        return 0
    else
        echo -e "${RED}[FAIL]${NC} Key '$key' does not match expected format"
        return 1
    fi
}

test_uniqueness() {
    local key1=$(generate_api_key)
    local key2=$(generate_api_key)
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
