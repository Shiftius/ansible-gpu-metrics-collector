# ansible-gpu-metrics-collector

## Security Notice

New installations use independent, per-host local credentials for InfluxDB, Telegraf compatibility access, and Grafana. Timestream output and AWS credential files are not configured.

### Security Features
- **No Debug Output**: Shell scripts run with `set +x` to prevent command echoing
- **No Secret Echoing**: Local values are generated on the host without command tracing
- **Secure File Permissions**: The source-of-truth credential file is `/etc/brev/metrics-secrets.env`, owned by root with mode `0600`
- **Independent Values**: InfluxDB admin, Telegraf operator, v1 compatibility, and Grafana admin credentials are distinct
- **Legacy Ansible Path Preserved**: The playbook and roles remain available for inspection or manual use, but `setup.sh` now defaults to raw shell execution

### Best Practices
1. **Never commit secrets** to version control
2. **Prefer environment variables** over command-line arguments for secrets
3. **Limit log verbosity** in production environments
4. **Do not copy the per-host credential file** between systems

### Running Securely

#### Default: Fast Raw Shell Setup
For fresh instances where startup time matters, use `setup.sh`. It delegates to the flattened raw shell installer, leaves the Ansible playbook and roles in place, and skips Python, the Python virtualenv, and Ansible install work.
When run from a checkout, `setup.sh` also uses local Grafana assets instead of fetching them over HTTP and installs the metrics packages plus the Fleet deb in a single apt transaction. The installer detects the Debian package architecture and selects the matching AMD64 or ARM64 Fleet package.

```bash
curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
  bash -s -- environmentID='ID'
```

To keep the current hostname unchanged, append `--skip-hostname-conf` to the `bash -s -- ...` arguments.

Failure tolerance is enabled by default for parent orchestration: the scripts still log `[ERROR]` and `[WARN]`
status output, but normalize failures to exit code `0`. Use `--strict-failures` only when you want a
benchmark/debug run to exit nonzero on failure. `--tolerate-failures` is still accepted to explicitly request
the default behavior.

Use `--fleet-only` when an instance needs Fleet enrollment without the InfluxDB, Telegraf, and Grafana
metrics stack or its package repositories:

```bash
curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
  bash -s -- --fleet-only --skip-hostname-conf --strict-failures
```

In the default tolerant mode, a Fleet download or installation failure is logged and the command exits
successfully. With `--strict-failures`, the same failure returns a nonzero exit code.

The raw installer accepts the environment ID through the environment:

```bash
export ENVIRONMENT_ID="your-environment-id"

curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash
```

`setup-raw.sh` can still be invoked directly from a checkout or via curl when you do not need the compatibility wrapper.
For compatibility with the former Ansible extra-vars flow, the raw installer accepts the existing setup values
for `environmentID`, `domain`, `host_prefix`, `skip_hostname_conf`, `influx.*`,
`grafana.subpath`, `fleet_amd64_url`, `fleet_pkg_amd64`, `fleet_arm64_url`, `fleet_pkg_arm64`, `metadata_path`, and `metadata_backup`.

#### Benchmarking Raw vs. Ansible Setup
Use `reset-setup.sh` between runs to remove the metrics packages, generated config, repositories, local metrics data, and metadata created by either setup path.

```bash
sudo ./reset-setup.sh --purge-benchmark-cache
time ./setup-via-ansible.sh environmentID='ID'

sudo ./reset-setup.sh --purge-benchmark-cache
time ./setup.sh environmentID='ID'
```

For a data-preserving reset, use `sudo ./reset-setup.sh --keep-data`. The reset script does not restore the hostname.

#### Method 1: Environment Variables
```bash
export ENVIRONMENT_ID="your-environment-id"

# Run setup; it delegates to setup-raw.sh and auto-detects env vars
./setup.sh
```

#### Method 2: Direct Invocation
```bash
# NEVER run with -x flag or debugging enabled!
# The script will refuse to run if debugging is detected

# Download and run (secrets protected)
curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
  bash -s -- environmentID='ID'
```

To keep the current hostname unchanged, append `--skip-hostname-conf` to the `bash -s -- ...` arguments.

### Security Protections

The scripts include multiple layers of security:

1. **Debug Mode Detection**: Scripts refuse `bash -x` or `sh -x` before doing work, while preserving the default tolerated exit behavior
2. **Trace Protection**: Detects and blocks shell tracing (`set -x`)
3. **History Disabled**: Command history is disabled during execution
4. **Local Generation**: Metrics credentials are generated independently on each new host
5. **Existing-Host Guard**: An initialized InfluxDB without the matching credential record is left unchanged and requires explicit operator handling
6. **No Timestream Credentials**: Future installations do not configure Timestream output or write AWS credentials

This change is intentionally new-install-only. It does not rotate, remove, or repair credentials on existing Brev hosts.

### Debugging Safely
If you need to debug, use targeted verbosity:
```bash
# setup.sh and setup-raw.sh emit high-level [INFO], [WARN], and [ERROR] status lines.
# Avoid bash -x or set -x because both scripts intentionally refuse traced execution.
./setup.sh
```
