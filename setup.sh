#!/bin/bash

sudo apt install python3 python3-pip -y
sudo pip install ansible
ansible-playbook -c local -i 'localhost,' -b playbook.yml