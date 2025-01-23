#!/bin/bash

# Install prerequisites
sudo apt update && sudo apt install python3 python3-pip git -y
sudo pip install ansible

cd /tmp
git clone https://github.com/Shiftius/ansible-gpu-metrics-collector.git mc
cd mc

# Define log directory and file
LOG_DIR="/var/log/ansible"
LOG_FILE="$LOG_DIR/ansible-playbook.log"

# Create the log directory and set permissions
sudo mkdir -p $LOG_DIR
sudo chown ubuntu:ubuntu $LOG_DIR  # Change 'ubuntu' to your username if needed
sudo chmod 775 $LOG_DIR  # Allow read/write for owner and group, read for others

# Create the log file
touch $LOG_FILE
chmod 664 $LOG_FILE  # Allow write for owner and group, read for others
# Capture all script arguments to pass to Ansible as extra-vars
EXTRA_VARS="$@"

# Run the Ansible playbook with logging and extra-vars
ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -c local -i 'localhost,' -b playbook.yml --extra-vars "$EXTRA_VARS"

# Sample call:
# curl -sSL https://raw.githubusercontent.com/Shiftius/ansible-gpu-metrics-collector/main/setup.sh | bash -s -- aws_timestream_access_key='' aws_timestream_secret_key='' aws_timestream_database='' environmentID=''
