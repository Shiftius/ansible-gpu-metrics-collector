# Hardware Metadata Role

This Ansible role gathers detailed hardware information from the target system and stores it in `/etc/brev/metadata.json`.

## Features

- Collects comprehensive hardware information including:
  - CPU details (architecture, cores, threads, model)
  - Memory information (total, free, swap)
  - Motherboard details
  - BIOS information
  - System serial numbers and UUIDs
  - GPU/Accelerator information with detailed NVIDIA support:
    - NVIDIA driver version (from multiple sources)
    - CUDA driver version (from nvidia-smi)
    - CUDA toolkit version (from nvcc)
    - CUDA runtime library version
    - GPU specifications (model, memory, compute capability, VBIOS version)
    - GPU serial numbers and UUIDs
    - GPU topology and multi-GPU configuration
    - Persistence mode and compute mode settings
    - Power limits and clock speeds
  - AMD GPU information (via rocm-smi)
  - Intel GPU information (via lspci)
  - Network adapter information
  - Storage device information

- Provides a clean `hardware_summary` section with key highlights:
  - CPU model, core count, and vCPU count
  - Total memory
  - Total GPU count and models
  - System vendor and model
- Collects structured data without raw command outputs for easy parsing
- Safely appends to existing JSON file (never replaces existing data)
- Creates `/etc/brev` directory if it doesn't exist
- Creates backup before modifying existing metadata
- All tasks tolerate failures (never fails the playbook)
- Stores all hardware data in a `hardware` dictionary

## Requirements

The role will attempt to install the following packages:
- `dmidecode`
- `pciutils`
- `lshw`

Optional tools for GPU detection:
- `nvidia-smi` (for NVIDIA GPUs)
- `rocm-smi` (for AMD GPUs)

## Role Variables

Available variables are listed below, along with default values (see `defaults/main.yml`):

```yaml
# Path where metadata will be stored
metadata_path: /etc/brev/metadata.json

# Whether to create backup before updating metadata
metadata_backup: yes
```

## Dependencies

None

## Example Playbook

```yaml
- name: Collect hardware metadata
  hosts: all
  become: true
  roles:
    - hardware_metadata
```

## Example Output

The resulting `/etc/brev/metadata.json` file will have the following structure:

```json
{
  "hardware_summary": {
    "cpu_model": "Intel(R) Xeon(R) CPU @ 2.20GHz",
    "total_cpus": 1,
    "total_cores": 8,
    "total_vcpus": 16,
    "total_memory_mb": 65536,
    "total_gpus": 2,
    "gpu_models": "NVIDIA L4, NVIDIA L4",
    "system_vendor": "Google",
    "system_model": "Google Compute Engine"
  },
  "hardware": {
    "cpu": {
      "architecture": "x86_64",
      "processor_count": 1,
      "processor_cores": 8,
      "processor_threads_per_core": 2,
      "processor_vcpus": 16,
      "model_name": "Intel(R) Xeon(R) CPU @ 2.20GHz"
    },
    "memory": {
      "total_mb": 65536,
      "free_mb": 32768,
      "swap_total_mb": 2048,
      "swap_free_mb": 2048
    },
    "motherboard": {
      "manufacturer": "Google",
      "product_name": "Google Compute Engine",
      "product_version": "NA"
    },
    "bios": {
      "vendor": "Google",
      "version": "Google",
      "date": "10/24/2025"
    },
    "system": {
      "vendor": "Google",
      "product_name": "Google Compute Engine",
      "serial_number": "GoogleCloud-...",
      "uuid": "2d2e5750-dbd0-6415-..."
    },
    "gpu": {
      "total_count": 2,
      "nvidia": {
        "count": "2",
        "driver_version": "570.195.03",
        "cuda_toolkit_version": "12.2",
        "cuda_runtime_version": "12.2.140",
        "gpu_models": "NVIDIA L4, NVIDIA L4",
        "serial_numbers": "1322723003395,1322723003396",
        "uuids": "GPU-65ae4220-...,GPU-65ae4221-...",
        "memory_total_mb": "23034,23034",
        "compute_capabilities": "8.9,8.9",
        "pci_bus_ids": "00000000:00:03.0,00000000:00:04.0",
        "persistence_mode": "Enabled",
        "compute_mode": "Default"
      },
      "amd": {
        "count": "0"
      },
      "intel": {
        "count": "0"
      }
    },
    "network": {
      "interfaces": ["lo", "ens4", "docker0"]
    },
    "storage": {
      "devices": {...}
    }
  }
}
```

## License

MIT

## Author Information

This role was created for collecting hardware metadata in a safe, non-failing manner.
