#!/usr/bin/env bash

if [[ ${-} == *x* ]]; then
    echo "[ERROR] Do not run this script with shell tracing enabled; it can expose credentials." >&2
    exit 0
fi

set -Eeuo pipefail
set +x

export HISTFILE=/dev/null

readonly DEFAULT_RAW_INSTALLER_URL="https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/${INSTALLER_REF:-main}/setup-raw.sh"

RAW_INSTALLER_URL="${RAW_INSTALLER_URL:-$DEFAULT_RAW_INSTALLER_URL}"
# Failures are tolerated by default so parent bootstrap/orchestration scripts do
# not fail closed if this metrics setup encounters an issue.
TOLERATE_FAILURES=true

echo_info() {
    printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

echo_warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

echo_error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

exit_with_status() {
    local status="$1"

    if [[ "$status" -ne 0 && "$TOLERATE_FAILURES" == true ]]; then
        echo_warn "setup.sh failed with exit code ${status}; failure tolerance enabled, exiting 0."
        exit 0
    fi

    exit "$status"
}

parse_wrapper_args() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            --tolerate-failures)
                TOLERATE_FAILURES=true
                ;;
            --strict-failures)
                TOLERATE_FAILURES=false
                ;;
        esac
    done
}

run_main() {
    local status

    set +e
    (
        set -Eeuo pipefail
        main "$@"
    )
    status="$?"

    exit_with_status "$status"
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        bash "$@"
    else
        sudo -E bash "$@"
    fi
}

local_raw_installer() {
    local source_path="${BASH_SOURCE[0]:-}"
    local script_dir

    if [[ -z "$source_path" || "$source_path" == "bash" || "$source_path" == */bash ]]; then
        return 1
    fi

    script_dir="$(cd "$(dirname "$source_path")" && pwd)"
    if [[ -f "${script_dir}/setup-raw.sh" ]]; then
        printf '%s\n' "${script_dir}/setup-raw.sh"
        return 0
    fi

    return 1
}

download_raw_installer() {
    local dest="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW_INSTALLER_URL" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$RAW_INSTALLER_URL"
    else
        echo_error "Install curl or wget, or run setup.sh from a checkout that also contains setup-raw.sh."
        return 1
    fi

    chmod 0755 "$dest"
}

main() {
    local raw_installer=""
    local downloaded_installer=""
    local script_dir=""

    echo_info "Delegating setup to the raw shell installer..."

    if raw_installer="$(local_raw_installer)"; then
        echo_info "Using local setup-raw.sh."
        script_dir="$(cd "$(dirname "$raw_installer")" && pwd)"
        export ASSET_DIR="${ASSET_DIR:-$script_dir}"
    else
        downloaded_installer="$(mktemp)"
        echo_info "Downloading setup-raw.sh from ${RAW_INSTALLER_URL}..."
        download_raw_installer "$downloaded_installer"
        raw_installer="$downloaded_installer"
    fi

    run_as_root "$raw_installer" "$@"

    if [[ -n "$downloaded_installer" ]]; then
        rm -f "$downloaded_installer"
    fi

    echo_info "Setup invocation finished via setup-raw.sh."
}

parse_wrapper_args "$@"
run_main "$@"

# Sample call:
# curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash -s -- aws_timestream_access_key='' aws_timestream_secret_key='' aws_timestream_database='' environmentID=''
# Add --skip-hostname-conf to preserve the current hostname.
