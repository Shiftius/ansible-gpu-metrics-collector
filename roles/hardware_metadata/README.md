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

- Safely appends to existing JSON file
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
  "hardware": {
    "cpu": {
      "architecture": "x86_64",
      "processor_count": 1,
      "processor_cores": 8,
      "processor_threads_per_core": 2,
      "processor_vcpus": 16,
      "lscpu_output": "...",
      "dmidecode_output": "..."
    },
    "memory": {
      "memtotal_mb": 65536,
      "memfree_mb": 32768,
      "dmidecode_output": "..."
    },
    "motherboard": {
      "product_name": "...",
      "product_version": "...",
      "dmidecode_output": "..."
    },
    "bios": {
      "bios_date": "...",
      "bios_version": "...",
      "dmidecode_output": "..."
    },
    "system": {
      "system_vendor": "...",
      "product_name": "...",
      "product_serial": "...",
      "product_uuid": "...",
      "dmidecode_output": "..."
    },
    "gpu": {
      "lspci_output": "...",
      "lspci_detailed": "...",
      "nvidia": {
        "driver_version": "535.183.01",
        "cuda_version": "12.2",
        "cuda_toolkit_version": "release 12.2, V12.2.140",
        "cuda_runtime": "libcudart.so.12.2.140",
        "smi_output": "0, Tesla V100-SXM2-32GB, 535.183.01, 00000000:00:1E.0, 0324817063841, GPU-d0a321a5-..., 32768 MiB",
        "detailed_info": "0, Tesla V100-SXM2-32GB, 535.183.01, 00000000:00:1E.0, 0324817063841, GPU-d0a321a5-..., 32768 MiB, 31234 MiB, 7.0, 86.00.46.00.03, 00000000:00:1E.0, 300.00 W, 1530 MHz, 877 MHz",
        "persistence_mode": "Enabled",
        "compute_mode": "Default",
        "topology": "GPU0   GPU1   CPU Affinity   NUMA Affinity..."
      },
      "amd": {
        "rocm_output": "..."
      },
      "intel": {
        "output": "..."
      }
    },
    "network": {
      "devices": [...],
      "lshw_output": "..."
    },
    "storage": {
      "devices": {...},
      "lsblk_output": "..."
    }
  }
}
```

## License

MIT

## Author Information

This role was created for collecting hardware metadata in a safe, non-failing manner.
