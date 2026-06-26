#!/usr/bin/env bash

if [[ ${-} == *x* ]]; then
    echo "[ERROR] Do not run this script with shell tracing enabled; it can expose credentials." >&2
    exit 1
fi

set -Eeuo pipefail
set +x

export HISTFILE=/dev/null

readonly DEFAULT_ASSET_BASE_URL="https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main"
readonly DEFAULT_FLEET_AMD64_URL="https://github.com/Shiftius/ansible-gpu-metrics-collector/releases/download/pkg-1.0.0/f2a389a0c40047587c32daafd34d407bc130075f8d29decf2c0aad5f60464043"
readonly DEFAULT_FLEET_PKG_AMD64="fleet-1.0.0_amd64.deb"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd || true)"
ASSET_BASE_URL="${ASSET_BASE_URL:-$DEFAULT_ASSET_BASE_URL}"
ASSET_DIR="${ASSET_DIR:-}"
AWS_REGION_VALUE="${AWS_REGION:-${aws_region:-us-west-2}}"
AWS_TIMESTREAM_ACCESS_KEY_VALUE="${AWS_TIMESTREAM_ACCESS_KEY:-${aws_timestream_access_key:-empty-access-key}}"
AWS_TIMESTREAM_SECRET_KEY_VALUE="${AWS_TIMESTREAM_SECRET_KEY:-${aws_timestream_secret_key:-empty-secret-key}}"
AWS_TIMESTREAM_DATABASE_VALUE="${AWS_TIMESTREAM_DATABASE:-${aws_timestream_database:-empty-database}}"
DOMAIN_VALUE="${DOMAIN:-${domain:-domain.com}}"
ENVIRONMENT_ID_VALUE="${ENVIRONMENT_ID:-${environmentID:-}}"
FLEET_AMD64_URL="${FLEET_AMD64_URL:-${fleet_amd64_url:-$DEFAULT_FLEET_AMD64_URL}}"
FLEET_PKG_AMD64="${FLEET_PKG_AMD64:-${fleet_pkg_amd64:-$DEFAULT_FLEET_PKG_AMD64}}"
GRAFANA_SUBPATH="${GRAFANA_SUBPATH:-metrics}"
HOST_PREFIX="${HOST_PREFIX:-brev}"
INFLUX_BUCKET="${INFLUX_BUCKET:-lp}"
INFLUX_ORG="${INFLUX_ORG:-lp}"
INFLUX_PASSWORD="${INFLUX_PASSWORD:-LocaFluxCapacity2024}"
INFLUX_USERNAME="${INFLUX_USERNAME:-lp}"
METADATA_PATH="${METADATA_PATH:-/etc/brev/metadata.json}"
METADATA_BACKUP="${METADATA_BACKUP:-${metadata_backup:-yes}}"
SKIP_HOSTNAME_CONF=false
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

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo_error "Run this script as root or with sudo."
        return 1
    fi
}

exit_with_status() {
    local status="$1"

    if [[ "$status" -ne 0 && "$TOLERATE_FAILURES" == true ]]; then
        echo_warn "setup-raw.sh failed with exit code ${status}; failure tolerance enabled, exiting 0."
        exit 0
    fi

    exit "$status"
}

