#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library_copy="$(mktemp)"
test_fleet_package="/tmp/setup-raw-test-fleet-$$.deb"
trap 'rm -f "$library_copy" "$test_fleet_package"' EXIT

sed '/^parse_tolerance_flag "\$@"/,$d' "${repo_root}/setup-raw.sh" > "$library_copy"
# shellcheck source=/dev/null
source "$library_copy"
FLEET_PKG_AMD64="../tmp/$(basename "$test_fleet_package")"
ORBIT_FLEET_URL_VALUE="https://fleet.example.invalid"
ORBIT_ENROLL_SECRET_VALUE="test-enrollment-secret"
detect_debian_architecture() { printf 'amd64\n'; }
verify_fleet_package() { :; }

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

test_fleet_package_selection() {
    (
        detect_debian_architecture() { printf 'amd64\n'; }
        select_fleet_package
        [[ "$SELECTED_FLEET_URL" == "$FLEET_AMD64_URL" ]] \
            || fail "amd64 selected the wrong Fleet URL"
        [[ "$SELECTED_FLEET_PKG" == "$FLEET_PKG_AMD64" ]] \
            || fail "amd64 selected the wrong Fleet package"
    )

    (
        detect_debian_architecture() { printf 'arm64\n'; }
        select_fleet_package
        [[ "$SELECTED_FLEET_URL" == "$FLEET_ARM64_URL" ]] \
            || fail "arm64 selected the wrong Fleet URL"
        [[ "$SELECTED_FLEET_PKG" == "$FLEET_PKG_ARM64" ]] \
            || fail "arm64 selected the wrong Fleet package"
    )

    (
        detect_debian_architecture() { printf 'riscv64\n'; }
        if select_fleet_package; then
            fail "unsupported architecture selected a Fleet package"
        fi
    )
}

test_arm64_install_uses_arm_package() {
    local trace
    local test_arm64_package
    trace="$(mktemp)"
    test_arm64_package="../tmp/$(basename "$test_fleet_package")"

    (
        detect_debian_architecture() { printf 'arm64\n'; }
        FLEET_PKG_ARM64="$test_arm64_package"
        download_file() { printf 'download %s %s %s\n' "$@" >> "$trace"; }
        apt_install() { printf 'install %s\n' "$*" >> "$trace"; }
        configure_fleet_enrollment() { :; }

        install_fleet_package
    )

    [[ "$(sed -n '1p' "$trace")" == "download ${FLEET_ARM64_URL} /opt/${test_arm64_package} 0644" ]] \
        || fail "arm64 install used the wrong Fleet download"
    [[ "$(sed -n '2p' "$trace")" == "install /opt/${test_arm64_package}" ]] \
        || fail "arm64 install used the wrong Fleet package path"
    rm -f "$trace"
}

test_missing_fleet_configuration_respects_tolerance_mode() {
    (
        ORBIT_FLEET_URL_VALUE=""
        ORBIT_ENROLL_SECRET_VALUE=""
        TOLERATE_FAILURES=true
        install_fleet_package || fail "default mode rejected missing Fleet configuration"
    )

    (
        ORBIT_FLEET_URL_VALUE=""
        ORBIT_ENROLL_SECRET_VALUE=""
        TOLERATE_FAILURES=false
        if install_fleet_package; then
            fail "strict mode tolerated missing Fleet configuration"
        fi
    )
}

test_transient_fleet_enrollment_cleanup_and_restart() {
    local test_root
    test_root="$(mktemp -d)"

    (
        ORBIT_DEFAULTS_PATH="${test_root}/orbit"
        FLEET_RUNTIME_DIR="${test_root}/run/fleet-enrollment"
        FLEET_SECRET_PATH="${FLEET_RUNTIME_DIR}/secret"
        FLEET_SYSTEMD_DROPIN_DIR="${test_root}/run/systemd/orbit.service.d"
        FLEET_NODE_KEY_PATH="${test_root}/opt/orbit/secret-orbit-node-key.txt"
        ORBIT_FLEET_URL_VALUE="https://fleet.example.invalid"
        ORBIT_ENROLL_SECRET_VALUE="test-enrollment-secret"
        FLEET_PACKAGE_INSTALLED=true
        TOLERATE_FAILURES=false

        mkdir -p "$(dirname "$FLEET_NODE_KEY_PATH")"
        printf '%s\n' \
            'ORBIT_ENROLL_SECRET=legacy-secret' \
            'ORBIT_HOST_IDENTIFIER=instance' \
            > "$ORBIT_DEFAULTS_PATH"

        systemctl() {
            if [[ "$1" == "restart" ]]; then
                printf 'node-key\n' > "$FLEET_NODE_KEY_PATH"
            fi
            return 0
        }
        sleep() { :; }

        mkdir -p "$FLEET_RUNTIME_DIR"
        printf '%s\n' "$ORBIT_ENROLL_SECRET_VALUE" > "$FLEET_SECRET_PATH"
        ORBIT_ENROLL_SECRET_VALUE=""

        configure_fleet_enrollment

        [[ ! -e "$FLEET_SECRET_PATH" ]] || fail "transient Fleet secret was retained"
        [[ ! -e "${FLEET_SYSTEMD_DROPIN_DIR}/enrollment.conf" ]] \
            || fail "transient Fleet systemd drop-in was retained"
        grep -qx 'ORBIT_FLEET_URL=https://fleet.example.invalid' "$ORBIT_DEFAULTS_PATH" \
            || fail "Fleet URL was not persisted"
        ! grep -Eq '^ORBIT_(ENROLL_SECRET|ENROLL_SECRET_PATH|HOST_IDENTIFIER)=' "$ORBIT_DEFAULTS_PATH" \
            || fail "Fleet enrollment or identity override persisted"
        [[ -s "$FLEET_NODE_KEY_PATH" ]] || fail "Fleet node key was not retained"
    )

    rm -rf "$test_root"
}

