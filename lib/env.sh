#!/usr/bin/env bash
# lib/env.sh — Shared environment file parsing library
# Source this in setup.sh, uninstall.sh, and manage.sh for consistent .env parsing.

# Safely read a value from .env without executing shell code.
# Strips inline comments preceded by whitespace (so passwords containing # are preserved),
# surrounding quotes (both single and double), carriage returns, and leading/trailing whitespace.
# Usage: env_val KEY ENV_FILE
env_val() {
    local key="$1"
    local env_file="${2:-${ENV_FILE:-}}"
    if [[ -z "$env_file" || ! -f "$env_file" ]]; then
        return 1
    fi
    grep "^${key}=" "${env_file}" 2>/dev/null | head -1 | cut -d= -f2- |
        sed 's/[[:space:]]#.*$//' | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Read .env values into the current shell WITHOUT sourcing it (avoids
# arbitrary code execution if .env contains shell metacharacters).
# Only sets variables not already defined in the environment.
# Usage: load_env_if_present ENV_FILE
load_env_if_present() {
    local env_file="${1:-${ENV_FILE:-}}"
    if [[ -z "$env_file" || ! -f "$env_file" ]]; then
        return 0
    fi
    while IFS='=' read -r _ek _ev; do
        # Skip blank lines and comments
        [[ -z "${_ek}" || "${_ek}" == \#* ]] && continue
        # Strip inline comments and surrounding quotes
        _ev="$(echo "${_ev}" | sed 's/\(#.*\)$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'" | tr -d '\r')"
        # Only set if not already defined in the environment
        if [[ -z "${!_ek+x}" ]]; then
            export "${_ek}=${_ev}"
        fi
    done <"${env_file}"
}

# Export functions for subshells if needed
export -f env_val
export -f load_env_if_present