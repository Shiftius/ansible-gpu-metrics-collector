#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display informational messages
echo_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

# Function to wait for apt lock to be free
wait_for_apt_lock() {
    local lock_file="/var/lib/dpkg/lock-frontend"
    local lock_wait_time=60  # Maximum wait time in seconds
    local interval=5         # Interval between checks in seconds
    local elapsed=0

    echo_info "Waiting for apt lock to be released..."

    while sudo fuser "$lock_file" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$lock_wait_time" ]; then
            echo -e "\033[1;31m[ERROR]\033[0m Timeout waiting for apt lock to be released."
            exit 1
        fi
        echo_info "Apt lock is currently held by another process. Waiting..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo_info "Apt lock is now free. Proceeding with package installation."
}

# Update package lists and install prerequisites
echo_info "Updating package lists and installing prerequisites..."

# Wait for any existing apt processes to finish
wait_for_apt_lock

# Proceed with package installation
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv git

# Define virtual environment directory
VENV_DIR="/tmp/ansible_env"

# Create virtual environment if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    echo_info "Creating Python virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
else
    echo_info "Python virtual environment already exists at $VENV_DIR."
fi

# Activate the virtual environment
echo_info "Activating the virtual environment..."
source "$VENV_DIR/bin/activate"

# Upgrade pip within the virtual environment
echo_info "Upgrading pip..."
pip install --upgrade pip

# Install Ansible within the virtual environment
echo_info "Installing Ansible in the virtual environment..."
pip install ansible

# Clone the Ansible repository
REPO_URL="https://github.com/Shiftius/ansible-gpu-metrics-collector.git"
CLONE_DIR="/tmp/mc"

if [ ! -d "$CLONE_DIR" ]; then
    echo_info "Cloning repository from $REPO_URL to $CLONE_DIR..."
    git clone "$REPO_URL" "$CLONE_DIR"
else
    echo_info "Repository already cloned at $CLONE_DIR."
fi

cd "$CLONE_DIR"

# Define log directory and file
LOG_DIR="/var/log/ansible"
LOG_FILE="$LOG_DIR/ansible-playbook.log"

# Create the log directory with appropriate permissions
echo_info "Setting up log directory at $LOG_DIR..."
sudo mkdir -p "$LOG_DIR"
sudo chmod 775 "$LOG_DIR"
# Optional: Change ownership to the current user to allow writing without sudo
# sudo chown "$USER":"$USER" "$LOG_DIR"

# Create the log file with appropriate permissions
echo_info "Creating log file at $LOG_FILE..."
sudo touch "$LOG_FILE"
# Secure the log file by setting appropriate permissions
sudo chmod 664 "$LOG_FILE"
# Optional: Change ownership to the current user to allow writing without sudo
# sudo chown "$USER":"$USER" "$LOG_FILE"

# Capture all script arguments to pass to Ansible as extra-vars
EXTRA_VARS="$@"

# Run the Ansible playbook with logging and extra-vars
echo_info "Running the Ansible playbook..."
ANSIBLE_LOG_PATH="$LOG_FILE" "$VENV_DIR/bin/ansible-playbook" -c local -i 'localhost,' -b playbook.yml --extra-vars "$EXTRA_VARS"

# Deactivate the virtual environment
echo_info "Deactivating the virtual environment..."
deactivate

echo_info "Ansible playbook execution completed successfully."

# Sample call:
# curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash -s -- aws_timestream_access_key='' aws_timestream_secret_key='' aws_timestream_database='' environmentID=''
