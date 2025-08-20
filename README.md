# ansible-gpu-metrics-collector

## Security Notice

This playbook handles sensitive AWS credentials and database passwords. The following security measures are implemented:

### Security Features
- **No Debug Output**: Shell scripts run with `set +x` to prevent command echoing
- **No-Log Tasks**: Sensitive Ansible tasks use `no_log: true` to prevent credential exposure
- **Secure File Permissions**: Configuration files containing secrets are created with restrictive permissions (0640)
- **Environment Variables**: Secrets are passed via environment variables, not command-line arguments where possible
- **Ansible Configuration**: Default settings prevent display of task arguments

### Best Practices
1. **Never commit secrets** to version control
2. **Use Ansible Vault** for encrypting sensitive variables:
   ```bash
   ansible-vault encrypt_string 'your-secret-key' --name 'aws_timestream_secret_key'
   ```
3. **Limit log verbosity** in production environments
4. **Rotate credentials** regularly
5. **Use IAM roles** instead of access keys when running on AWS infrastructure

### Running Securely

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

# Run setup (will auto-detect env vars)
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

### Security Protections

The scripts include multiple layers of security:

1. **Debug Mode Detection**: Scripts will exit if run with `bash -x` or `sh -x`
2. **Trace Protection**: Detects and blocks shell tracing (`set -x`)
3. **History Disabled**: Command history is disabled during execution
4. **Parameter Clearing**: Positional parameters are cleared after capture
5. **Multiple Checkpoints**: Debug mode is disabled at multiple points

### Debugging Safely
If you need to debug, use targeted verbosity:
```bash
# Use -vv for moderate verbosity (some tasks still hidden)
ansible-playbook -vv playbook.yml

# Use -vvv only in secure environments (may expose secrets)
ansible-playbook -vvv playbook.yml
```