parse_tolerance_flag() {
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
            return 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

apt_install() {
    wait_for_apt_lock
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

apt_update() {
    wait_for_apt_lock
    NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

apt_install_missing() {
    local missing=()
    local package

    for package in "$@"; do
        if ! apt_package_installed "$package"; then
            missing+=("$package")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo_info "Base packages already installed."
        return
    fi

    apt_update
    apt_install "${missing[@]}"
}

download_file() {
    local url="$1"
    local dest="$2"
    local mode="${3:-0644}"
    local dest_dir

    dest_dir="$(dirname "$dest")"
    if [[ ! -d "$dest_dir" ]]; then
        install -d -m 0755 "$dest_dir"
    fi
    curl -fsSL "$url" -o "$dest"
    chmod "$mode" "$dest"
}

copy_or_download_asset() {
    local relative_path="$1"
    local dest="$2"
    local mode="${3:-0644}"
    local asset_root
    local local_path

    for asset_root in "$ASSET_DIR" "$SCRIPT_DIR"; do
        [[ -n "$asset_root" ]] || continue
        local_path="${asset_root}/${relative_path}"
        if [[ -f "$local_path" ]]; then
            install -d -m 0755 "$(dirname "$dest")"
            install -m "$mode" "$local_path" "$dest"
            return
        fi
    done

    download_file "${ASSET_BASE_URL}/${relative_path}" "$dest" "$mode"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&@\\]/\\&/g'
}

run_capture() {
    sh -c "$1" 2>/dev/null || true
}

first_line() {
    run_capture "$1" | head -n 1 | tr -d '\n'
}

int_value() {
    local value="${1:-0}"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

is_truthy() {
    case "${1:-}" in
        true|TRUE|True|yes|YES|Yes|y|Y|1)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

sysfs_first() {
    local default="$1"
    shift
    local path value

    for path in "$@"; do
        if [[ -r "$path" ]]; then
            value="$(tr -d '\n' < "$path")"
            if [[ -n "$value" ]]; then
                printf '%s' "$value"
                return
            fi
        fi
    done

    printf '%s' "$default"
}

nvidia_query() {
    local field="$1"
    local first_only="${2:-false}"
    local output

    output="$(run_capture "nvidia-smi --query-gpu=${field} --format=csv,noheader")"
    if [[ -z "$output" ]]; then
        return
    fi

    if [[ "$first_only" == true ]]; then
        printf '%s' "$output" | awk 'NF {print; exit}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    else
        printf '%s' "$output" | awk 'NF {gsub(/^[[:space:]]+|[[:space:]]+$/, ""); printf "%s%s", sep, $0; sep=","}'
    fi
}

parse_args() {
    local arg value

    for arg in "$@"; do
        case "$arg" in
            --skip-hostname-conf)
                SKIP_HOSTNAME_CONF=true
                ;;
            --tolerate-failures)
                TOLERATE_FAILURES=true
                ;;
            --strict-failures)
                TOLERATE_FAILURES=false
                ;;
            skip_hostname_conf=*)
                value="${arg#*=}"
                case "$value" in
                    true|TRUE|True|yes|YES|Yes|1)
                        SKIP_HOSTNAME_CONF=true
                        ;;
                    *)
                        SKIP_HOSTNAME_CONF=false
                        ;;
                esac
                ;;
            asset_base_url=*|ASSET_BASE_URL=*)
                value="${arg#*=}"
                ASSET_BASE_URL="$value"
                ;;
            aws_region=*|AWS_REGION=*)
                value="${arg#*=}"
                AWS_REGION_VALUE="$value"
                ;;
            aws_timestream_access_key=*|AWS_TIMESTREAM_ACCESS_KEY=*)
                value="${arg#*=}"
                AWS_TIMESTREAM_ACCESS_KEY_VALUE="$value"
                ;;
            aws_timestream_secret_key=*|AWS_TIMESTREAM_SECRET_KEY=*)
                value="${arg#*=}"
                AWS_TIMESTREAM_SECRET_KEY_VALUE="$value"
                ;;
            aws_timestream_database=*|AWS_TIMESTREAM_DATABASE=*)
                value="${arg#*=}"
                AWS_TIMESTREAM_DATABASE_VALUE="$value"
                ;;
            environmentID=*|ENVIRONMENT_ID=*)
                value="${arg#*=}"
                ENVIRONMENT_ID_VALUE="$value"
                ;;
            domain=*|DOMAIN=*)
                value="${arg#*=}"
                DOMAIN_VALUE="$value"
                ;;
            grafana.subpath=*|grafana_subpath=*|GRAFANA_SUBPATH=*)
                value="${arg#*=}"
                GRAFANA_SUBPATH="$value"
                ;;
            host_prefix=*|HOST_PREFIX=*)
                value="${arg#*=}"
                HOST_PREFIX="$value"
                ;;
            influx.bucket=*|influx_bucket=*|INFLUX_BUCKET=*)
                value="${arg#*=}"
                INFLUX_BUCKET="$value"
                ;;
            influx.org=*|influx_org=*|INFLUX_ORG=*)
                value="${arg#*=}"
                INFLUX_ORG="$value"
                ;;
            influx.password=*|influx_password=*|INFLUX_PASSWORD=*)
                value="${arg#*=}"
                INFLUX_PASSWORD="$value"
                ;;
            influx.username=*|influx_username=*|INFLUX_USERNAME=*)
                value="${arg#*=}"
                INFLUX_USERNAME="$value"
                ;;
            metadata_path=*|METADATA_PATH=*)
                value="${arg#*=}"
                METADATA_PATH="$value"
                ;;
            metadata_backup=*|METADATA_BACKUP=*)
                value="${arg#*=}"
                METADATA_BACKUP="$value"
                ;;
            fleet_amd64_url=*|FLEET_AMD64_URL=*)
                value="${arg#*=}"
                FLEET_AMD64_URL="$value"
                ;;
            fleet_pkg_amd64=*|FLEET_PKG_AMD64=*)
                value="${arg#*=}"
                FLEET_PKG_AMD64="$value"
                ;;
            *)
                echo_warn "Ignoring unsupported argument: ${arg%%=*}"
                ;;
        esac
    done

    unset arg value
    set --
}

