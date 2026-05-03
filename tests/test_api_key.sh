#!/usr/bin/env bash

# Test suite for generate_api_key function in setup.sh
# Sources shared test utilities.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test_utils.sh
source "${SCRIPT_DIR}/test_utils.sh"

echo "Running tests for generate_api_key..."

test_length() {
    local key
    key=$(generate_api_key)
    if [[ ${#key} -eq 32 ]]; then
        pass "Key length is 32 characters"
        return 0
    else
        fail "Key length is ${#key}, expected 32"
        return 1
    fi
}

test_format() {
    local key
    key=$(generate_api_key)
    if [[ "$key" =~ ^[a-f0-9]{32}$ ]]; then
        pass "Key format is 32-char lowercase hex"
        return 0
    else
        fail "Key '$key' does not match expected format"
        return 1
    fi
}

test_uniqueness() {
    local key1 key2
    key1=$(generate_api_key)
    key2=$(generate_api_key)
    if [[ "$key1" != "$key2" ]]; then
        pass "Consecutive keys are unique"
        return 0
    else
        fail "Consecutive keys are identical: $key1"
        return 1
    fi
}

# Run tests
test_length
test_format
test_uniqueness

print_summary
exit $?
