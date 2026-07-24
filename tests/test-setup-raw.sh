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

fail() {
    echo "FAIL: $*" >&2
    exit 1
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
        configure_influxdb() { echo influxdb >> "$trace"; }
        configure_telegraf() { echo telegraf >> "$trace"; }
        configure_grafana() { echo grafana >> "$trace"; }
        restore_tmp_permissions() { echo tmp >> "$trace"; }

        main
    )

    [[ "$(cat "$trace")" == $'base\nhostname\nmetadata\nrepositories\nmetrics\ninfluxdb\ntelegraf\ngrafana\ntmp' ]] \
        || fail "Full setup omitted or reordered required steps: $(tr '\n' ' ' < "$trace")"
    rm -f "$trace"
}

test_fleet_failure_is_tolerated_by_default
test_fleet_failure_is_strict_when_requested
test_fleet_install_failure_respects_tolerance_mode
test_default_setup_keeps_combined_package_transaction
test_combined_install_failure_respects_tolerance_mode
test_full_setup_fleet_download_failure_respects_tolerance_mode
test_fleet_only_skips_metrics_stack
test_full_setup_retains_metrics_stack

echo "PASS: setup-raw mode and Fleet failure handling"
