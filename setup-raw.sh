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

ASSET_BASE_URL="${ASSET_BASE_URL:-$DEFAULT_ASSET_BASE_URL}"
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
SKIP_HOSTNAME_CONF=false

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
        exit 1
    fi
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
            exit 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
}

apt_install() {
    wait_for_apt_lock
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

apt_update() {
    wait_for_apt_lock
    DEBIAN_FRONTEND=noninteractive apt-get update
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

parse_args() {
    local arg value

    for arg in "$@"; do
        case "$arg" in
            --skip-hostname-conf)
                SKIP_HOSTNAME_CONF=true
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
        exit 1
    fi

    echo_info "Installing base packages..."
    apt_update
    apt_install ca-certificates curl dmidecode gnupg jq lshw pciutils python3 wget
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
    echo_info "Installing metrics packages..."
    apt_install grafana influxdb2 influxdb2-cli telegraf wget
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
            exit 1
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

    python3 - "$template_file" "$output_file" <<'PY'
import os
import sys

template_path, output_path = sys.argv[1], sys.argv[2]
with open(template_path, "r", encoding="utf-8") as handle:
    content = handle.read()

replacements = {
    "{{ hostid }}": os.environ["HOSTID"],
    "{{ domain }}": os.environ["DOMAIN_VALUE"],
    "{{ grafana.subpath }}": os.environ["GRAFANA_SUBPATH"],
}
for old, new in replacements.items():
    content = content.replace(old, new)

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(content)
PY
}

configure_grafana() {
    local grafana_template

    echo_info "Writing Grafana configuration..."

    install -d -m 0755 /etc/grafana/provisioning/datasources
    install -d -m 0755 /etc/grafana/provisioning/dashboards
    install -d -m 0755 /var/lib/grafana/dashboards

    grafana_template="$(mktemp)"
    download_file "${ASSET_BASE_URL}/roles/telegraf_config/templates/grafana/grafana.ini" "$grafana_template" 0644
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

    download_file "${ASSET_BASE_URL}/roles/telegraf_config/templates/grafana/dashboard.json" /var/lib/grafana/dashboards/metrics.json 0644
    chown -R grafana:grafana /var/lib/grafana/dashboards
    systemctl_enable_restart grafana-server
}

collect_hardware_metadata() {
    echo_info "Collecting hardware metadata..."

    METADATA_PATH="$METADATA_PATH" python3 <<'PY'
import glob
import json
import os
import platform
import shutil
import socket
import subprocess
from pathlib import Path

metadata_path = Path(os.environ.get("METADATA_PATH", "/etc/brev/metadata.json"))

def run(command):
    try:
        return subprocess.check_output(command, shell=True, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""

def run_lines(command):
    output = run(command)
    return [line.strip() for line in output.splitlines() if line.strip()]

def first_line(command):
    lines = run_lines(command)
    return lines[0] if lines else ""

def int_value(value):
    try:
        return int(str(value).strip())
    except Exception:
        return 0

def nvidia_query(field, join_lines=True):
    output = run(f"nvidia-smi --query-gpu={field} --format=csv,noheader 2>/dev/null")
    if not output:
        return ""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not join_lines:
        return lines[0] if lines else ""
    return ",".join(lines)

def cpu_model():
    model = first_line("awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo")
    return model or platform.processor() or "Unknown"

def meminfo_mb(key):
    raw = first_line(f"awk '/^{key}:/ {{print $2; exit}}' /proc/meminfo")
    return int_value(raw) // 1024

def processor_count():
    return int_value(run("grep -c '^physical id' /proc/cpuinfo")) or 1

def processor_cores():
    return int_value(first_line("awk -F': ' '/cpu cores/ {print $2; exit}' /proc/cpuinfo"))

def processor_vcpus():
    return os.cpu_count() or 0

def threads_per_core():
    cores = processor_cores()
    vcpus = processor_vcpus()
    return int(vcpus / cores) if cores and vcpus else 0

def sysfs_first(paths, default="unknown"):
    for path in paths:
        try:
            value = Path(path).read_text(encoding="utf-8", errors="ignore").strip()
            if value:
                return value
        except Exception:
            pass
    return default

def network_interfaces():
    return sorted(Path(path).name for path in glob.glob("/sys/class/net/*"))

def storage_devices():
    devices = {}
    for path in sorted(glob.glob("/sys/block/*")):
        name = Path(path).name
        if name.startswith(("loop", "ram")):
            continue
        size = int_value(sysfs_first([f"{path}/size"], "0"))
        model = sysfs_first([f"{path}/device/model"], "")
        rotational = sysfs_first([f"{path}/queue/rotational"], "")
        devices[name] = {
            "model": model,
            "sectors": size,
            "size_bytes": size * 512,
            "rotational": rotational,
        }
    return devices

lspci_gpu_count = int_value(run("lspci 2>/dev/null | grep -icE 'VGA|3D controller.*NVIDIA|Display.*NVIDIA'"))
nvidia_gpu_count = int_value(nvidia_query("count", join_lines=False))
amd_gpu_count = int_value(run("lspci 2>/dev/null | grep -icE 'VGA.*AMD|3D.*AMD|Display.*AMD'"))
intel_gpu_count = int_value(run("lspci 2>/dev/null | grep -icE 'VGA.*Intel|Display.*Intel.*Graphics'"))
total_gpu_count = (nvidia_gpu_count if nvidia_gpu_count > 0 else lspci_gpu_count) + amd_gpu_count + intel_gpu_count

cuda_toolkit_version = run("nvcc --version 2>/dev/null | grep 'release' | sed 's/.*release \\([0-9.]*\\).*/\\1/' | tr -d '\\n'")
cuda_runtime_version = run("ldconfig -p 2>/dev/null | grep -oP 'libcudart\\.so\\.\\K[0-9.]+' | head -1 | tr -d '\\n'")
nvidia_driver_version = nvidia_query("driver_version", join_lines=False)
nvidia_gpu_names = nvidia_query("name")
nvidia_gpu_memory = nvidia_query("memory.total")
nvidia_gpu_compute_cap = nvidia_query("compute_cap")

hardware_metadata = {
    "hardware_summary": {
        "cpu_model": cpu_model(),
        "total_cpus": processor_count(),
        "total_cores": processor_cores(),
        "total_vcpus": processor_vcpus(),
        "total_memory_mb": meminfo_mb("MemTotal"),
        "total_gpus": total_gpu_count,
        "gpu_models": nvidia_gpu_names,
        "nvidia_driver_version": nvidia_driver_version,
        "cuda_toolkit_version": cuda_toolkit_version,
        "cuda_runtime_version": cuda_runtime_version,
        "gpu_memory_total_mb": nvidia_gpu_memory,
        "gpu_compute_capabilities": nvidia_gpu_compute_cap,
        "system_vendor": sysfs_first(["/sys/class/dmi/id/sys_vendor"], "Unknown"),
        "system_model": sysfs_first(["/sys/class/dmi/id/product_name"], "Unknown"),
    },
    "hardware": {
        "cpu": {
            "architecture": platform.machine() or "unknown",
            "processor_count": processor_count(),
            "processor_cores": processor_cores(),
            "processor_threads_per_core": threads_per_core(),
            "processor_vcpus": processor_vcpus(),
            "model_name": cpu_model(),
        },
        "memory": {
            "total_mb": meminfo_mb("MemTotal"),
            "free_mb": meminfo_mb("MemFree"),
            "swap_total_mb": meminfo_mb("SwapTotal"),
            "swap_free_mb": meminfo_mb("SwapFree"),
        },
        "motherboard": {
            "manufacturer": sysfs_first(["/sys/class/dmi/id/board_vendor", "/sys/class/dmi/id/sys_vendor"], "unknown"),
            "product_name": sysfs_first(["/sys/class/dmi/id/board_name", "/sys/class/dmi/id/product_name"], "unknown"),
            "product_version": sysfs_first(["/sys/class/dmi/id/board_version", "/sys/class/dmi/id/product_version"], "unknown"),
        },
        "bios": {
            "vendor": sysfs_first(["/sys/class/dmi/id/bios_version"], "unknown"),
            "version": sysfs_first(["/sys/class/dmi/id/bios_version"], "unknown"),
            "date": sysfs_first(["/sys/class/dmi/id/bios_date"], "unknown"),
        },
        "system": {
            "vendor": sysfs_first(["/sys/class/dmi/id/sys_vendor"], "unknown"),
            "product_name": sysfs_first(["/sys/class/dmi/id/product_name"], "unknown"),
            "serial_number": sysfs_first(["/sys/class/dmi/id/product_serial"], "unknown"),
            "uuid": sysfs_first(["/sys/class/dmi/id/product_uuid"], "unknown"),
            "fqdn": socket.getfqdn(),
        },
        "gpu": {
            "total_count": total_gpu_count,
            "nvidia": {
                "count": str(nvidia_gpu_count),
                "driver_version": nvidia_driver_version,
                "cuda_toolkit_version": cuda_toolkit_version,
                "cuda_runtime_version": cuda_runtime_version,
                "gpu_models": nvidia_gpu_names,
                "serial_numbers": nvidia_query("serial"),
                "uuids": nvidia_query("uuid"),
                "memory_total_mb": nvidia_gpu_memory,
                "compute_capabilities": nvidia_gpu_compute_cap,
                "pci_bus_ids": nvidia_query("pci.bus_id"),
                "persistence_mode": nvidia_query("persistence_mode", join_lines=False),
                "compute_mode": nvidia_query("compute_mode", join_lines=False),
            },
            "amd": {"count": str(amd_gpu_count)},
            "intel": {"count": str(intel_gpu_count)},
        },
        "network": {"interfaces": network_interfaces()},
        "storage": {"devices": storage_devices()},
    },
}

existing = {}
if metadata_path.exists():
    try:
        existing = json.loads(metadata_path.read_text(encoding="utf-8"))
    except Exception:
        backup_path = metadata_path.with_suffix(metadata_path.suffix + ".invalid")
        shutil.copy2(metadata_path, backup_path)

def merge(a, b):
    result = dict(a)
    for key, value in b.items():
        if isinstance(result.get(key), dict) and isinstance(value, dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = value
    return result

metadata_path.parent.mkdir(parents=True, exist_ok=True)
if metadata_path.exists():
    shutil.copy2(metadata_path, str(metadata_path) + ".bak")
metadata_path.write_text(json.dumps(merge(existing, hardware_metadata), indent=4, sort_keys=True) + "\n", encoding="utf-8")
metadata_path.chmod(0o644)
PY
}

install_fleet_package() {
    local pkg_path="/opt/${FLEET_PKG_AMD64}"

    echo_info "Installing fleet package..."
    download_file "$FLEET_AMD64_URL" "$pkg_path" 0644
    wait_for_apt_lock
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg_path"; then
        echo_warn "Fleet package installation failed; continuing to match the non-failing Ansible role."
    fi
}

main() {
    require_root
    parse_args "$@"
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
    install_fleet_package

    echo_info "Raw metrics collector setup completed successfully."
}

main "$@"
