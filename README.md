# ansible-gpu-metrics-collector

## Security Notice

This setup handles sensitive Fleet enrollment and metrics credentials. The following security measures are implemented:

### Security Features
- **No Debug Output**: Shell scripts run with `set +x` to prevent command echoing
- **No Secret Echoing**: Sensitive values are written to protected config files without command tracing
- **Secure File Permissions**: Configuration files containing secrets are created with restrictive permissions (0640)
- **Environment Variables**: Secrets are passed via environment variables, not command-line arguments where possible
- **Legacy Ansible Path Preserved**: The playbook and roles remain available for inspection or manual use, but `setup.sh` now defaults to raw shell execution

### Best Practices
1. **Never commit secrets** to version control
2. **Prefer environment variables** over command-line arguments for secrets
3. **Limit log verbosity** in production environments
4. **Rotate credentials** regularly
5. **Use IAM roles** instead of access keys when running on AWS infrastructure

### Running Securely

#### Default: Fast Raw Shell Setup
For fresh instances where startup time matters, use `setup.sh`. It delegates to the flattened raw shell installer, leaves the Ansible playbook and roles in place, and skips Python, the Python virtualenv, and Ansible install work.
When run from a checkout, `setup.sh` also uses local Grafana assets instead of fetching them over HTTP and installs the metrics packages plus the Fleet deb in a single apt transaction. The installer detects the Debian package architecture and selects the matching AMD64 or ARM64 Fleet package.

Fleet remains optional for Brev. Set both `ORBIT_FLEET_URL` and
`ORBIT_ENROLL_SECRET` to request enrollment. Missing values, download failures,
installation failures, or registration failures warn and continue by default.
The secret is copied to a root-only file below `/run`, removed after enrollment,
and Orbit is restarted using its node key. It is never retained in
`/etc/default/orbit`; UUID remains the implicit host identifier.

```bash
export ORBIT_FLEET_URL='https://fleet.example.com'
export ORBIT_ENROLL_SECRET='SECRET'
export environmentID='ID'
curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash
```

The configless Orbit 1.35.0 packages are checksum-pinned. Package installation
does not start Orbit; the installer explicitly enables and starts
`orbit.service` only after runtime enrollment configuration exists. The service
remains enabled after the transient enrollment file and systemd drop-in are
removed.

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

The raw installer also accepts environment variables, which keeps secrets out of the process arguments:

```bash
export AWS_TIMESTREAM_ACCESS_KEY="your-key"
export AWS_TIMESTREAM_SECRET_KEY="your-secret"
export AWS_TIMESTREAM_DATABASE="your-db"
export ENVIRONMENT_ID="your-environment-id"

curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash
```

`setup-raw.sh` can still be invoked directly from a checkout or via curl when you do not need the compatibility wrapper.
For compatibility with the former Ansible extra-vars flow, the raw installer accepts the existing setup values
for `aws_timestream_*`, `environmentID`, `domain`, `host_prefix`, `skip_hostname_conf`, `influx.*`,
`grafana.subpath`, `fleet_amd64_url`, `fleet_pkg_amd64`, `fleet_arm64_url`, `fleet_pkg_arm64`, `metadata_path`, and `metadata_backup`.

#### Benchmarking Raw vs. Ansible Setup
Use `reset-setup.sh` between runs to remove the metrics packages, generated config, repositories, local metrics data, and metadata created by either setup path.

```bash
sudo ./reset-setup.sh --purge-benchmark-cache
time ./setup-via-ansible.sh aws_timestream_access_key='KEY' aws_timestream_secret_key='SECRET' aws_timestream_database='DB' environmentID='ID'

sudo ./reset-setup.sh --purge-benchmark-cache
time ./setup.sh aws_timestream_access_key='KEY' aws_timestream_secret_key='SECRET' aws_timestream_database='DB' environmentID='ID'
```

For a data-preserving reset, use `sudo ./reset-setup.sh --keep-data`. The reset script does not restore the hostname.

#### Method 1: Interactive Secure Input (RECOMMENDED)
```bash
# Use the secure wrapper script for interactive credential input
chmod +x secure-run.sh
./secure-run.sh
# Enter credentials when prompted (input is hidden)
```

#### Method 2: Environment Variables
```bash
# Pass secrets as environment variables
export AWS_TIMESTREAM_ACCESS_KEY="your-key"
export AWS_TIMESTREAM_SECRET_KEY="your-secret"
export AWS_TIMESTREAM_DATABASE="your-db"

# Run setup; it delegates to setup-raw.sh and auto-detects env vars
./setup.sh
```

#### Method 3: Direct Invocation (Use Carefully)
```bash
# NEVER run with -x flag or debugging enabled!
# The script will refuse to run if debugging is detected

# Download and run (secrets protected)
curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
  bash -s -- aws_timestream_access_key='KEY' aws_timestream_secret_key='SECRET' aws_timestream_database='DB' environmentID='ID'
```

To keep the current hostname unchanged, append `--skip-hostname-conf` to the `bash -s -- ...` arguments.

### Security Protections

The scripts include multiple layers of security:

1. **Debug Mode Detection**: Scripts refuse `bash -x` or `sh -x` before doing work, while preserving the default tolerated exit behavior
2. **Trace Protection**: Detects and blocks shell tracing (`set -x`)
3. **History Disabled**: Command history is disabled during execution
4. **Environment Credential Flow**: Environment variables are supported to avoid putting secrets in command-line arguments
5. **Secure Permissions**: Generated secret-bearing files are written with restrictive permissions

### Debugging Safely
If you need to debug, use targeted verbosity:
```bash
# setup.sh and setup-raw.sh emit high-level [INFO], [WARN], and [ERROR] status lines.
# Avoid bash -x or set -x because both scripts intentionally refuse traced execution.
./setup.sh
```
