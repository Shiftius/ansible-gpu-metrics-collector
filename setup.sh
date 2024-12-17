#!/bin/bash

sudo pip install ansible
ansible-playbook -c local -i 'localhost,' playbook.yml