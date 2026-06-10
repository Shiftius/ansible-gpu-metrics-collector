#!/usr/bin/env bash

set -Eeuo pipefail
set +x

PURGE_DATA=true
PURGE_BENCHMARK_CACHE=false
REFRESH_APT=false
FLEET_PACKAGE_NAME="${FLEET_PACKAGE_NAME:-fleet-osquery}"
FLEET_PKG_AMD64="${FLEET_PKG_AMD64:-fleet-1.0.0_amd64.deb}"
METADATA_PATH="${METADATA_PATH:-/etc/brev/metadata.json}"
TEMP_INFLUXDB_UNIT_CREATED=false
TEMP_INFLUXDB_UNIT_PATH="/etc/systemd/system/influxdb.service"

echo_info() {
    printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

echo_warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

echo_error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage: ./reset-setup.sh [options]

Removes the metrics collector installation so setup.sh and setup-via-ansible.sh
can be benchmarked from a cleaner state.

Options:
  --keep-data              Keep InfluxDB/Grafana/Telegraf data and /etc/brev metadata.
  --purge-benchmark-cache  Also remove /tmp/ansible_env, /tmp/mc, and /var/log/ansible.
  --refresh-apt            Run apt-get update after removing repository files.
  --fleet-package NAME     Fleet Debian package name to purge. Default: fleet-osquery.
  --metadata-path PATH     Metadata JSON path to remove. Default: /etc/brev/metadata.json.
  -h, --help               Show this help.

The script does not restore the system hostname.
EOF
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo_error "Run this script as root or with sudo."
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-data)
                PURGE_DATA=false
                shift
                ;;
            --purge-benchmark-cache)
                PURGE_BENCHMARK_CACHE=true
                shift
                ;;
            --refresh-apt)
                REFRESH_APT=true
                shift
                ;;
            --fleet-package)
                if [[ $# -lt 2 ]]; then
                    echo_error "--fleet-package requires a package name."
                    exit 1
                fi
                FLEET_PACKAGE_NAME="$2"
                shift 2
                ;;
            --metadata-path)
                if [[ $# -lt 2 ]]; then
                    echo_error "--metadata-path requires a path."
                    exit 1
                fi
                METADATA_PATH="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

wait_for_apt_lock() {
    local elapsed=0
    local interval=5
    local lock_wait_time=360
    local locks=(
        /var/lib/dpkg/lock
        /var/lib/dpkg/lock-frontend
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    echo_info "Waiting for apt/dpkg locks to be released..."
    while true; do
        local busy=false
        local lock_file

        for lock_file in "${locks[@]}"; do
            if [[ -e "$lock_file" ]] && fuser "$lock_file" >/dev/null 2>&1; then
                busy=true
                break
            fi
        done

        if [[ "$busy" == false ]]; then
            echo_info "Apt locks are free."
            return
        fi

        if (( elapsed >= lock_wait_time )); then
            echo_error "Timeout waiting for apt/dpkg locks to be released."
            exit 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

stop_disable_service() {
    local service="$1"

    if systemctl list-unit-files "$service" >/dev/null 2>&1 || systemctl status "$service" >/dev/null 2>&1; then
        echo_info "Stopping and disabling ${service}..."
        systemctl disable --now "$service" >/dev/null 2>&1 || true
    fi
}

package_present() {
    dpkg-query -W "$1" >/dev/null 2>&1
}

cleanup_temp_units() {
    if [[ "$TEMP_INFLUXDB_UNIT_CREATED" == true ]]; then
        rm -f "$TEMP_INFLUXDB_UNIT_PATH"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

ensure_influxdb_unit_for_package_removal() {
    if ! package_present influxdb2; then
        return
    fi

    echo_info "Creating temporary influxdb.service so the influxdb2 package removal script can complete..."
    cat > "$TEMP_INFLUXDB_UNIT_PATH" <<'EOF'
[Unit]
Description=Temporary InfluxDB service stub for package removal

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$TEMP_INFLUXDB_UNIT_PATH"
    systemctl daemon-reload
    TEMP_INFLUXDB_UNIT_CREATED=true
}

purge_packages() {
    local packages=("$@")
    local installed=()
    local package

    for package in "${packages[@]}"; do
        if package_present "$package"; then
            installed+=("$package")
        fi
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        echo_info "No benchmark packages are currently installed."
        return
    fi

    echo_info "Purging packages: ${installed[*]}"
    wait_for_apt_lock
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}"
    wait_for_apt_lock
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
}

remove_paths() {
    local path

    for path in "$@"; do
        if [[ -e "$path" || -L "$path" ]]; then
            echo_info "Removing ${path}"
            rm -rf "$path"
        fi
    done
}

remove_repo_state() {
    echo_info "Removing metrics apt repository state..."
    remove_paths \
        /etc/apt/sources.list.d/influxdata.list \
        /etc/apt/sources.list.d/influxdb.list \
        /etc/apt/sources.list.d/grafana.list \
        /etc/apt/keyrings/influxdata-apt-keyring.asc \
        /etc/apt/keyrings/influxdata.gpg \
        /etc/apt/keyrings/grafana.asc \
        /etc/apt/keyrings/grafana.key \
        /usr/share/keyrings/grafana.key \
        /usr/share/keyrings/grafana.asc \
        /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg
}

remove_config_and_data() {
    echo_info "Removing generated metrics configuration..."
    remove_paths \
        /etc/default/telegraf \
        /etc/telegraf \
        /etc/grafana \
        /etc/influxdb \
        /etc/influxdb2 \
        "/opt/${FLEET_PKG_AMD64}"

    if [[ "$PURGE_DATA" == true ]]; then
        echo_info "Removing generated metrics data and metadata..."
        remove_paths \
            /var/lib/grafana \
            /var/log/grafana \
            /var/lib/influxdb \
            /var/lib/influxdb2 \
            /var/log/influxdb \
            /var/log/influxdb2 \
            /var/log/telegraf \
            /root/.influxdbv2 \
            /home/ubuntu/.influxdbv2 \
            "$METADATA_PATH" \
            "${METADATA_PATH}.bak" \
            "${METADATA_PATH}.invalid"
    else
        echo_info "Keeping metrics data and metadata."
    fi
}

remove_benchmark_cache() {
    if [[ "$PURGE_BENCHMARK_CACHE" == false ]]; then
        return
    fi

    echo_info "Removing benchmark cache from the Ansible bootstrap path..."
    remove_paths /tmp/ansible_env /tmp/mc /var/log/ansible
}

refresh_apt() {
    if [[ "$REFRESH_APT" == true ]] && command -v apt-get >/dev/null 2>&1; then
        echo_info "Refreshing apt package lists..."
        wait_for_apt_lock
        NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get update || echo_warn "apt-get update failed after repository cleanup."
    fi
}

main() {
    trap cleanup_temp_units EXIT

    parse_args "$@"
    require_root

    if ! command -v apt-get >/dev/null 2>&1; then
        echo_error "This reset script currently supports apt-based Debian/Ubuntu instances."
        exit 1
    fi

    stop_disable_service telegraf
    stop_disable_service grafana-server
    stop_disable_service influxdb

    ensure_influxdb_unit_for_package_removal
    purge_packages grafana telegraf influxdb2 influxdb2-cli "$FLEET_PACKAGE_NAME" fleet
    remove_repo_state
    remove_config_and_data
    remove_benchmark_cache
    refresh_apt

    echo_info "Reset completed. Hostname was not changed."
}

main "$@"
