#!/bin/bash

# Install prerequisites
sudo apt update && sudo apt install python3 python3-pip -y
sudo pip install ansible

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

# Run the Ansible playbook with logging enabled
ANSIBLE_LOG_PATH=$LOG_FILE ansible-playbook -c local -i 'localhost,' -b playbook.yml