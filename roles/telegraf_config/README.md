Role Name
=========

Install and configure Telegraf with a local InfluxDB backend and independent per-host credentials.

Requirements
------------

N/A

Role Variables
--------------

N/A - derived from environment variables

Dependencies
------------

N/A

Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

```
---
- name: Configure Telegraf
  hosts: all
  become: true
  gather_facts: true
  vars:
    domain: "domain.com"
    influx:
      org: lp
      bucket: lp
      username: lp
    grafana:
      subpath: 'metrics'
  roles:
    - name: telegraf_config
```

License
-------

BSD

Author Information
------------------

https://shifti.us
