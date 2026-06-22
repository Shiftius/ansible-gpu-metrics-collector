# ansible-gpu-metrics-collector

## Security Notice

This setup handles sensitive AWS credentials and database passwords. The following security measures are implemented:

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
When run from a checkout, `setup.sh` also uses local Grafana assets instead of fetching them over HTTP and installs the metrics packages plus the Fleet deb in a single apt transaction.

```bash
curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | \
  bash -s -- aws_timestream_access_key='KEY' aws_timestream_secret_key='SECRET' aws_timestream_database='DB' environmentID='ID'
```

To keep the current hostname unchanged, append `--skip-hostname-conf` to the `bash -s -- ...` arguments.

For parent orchestration that should remain best effort, append `--tolerate-failures`.
The scripts still log `[ERROR]` and `[WARN]` status output, but normalize failures to exit code `0`.

The raw installer also accepts environment variables, which keeps secrets out of the process arguments:

```bash
export AWS_TIMESTREAM_ACCESS_KEY="your-key"
export AWS_TIMESTREAM_SECRET_KEY="your-secret"
export AWS_TIMESTREAM_DATABASE="your-db"
export ENVIRONMENT_ID="your-environment-id"

curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash
```

`setup-raw.sh` can still be invoked directly from a checkout or via curl when you do not need the compatibility wrapper.

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

1. **Debug Mode Detection**: Scripts will exit if run with `bash -x` or `sh -x`
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
