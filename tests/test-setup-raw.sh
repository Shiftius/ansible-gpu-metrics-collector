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
detect_debian_architecture() { printf 'amd64\n'; }

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

        install_fleet_package
    )

    [[ "$(sed -n '1p' "$trace")" == "download ${FLEET_ARM64_URL} /opt/${test_arm64_package} 0644" ]] \
        || fail "arm64 install used the wrong Fleet download"
    [[ "$(sed -n '2p' "$trace")" == "install /opt/${test_arm64_package}" ]] \
        || fail "arm64 install used the wrong Fleet package path"
    rm -f "$trace"
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
        configure_influxdb() { echo influxdb >> "$trace"; }
        configure_telegraf() { echo telegraf >> "$trace"; }
        configure_grafana() { echo grafana >> "$trace"; }
        restore_tmp_permissions() { echo tmp >> "$trace"; }

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
        load_or_create_metrics_secrets() { echo secrets >> "$trace"; }
        configure_influxdb() { echo influxdb >> "$trace"; }
        configure_telegraf() { echo telegraf >> "$trace"; }
        configure_grafana() { echo grafana >> "$trace"; }
        restore_tmp_permissions() { echo tmp >> "$trace"; }

        main
    )

    [[ "$(cat "$trace")" == $'base\nhostname\nmetadata\nrepositories\nmetrics\nsecrets\ninfluxdb\ntelegraf\ngrafana\ntmp' ]] \
        || fail "Full setup omitted or reordered required steps: $(tr '\n' ' ' < "$trace")"
    rm -f "$trace"
}

test_metrics_credentials_are_independent_and_local_only() {
    local first second third fourth

    first="$(random_local_secret)"
    second="$(random_local_secret)"
    third="$(random_local_secret)"
    fourth="$(random_local_secret)"
    [[ "$first" =~ ^[0-9a-f]{48}$ ]] || fail "Generated credential has unexpected format"
    [[ "$(printf '%s\n' "$first" "$second" "$third" "$fourth" | sort -u | wc -l | tr -d ' ')" == 4 ]] \
        || fail "Generated metrics credentials are not independent"

    ! grep -R -q 'LocaFluxCapacity2024' \
        "${repo_root}/setup-raw.sh" \
        "${repo_root}/playbook.yml" \
        "${repo_root}/roles/telegraf_config" \
        || fail "Fixed legacy metrics password remains in an install path"
    ! grep -Eq 'outputs\.timestream|AWS_(ACCESS_KEY|SECRET_KEY|TIMESTREAM_DB)' "${repo_root}/setup-raw.sh" \
        || fail "Raw installer still configures Timestream or AWS credentials"
    grep -q 'METRICS_SECRETS_FILE="${METRICS_SECRETS_FILE:-/etc/brev/metrics-secrets.env}"' "${repo_root}/setup-raw.sh" \
        || fail "Raw installer does not persist new-host local credentials"

    INFLUX_ADMIN_PASSWORD="$first"
    INFLUX_OPERATOR_TOKEN="$second"
    INFLUX_V1_PASSWORD="$third"
    GRAFANA_ADMIN_PASSWORD="$fourth"
    validate_metrics_secrets \
        || fail "Raw installer rejected four independent credentials"

    GRAFANA_ADMIN_PASSWORD="$first"
    if validate_metrics_secrets >/dev/null 2>&1; then
        fail "Raw installer accepted duplicate credentials"
    fi
}

test_fleet_package_selection
test_arm64_install_uses_arm_package
test_fleet_failure_is_tolerated_by_default
test_fleet_failure_is_strict_when_requested
test_fleet_install_failure_respects_tolerance_mode
test_default_setup_keeps_combined_package_transaction
test_combined_install_failure_respects_tolerance_mode
test_full_setup_fleet_download_failure_respects_tolerance_mode
test_fleet_only_skips_metrics_stack
test_full_setup_retains_metrics_stack
test_metrics_credentials_are_independent_and_local_only

echo "PASS: setup-raw mode and Fleet failure handling"