detect_hostid() {
    if [[ -n "$ENVIRONMENT_ID_VALUE" ]]; then
        printf '%s' "$ENVIRONMENT_ID_VALUE"
        return
    fi

    hostname -f 2>/dev/null || hostname
}

set_instance_hostname() {
    local hostid="$1"
    local desired_hostname="${HOST_PREFIX}-${hostid}"

    if [[ "$SKIP_HOSTNAME_CONF" == true ]]; then
        echo_info "Leaving hostname unchanged because --skip-hostname-conf was provided."
        return
    fi

    echo_info "Setting hostname to ${desired_hostname}..."
    hostnamectl set-hostname "$desired_hostname"
}

install_base_packages() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo_error "This raw installer currently supports apt-based Debian/Ubuntu instances."
        return 1
    fi

    echo_info "Installing base packages..."
    apt_install_missing ca-certificates curl dmidecode gnupg jq lshw pciutils wget
}

configure_repositories() {
    echo_info "Configuring InfluxData and Grafana apt repositories..."

    rm -f \
        /etc/apt/sources.list.d/influxdata.list \
        /etc/apt/sources.list.d/influxdb.list \
        /etc/apt/keyrings/influxdata-apt-keyring.asc \
        /etc/apt/keyrings/influxdata.gpg \
        /etc/apt/sources.list.d/grafana.list \
        /etc/apt/keyrings/grafana.asc \
        /etc/apt/keyrings/grafana.key \
        /usr/share/keyrings/grafana.key \
        /usr/share/keyrings/grafana.asc

    install -d -m 0755 /etc/apt/trusted.gpg.d /usr/share/keyrings
    curl -fsSL https://repos.influxdata.com/influxdata-archive.key \
        | gpg --dearmor > /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg
    chmod 0644 /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg

    printf '%s\n' \
        "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian stable main" \
        > /etc/apt/sources.list.d/influxdata.list

    curl -fsSL https://apt.grafana.com/gpg.key -o /usr/share/keyrings/grafana.key
    chmod 0644 /usr/share/keyrings/grafana.key
    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list

    apt_update
}

install_metrics_packages() {
    local pkg_path="/opt/${FLEET_PKG_AMD64}"

    echo_info "Installing metrics packages..."
    download_file "$FLEET_AMD64_URL" "$pkg_path" 0644
    if ! apt_install grafana influxdb2 influxdb2-cli telegraf "$pkg_path"; then
        echo_warn "Combined metrics and fleet package install failed; retrying metrics packages without fleet."
        apt_install grafana influxdb2 influxdb2-cli telegraf
    fi
}

