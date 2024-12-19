Role Name
=========

Install and Configure Telegraf with outputs for local InfluxDB and remote AWS Timestream backends

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
      password: LocaFluxCapacity2024
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