test_incoming_secret_is_staged_and_cleared_from_environment() {
    local test_root
    test_root="$(mktemp -d)"

    (
        FLEET_RUNTIME_DIR="${test_root}/fleet-enrollment"
        FLEET_SECRET_PATH="${FLEET_RUNTIME_DIR}/secret"
        ORBIT_ENROLL_SECRET="test-enrollment-secret"
        ORBIT_ENROLL_SECRET_VALUE="$ORBIT_ENROLL_SECRET"
        chown() { :; }
        install() {
            mkdir -p "${*: -1}"
            chmod 0700 "${*: -1}"
        }

        stage_incoming_fleet_enroll_secret

        [[ "$(cat "$FLEET_SECRET_PATH")" == "test-enrollment-secret" ]] \
            || fail "Incoming Fleet enrollment secret was not staged"
        [[ "$ORBIT_ENROLL_SECRET_VALUE" == "" ]] \
            || fail "In-memory Fleet enrollment value was not cleared"
        [[ -z "${ORBIT_ENROLL_SECRET+x}" ]] \
            || fail "Fleet enrollment environment variable was not unset"
        fleet_enrollment_configured \
            || fail "Staged Fleet enrollment secret was not recognized"
    )

    rm -rf "$test_root"
}

test_fleet_failure_is_tolerated_by_default() {
    (
        TOLERATE_FAILURES=true
        download_file() { return 1; }

        install_fleet_package || fail "default mode rejected a Fleet download failure"
    )
}

test_fleet_failure_is_strict_when_requested() {
    (
        TOLERATE_FAILURES=false
        download_file() { return 1; }

        if install_fleet_package; then
            fail "strict mode tolerated a Fleet download failure"
        fi
    )
}

test_fleet_install_failure_respects_tolerance_mode() {
    (
        download_file() { return 0; }
        apt_install() { return 1; }

        TOLERATE_FAILURES=true
        install_fleet_package || fail "default mode rejected a Fleet installation failure"

        TOLERATE_FAILURES=false
        if install_fleet_package; then
            fail "strict mode tolerated a Fleet installation failure"
        fi
    )
}

test_default_setup_keeps_combined_package_transaction() {
    local trace
    trace="$(mktemp)"

    (
        TOLERATE_FAILURES=true
        download_file() { :; }
        apt_install() { printf '%s\n' "$*" >> "$trace"; }

        install_metrics_packages
    )

    [[ "$(wc -l < "$trace" | tr -d ' ')" == "1" ]] \
        || fail "Default setup used more than one apt transaction"
    grep -q "grafana influxdb2 influxdb2-cli telegraf /opt/" "$trace" \
        || fail "Default apt transaction did not include both metrics and Fleet"
    rm -f "$trace"
}

test_combined_install_failure_respects_tolerance_mode() {
    local trace
    trace="$(mktemp)"

    (
        TOLERATE_FAILURES=true
        download_file() { :; }
        apt_install() {
            printf '%s\n' "$*" >> "$trace"
            [[ "$(wc -l < "$trace" | tr -d ' ')" -gt 1 ]]
        }

        install_metrics_packages
    ) || fail "Default mode did not preserve the metrics-only fallback"

    [[ "$(wc -l < "$trace" | tr -d ' ')" == "2" ]] \
        || fail "Default fallback did not use exactly two apt attempts"
    [[ "$(tail -n 1 "$trace")" == "grafana influxdb2 influxdb2-cli telegraf" ]] \
        || fail "Default fallback did not retry metrics packages without Fleet"

    : > "$trace"
    (
        TOLERATE_FAILURES=false
        download_file() { :; }
        apt_install() {
            printf '%s\n' "$*" >> "$trace"
            return 1
        }

        if install_metrics_packages; then
            fail "Strict mode tolerated a combined package installation failure"
        fi
    )

    [[ "$(wc -l < "$trace" | tr -d ' ')" == "1" ]] \
        || fail "Strict mode retried without Fleet"
    rm -f "$trace"
}