systemctl_enable_restart() {
    local unit="$1"
    systemctl enable "$unit"
    systemctl restart "$unit"
}

wait_for_influxdb() {
    local elapsed=0
    local interval=2
    local timeout=90

    echo_info "Waiting for InfluxDB to become available..."
    until influx ping >/dev/null 2>&1; do
        if (( elapsed >= timeout )); then
            echo_error "InfluxDB did not become available within ${timeout}s."
            return 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

configure_influxdb() {
    local bucket_id auth_id

    echo_info "Starting InfluxDB..."
    systemctl enable influxdb
    systemctl start influxdb
    wait_for_influxdb

    bucket_id="$(influx bucket list 2>/dev/null | awk -v bucket="$INFLUX_BUCKET" '$0 ~ bucket {print $1; exit}' || true)"
    if [[ -z "$bucket_id" ]]; then
        echo_info "Creating InfluxDB organization, bucket, and admin token..."
        influx setup \
            --name default \
            --username "$INFLUX_USERNAME" \
            --password "$INFLUX_PASSWORD" \
            --org "$INFLUX_ORG" \
            --bucket "$INFLUX_BUCKET" \
            --retention 30d \
            --token "$INFLUX_PASSWORD" \
            --force >/dev/null
        bucket_id="$(influx bucket list 2>/dev/null | awk -v bucket="$INFLUX_BUCKET" '$0 ~ bucket {print $1; exit}' || true)"
    fi

    auth_id="$(influx v1 auth list 2>/dev/null | awk -v bucket="$INFLUX_BUCKET" '$0 ~ bucket {print $1; exit}' || true)"
    if [[ -n "$bucket_id" && -z "$auth_id" ]]; then
        echo_info "Creating InfluxDB v1 compatibility auth..."
        influx v1 auth create \
            --username "$INFLUX_USERNAME" \
            --password "$INFLUX_PASSWORD" \
            --org "$INFLUX_ORG" \
            --read-bucket "$bucket_id" >/dev/null
    else
        echo_info "InfluxDB bucket/auth already exists."
    fi
}

configure_telegraf() {
    echo_info "Writing Telegraf configuration..."

    install -d -m 0750 -o telegraf -g telegraf /etc/telegraf
    install -d -m 0755 /var/log/telegraf

    cat > /etc/default/telegraf <<EOF
LP_STACK_NAME="${HOSTID}"
AWS_REGION="${AWS_REGION_VALUE}"
AWS_ACCESS_KEY="${AWS_TIMESTREAM_ACCESS_KEY_VALUE}"
AWS_SECRET_KEY="${AWS_TIMESTREAM_SECRET_KEY_VALUE}"
AWS_TIMESTREAM_DB="${AWS_TIMESTREAM_DATABASE_VALUE}"
EOF
    chown telegraf:telegraf /etc/default/telegraf
    chmod 0640 /etc/default/telegraf

    cat > /etc/telegraf/telegraf.conf <<EOF
## Configure Telegraf Global Tags
[global_tags]

## Configure Telegraf Agent
[agent]
  interval = "30s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "15s"
  flush_jitter = "0s"
  precision = ""
  hostname = "\${LP_STACK_NAME}"
  omit_hostname = false
  logfile = "/var/log/telegraf/telegraf.log"

## Configure Telegraf Inputs

[[inputs.cpu]]
  percpu = false
[[inputs.disk]]
 ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs", "shm"]
[[inputs.diskio]]
 devices = ["sd*", "vd*", "nv*"]
[[inputs.net]]
[[inputs.mem]]
[[inputs.system]]
[[inputs.nvidia_smi]]
[[inputs.procstat]]
  pattern = "cloudflared"

## Configure Telegraf Outputs
[[outputs.timestream]]
  region = "\${AWS_REGION}"
  access_key = "\${AWS_ACCESS_KEY}"
  secret_key = "\${AWS_SECRET_KEY}"
  database_name = "\${AWS_TIMESTREAM_DB}"
  describe_database_on_start = false
  mapping_mode = "multi-table"
  create_table_if_not_exists = true
  create_table_magnetic_store_retention_period_in_days = 365
  create_table_memory_store_retention_period_in_hours = 24


[[outputs.influxdb_v2]]
  urls = ["http://127.0.0.1:8086"]
  token = "${INFLUX_PASSWORD}"
  organization = "${INFLUX_ORG}"
  bucket = "${INFLUX_BUCKET}"
EOF

    chown -R telegraf:telegraf /etc/telegraf
    chmod 0750 /etc/telegraf
    chmod 0640 /etc/telegraf/telegraf.conf
    usermod -a -G adm telegraf
    systemctl_enable_restart telegraf
}

render_grafana_ini() {
    local template_file="$1"
    local output_file="$2"
    local hostid domain subpath

    hostid="$(escape_sed_replacement "$HOSTID")"
    domain="$(escape_sed_replacement "$DOMAIN_VALUE")"
    subpath="$(escape_sed_replacement "$GRAFANA_SUBPATH")"

    sed \
        -e "s@{{ hostid }}@${hostid}@g" \
        -e "s@{{ domain }}@${domain}@g" \
        -e "s@{{ grafana.subpath }}@${subpath}@g" \
        "$template_file" > "$output_file"
}

configure_grafana() {
    local grafana_template

    echo_info "Writing Grafana configuration..."

    install -d -m 0755 /etc/grafana/provisioning/datasources
    install -d -m 0755 /etc/grafana/provisioning/dashboards
    install -d -m 0755 /var/lib/grafana/dashboards

    grafana_template="$(mktemp)"
    copy_or_download_asset "roles/telegraf_config/templates/grafana/grafana.ini" "$grafana_template" 0644
    render_grafana_ini "$grafana_template" /etc/grafana/grafana.ini
    rm -f "$grafana_template"

    cat > /etc/grafana/provisioning/datasources/graf_ds.yaml <<EOF
# config file version
# Updated per https://grafana.com/docs/grafana/latest/datasources/influxdb/#provision-the-data-source
apiVersion: 1

deleteDatasources:
  - name: Influxdb
    orgId: 1

datasources:
  - name: Influxdb
    type: influxdb
    access: proxy
    user: ${INFLUX_USERNAME}
    url: http://localhost:8086
    jsonData:
      dbName: ${INFLUX_BUCKET}
      httpMode: GET
    secureJsonData:
      password: ${INFLUX_PASSWORD}
EOF

    cat > /etc/grafana/provisioning/dashboards/graf_dash.yaml <<'EOF'
apiVersion: 1

providers:
- name: 'LaunchPad Metrics'
  orgId: 1
  folder: ''
  folderUid: ''
  type: file
  disableDeletion: false
  editable: true
  updateIntervalSeconds: 30
  options:
    path: /var/lib/grafana/dashboards
EOF

    copy_or_download_asset "roles/telegraf_config/templates/grafana/dashboard.json" /var/lib/grafana/dashboards/metrics.json 0644
    chown -R grafana:grafana /var/lib/grafana/dashboards
    systemctl_enable_restart grafana-server
}

network_interfaces_json() {
    local interfaces='[]'
    local path

    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        interfaces="$(jq -c --arg iface "$(basename "$path")" '. + [$iface]' <<< "$interfaces")"
    done

    jq -c 'sort' <<< "$interfaces"
}

storage_devices_json() {
    local devices='{}'
    local model name path rotational sectors

    for path in /sys/block/*; do
        [[ -e "$path" ]] || continue
        name="$(basename "$path")"
        case "$name" in
            loop*|ram*)
                continue
                ;;
        esac

        sectors="$(int_value "$(sysfs_first 0 "${path}/size")")"
        model="$(sysfs_first "" "${path}/device/model")"
        rotational="$(sysfs_first "" "${path}/queue/rotational")"
        devices="$(jq -c \
            --arg name "$name" \
            --arg model "$model" \
            --arg rotational "$rotational" \
            --argjson sectors "$sectors" \
            '. + {($name): {
                model: $model,
                sectors: $sectors,
                size_bytes: ($sectors * 512),
                rotational: $rotational
            }}' <<< "$devices")"
    done

    printf '%s\n' "$devices"
}

collect_hardware_metadata() {
    local amd_gpu_count architecture bios_date bios_version cpu_model cuda_runtime_version cuda_toolkit_version
    local existing_metadata fqdn gpu_count_lspci hardware_metadata intel_gpu_count mem_free_mb mem_total_mb
    local metadata_dir metadata_tmp nvidia_compute_mode nvidia_driver_version nvidia_gpu_compute_cap
    local nvidia_gpu_count nvidia_gpu_memory nvidia_gpu_names nvidia_gpu_pci_bus_ids nvidia_gpu_serials
    local nvidia_gpu_uuids nvidia_persistence_mode processor_cores processor_count processor_threads_per_core
    local processor_vcpus product_name product_serial product_uuid product_version storage_devices
    local swap_free_mb swap_total_mb system_model system_vendor total_gpu_count

    echo_info "Collecting hardware metadata..."

    cpu_model="$(first_line "awk -F': ' '/model name/ {print \$2; exit}' /proc/cpuinfo")"
    [[ -n "$cpu_model" ]] || cpu_model="Unknown"
    architecture="$(uname -m 2>/dev/null || echo unknown)"
    processor_count="$(int_value "$(first_line "awk -F': ' '/physical id/ {ids[\$2]=1} END {print length(ids)}' /proc/cpuinfo")")"
    [[ "$processor_count" -gt 0 ]] || processor_count=1
    processor_cores="$(int_value "$(first_line "awk -F': ' '/cpu cores/ {print \$2; exit}' /proc/cpuinfo")")"
    processor_vcpus="$(int_value "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)")"
    if [[ "$processor_cores" -gt 0 && "$processor_vcpus" -gt 0 ]]; then
        processor_threads_per_core=$((processor_vcpus / processor_cores))
    else
        processor_threads_per_core=0
    fi

    mem_total_mb=$(( $(int_value "$(first_line "awk '/^MemTotal:/ {print \$2; exit}' /proc/meminfo")") / 1024 ))
    mem_free_mb=$(( $(int_value "$(first_line "awk '/^MemFree:/ {print \$2; exit}' /proc/meminfo")") / 1024 ))
    swap_total_mb=$(( $(int_value "$(first_line "awk '/^SwapTotal:/ {print \$2; exit}' /proc/meminfo")") / 1024 ))
    swap_free_mb=$(( $(int_value "$(first_line "awk '/^SwapFree:/ {print \$2; exit}' /proc/meminfo")") / 1024 ))

    system_vendor="$(sysfs_first "unknown" /sys/class/dmi/id/sys_vendor)"
    system_model="$(sysfs_first "unknown" /sys/class/dmi/id/product_name)"
    product_name="$system_model"
    product_version="$(sysfs_first "unknown" /sys/class/dmi/id/product_version)"
    product_serial="$(sysfs_first "unknown" /sys/class/dmi/id/product_serial)"
    product_uuid="$(sysfs_first "unknown" /sys/class/dmi/id/product_uuid)"
    bios_version="$(sysfs_first "unknown" /sys/class/dmi/id/bios_version)"
    bios_date="$(sysfs_first "unknown" /sys/class/dmi/id/bios_date)"
    fqdn="$(hostname -f 2>/dev/null || hostname)"

    gpu_count_lspci="$(int_value "$(run_capture "lspci 2>/dev/null | grep -icE 'VGA|3D controller.*NVIDIA|Display.*NVIDIA'")")"
    nvidia_gpu_count="$(int_value "$(nvidia_query count true)")"
    amd_gpu_count="$(int_value "$(run_capture "lspci 2>/dev/null | grep -icE 'VGA.*AMD|3D.*AMD|Display.*AMD'")")"
    intel_gpu_count="$(int_value "$(run_capture "lspci 2>/dev/null | grep -icE 'VGA.*Intel|Display.*Intel.*Graphics'")")"
    if [[ "$nvidia_gpu_count" -gt 0 ]]; then
        total_gpu_count=$((nvidia_gpu_count + amd_gpu_count + intel_gpu_count))
    else
        total_gpu_count=$((gpu_count_lspci + amd_gpu_count + intel_gpu_count))
    fi

    nvidia_driver_version="$(nvidia_query driver_version true)"
    nvidia_gpu_names="$(nvidia_query name)"
    nvidia_gpu_serials="$(nvidia_query serial)"
    nvidia_gpu_uuids="$(nvidia_query uuid)"
    nvidia_gpu_memory="$(nvidia_query memory.total)"
    nvidia_gpu_compute_cap="$(nvidia_query compute_cap)"
    nvidia_gpu_pci_bus_ids="$(nvidia_query pci.bus_id)"
    nvidia_persistence_mode="$(nvidia_query persistence_mode true)"
    nvidia_compute_mode="$(nvidia_query compute_mode true)"
    cuda_toolkit_version="$(first_line "nvcc --version 2>/dev/null | grep 'release' | sed 's/.*release \([0-9.]*\).*/\1/'")"
    cuda_runtime_version="$(first_line "ldconfig -p 2>/dev/null | grep -oP 'libcudart\.so\.\K[0-9.]+'")"

    storage_devices="$(storage_devices_json)"

    hardware_metadata="$(jq -n \
        --arg cpu_model "$cpu_model" \
        --arg architecture "$architecture" \
        --argjson processor_count "$processor_count" \
        --argjson processor_cores "$processor_cores" \
        --argjson processor_threads_per_core "$processor_threads_per_core" \
        --argjson processor_vcpus "$processor_vcpus" \
        --argjson mem_total_mb "$mem_total_mb" \
        --argjson mem_free_mb "$mem_free_mb" \
        --argjson swap_total_mb "$swap_total_mb" \
        --argjson swap_free_mb "$swap_free_mb" \
        --argjson total_gpu_count "$total_gpu_count" \
        --arg nvidia_gpu_count "$nvidia_gpu_count" \
        --arg nvidia_driver_version "$nvidia_driver_version" \
        --arg cuda_toolkit_version "$cuda_toolkit_version" \
        --arg cuda_runtime_version "$cuda_runtime_version" \
        --arg nvidia_gpu_names "$nvidia_gpu_names" \
        --arg nvidia_gpu_serials "$nvidia_gpu_serials" \
        --arg nvidia_gpu_uuids "$nvidia_gpu_uuids" \
        --arg nvidia_gpu_memory "$nvidia_gpu_memory" \
        --arg nvidia_gpu_compute_cap "$nvidia_gpu_compute_cap" \
        --arg nvidia_gpu_pci_bus_ids "$nvidia_gpu_pci_bus_ids" \
        --arg nvidia_persistence_mode "$nvidia_persistence_mode" \
        --arg nvidia_compute_mode "$nvidia_compute_mode" \
        --arg amd_gpu_count "$amd_gpu_count" \
        --arg intel_gpu_count "$intel_gpu_count" \
        --arg system_vendor "$system_vendor" \
        --arg system_model "$system_model" \
        --arg product_name "$product_name" \
        --arg product_version "$product_version" \
        --arg product_serial "$product_serial" \
        --arg product_uuid "$product_uuid" \
        --arg bios_version "$bios_version" \
        --arg bios_date "$bios_date" \
        --arg fqdn "$fqdn" \
        --argjson interfaces "$(network_interfaces_json)" \
        --argjson storage_devices "$storage_devices" \
        '{
            hardware_summary: {
                cpu_model: $cpu_model,
                total_cpus: $processor_count,
                total_cores: $processor_cores,
                total_vcpus: $processor_vcpus,
                total_memory_mb: $mem_total_mb,
                total_gpus: $total_gpu_count,
                gpu_models: $nvidia_gpu_names,
                nvidia_driver_version: $nvidia_driver_version,
                cuda_toolkit_version: $cuda_toolkit_version,
                cuda_runtime_version: $cuda_runtime_version,
                gpu_memory_total_mb: $nvidia_gpu_memory,
                gpu_compute_capabilities: $nvidia_gpu_compute_cap,
                system_vendor: $system_vendor,
                system_model: $system_model
            },
            hardware: {
                cpu: {
                    architecture: $architecture,
                    processor_count: $processor_count,
                    processor_cores: $processor_cores,
                    processor_threads_per_core: $processor_threads_per_core,
                    processor_vcpus: $processor_vcpus,
                    model_name: $cpu_model
                },
                memory: {
                    total_mb: $mem_total_mb,
                    free_mb: $mem_free_mb,
                    swap_total_mb: $swap_total_mb,
                    swap_free_mb: $swap_free_mb
                },
                motherboard: {
                    manufacturer: $system_vendor,
                    product_name: $product_name,
                    product_version: $product_version
                },
                bios: {
                    vendor: $bios_version,
                    version: $bios_version,
                    date: $bios_date
                },
                system: {
                    vendor: $system_vendor,
                    product_name: $product_name,
                    serial_number: $product_serial,
                    uuid: $product_uuid,
                    fqdn: $fqdn
                },
                gpu: {
                    total_count: $total_gpu_count,
                    nvidia: {
                        count: $nvidia_gpu_count,
                        driver_version: $nvidia_driver_version,
                        cuda_toolkit_version: $cuda_toolkit_version,
                        cuda_runtime_version: $cuda_runtime_version,
                        gpu_models: $nvidia_gpu_names,
                        serial_numbers: $nvidia_gpu_serials,
                        uuids: $nvidia_gpu_uuids,
                        memory_total_mb: $nvidia_gpu_memory,
                        compute_capabilities: $nvidia_gpu_compute_cap,
                        pci_bus_ids: $nvidia_gpu_pci_bus_ids,
                        persistence_mode: $nvidia_persistence_mode,
                        compute_mode: $nvidia_compute_mode
                    },
                    amd: {count: $amd_gpu_count},
                    intel: {count: $intel_gpu_count}
                },
                network: {interfaces: $interfaces},
                storage: {devices: $storage_devices}
            }
        }')"

    metadata_dir="$(dirname "$METADATA_PATH")"
    install -d -m 0755 "$metadata_dir"

    existing_metadata="{}"
    if [[ -f "$METADATA_PATH" ]]; then
        if jq -e . "$METADATA_PATH" >/dev/null 2>&1; then
            if is_truthy "$METADATA_BACKUP"; then
                cp "$METADATA_PATH" "${METADATA_PATH}.bak"
            fi
            existing_metadata="$(cat "$METADATA_PATH")"
        else
            cp "$METADATA_PATH" "${METADATA_PATH}.invalid"
        fi
    fi

    metadata_tmp="$(mktemp)"
    jq -S -s '.[0] * .[1]' \
        <(printf '%s\n' "$existing_metadata") \
        <(printf '%s\n' "$hardware_metadata") > "$metadata_tmp"
    install -m 0644 "$metadata_tmp" "$METADATA_PATH"
    rm -f "$metadata_tmp"
}

main() {
    parse_args "$@"
    require_root
    readonly HOSTID="$(detect_hostid)"
    export HOSTID DOMAIN_VALUE GRAFANA_SUBPATH

    echo_info "Using host id: ${HOSTID}"

    install_base_packages
    set_instance_hostname "$HOSTID"
    collect_hardware_metadata || echo_warn "Hardware metadata collection failed; continuing."
    configure_repositories
    install_metrics_packages
    configure_influxdb
    configure_telegraf
    configure_grafana

    echo_info "Raw metrics collector setup completed successfully."
}

parse_tolerance_flag "$@"
run_main "$@"
