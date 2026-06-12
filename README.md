# iNELS Harmony — Installation

Public distribution repository for iNELS Harmony hotel automation platform.

## Quick install

Run this on a fresh Ubuntu/Debian server:

```bash
curl -sL https://raw.githubusercontent.com/elkoep-dev/harmony-releases/main/install.sh | sudo bash
```

The interactive installer will:
- Install Docker if needed
- Prompt for hotel name, password, network, and ports
- Download and start all Harmony services
- Show the dashboard URLs when complete

## Requirements

- Ubuntu 22.04+ or Debian 12+
- x86_64 or aarch64 architecture
- 3 GB free disk space
- Internet access (or use `--tarball` for offline install)
- Root/sudo access

## CLI options

For automated or offline installs:

```bash
sudo bash install.sh \
  --non-interactive \
  --version 1.28.3 \
  --hotel-name "Grand Palace Hotel" \
  --password "securepass123"
```

| Flag | Description | Default |
|------|-------------|---------|
| `--version VERSION` | Install specific version | latest |
| `--tarball PATH` | Use local tarball (offline) | — |
| `--non-interactive` | No prompts, use defaults | off |
| `--hotel-name NAME` | Hotel name | My Hotel |
| `--password PASSWORD` | Database password | webmodul |
| `--interface IFACE` | Network interface | auto-detect |
| `--landing-port PORT` | Landing page port | 80 |
| `--admin-port PORT` | Administration port | 81 |
| `--reception-port PORT` | Reception port | 82 |

## Releases

Each release contains:
- `install.sh` — smart installer (same as `install.sh` in this repo root)
- `harmony-VERSION.tar.gz` — Docker install package
- `SHA256SUMS` — integrity checksum