test_full_setup_fleet_download_failure_respects_tolerance_mode() {
    local trace
    trace="$(mktemp)"

    (
        TOLERATE_FAILURES=true
        download_file() { return 1; }
        apt_install() { printf '%s\n' "$*" >> "$trace"; }

        install_metrics_packages
    ) || fail "Default mode rejected a Fleet download failure"

    [[ "$(cat "$trace")" == "grafana influxdb2 influxdb2-cli telegraf" ]] \
        || fail "Default mode did not continue with metrics packages after Fleet download failed"

    : > "$trace"
    (
        TOLERATE_FAILURES=false
        download_file() { return 1; }
        apt_install() { printf '%s\n' "$*" >> "$trace"; }

        if install_metrics_packages; then
            fail "Strict mode tolerated a Fleet download failure"
        fi
    )

    [[ ! -s "$trace" ]] || fail "Strict mode installed metrics packages after Fleet download failed"
    rm -f "$trace"
}

test_fleet_only_skips_metrics_stack() {
    local trace
    trace="$(mktemp)"

    (
        require_root() { :; }
        detect_hostid() { printf 'test-host'; }
        install_base_packages() { echo base >> "$trace"; }
        set_instance_hostname() { echo hostname >> "$trace"; }
        install_fleet_package() { echo fleet >> "$trace"; }
        collect_hardware_metadata() { echo metadata >> "$trace"; }
        configure_repositories() { echo repositories >> "$trace"; }
        install_metrics_packages() { echo metrics >> "$trace"; }
        configure_fleet_enrollment() { echo fleet-config >> "$trace"; }
        configure_influxdb() { echo influxdb >> "$trace"; }
        configure_telegraf() { echo telegraf >> "$trace"; }
        configure_grafana() { echo grafana >> "$trace"; }
        restore_tmp_permissions() { echo tmp >> "$trace"; }
        stage_incoming_fleet_enroll_secret() { :; }

        main --fleet-only --skip-hostname-conf
    )

    [[ "$(cat "$trace")" == $'base\nhostname\nfleet\ntmp' ]] \
        || fail "Fleet-only mode invoked unexpected setup steps: $(tr '\n' ' ' < "$trace")"
    rm -f "$trace"
}

test_full_setup_retains_metrics_stack() {
    local trace
    trace="$(mktemp)"

    (
        require_root() { :; }
        detect_hostid() { printf 'test-host'; }
        install_base_packages() { echo base >> "$trace"; }
        set_instance_hostname() { echo hostname >> "$trace"; }
        collect_hardware_metadata() { echo metadata >> "$trace"; }
        configure_repositories() { echo repositories >> "$trace"; }
        install_metrics_packages() { echo metrics >> "$trace"; }
        configure_fleet_enrollment() { echo fleet-config >> "$trace"; }
        configure_influxdb() { echo influxdb >> "$trace"; }
        configure_telegraf() { echo telegraf >> "$trace"; }
        configure_grafana() { echo grafana >> "$trace"; }
        restore_tmp_permissions() { echo tmp >> "$trace"; }
        stage_incoming_fleet_enroll_secret() { :; }

        main
    )

    [[ "$(cat "$trace")" == $'base\nhostname\nmetadata\nrepositories\nmetrics\nfleet-config\ninfluxdb\ntelegraf\ngrafana\ntmp' ]] \
        || fail "Full setup omitted or reordered required steps: $(tr '\n' ' ' < "$trace")"
    rm -f "$trace"
}

test_fleet_package_selection
test_arm64_install_uses_arm_package
test_missing_fleet_configuration_respects_tolerance_mode
test_incoming_secret_is_staged_and_cleared_from_environment
test_transient_fleet_enrollment_cleanup_and_restart
test_fleet_failure_is_tolerated_by_default
test_fleet_failure_is_strict_when_requested
test_fleet_install_failure_respects_tolerance_mode
test_default_setup_keeps_combined_package_transaction
test_combined_install_failure_respects_tolerance_mode
test_full_setup_fleet_download_failure_respects_tolerance_mode
test_fleet_only_skips_metrics_stack
test_full_setup_retains_metrics_stack

echo "PASS: setup-raw mode and Fleet failure handling"
