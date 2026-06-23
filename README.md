# iNELS Harmony — Installation

Public distribution repository for iNELS Harmony hotel automation platform.

**Current release: 1.28.7** — Harmony Cloud Portal integration, BUS + eLAN driver binaries bundled.

## Quick install

Run this on a fresh Ubuntu/Debian server (with registration token from the [Harmony Portal](https://harmony-portal.inels.com)):

```bash
curl -sL https://raw.githubusercontent.com/elkoep-dev/harmony-releases/main/install.sh \
  | sudo bash -s -- --registration-token hrt_xxxxxxxxxxxx
```

The installer will:
- Install Docker if needed
- Download **Harmony 1.28.7** (latest GitHub release)
- Configure and start all services
- Register with the Harmony Cloud Portal and apply the project license

## Requirements

- Ubuntu 22.04+ or Debian 12+
- x86_64 or aarch64 architecture
- 3 GB free disk space
- Internet access (or use `--tarball` for offline install)
- Root/sudo access

## CLI options

```bash
sudo bash install.sh \
  --non-interactive \
  --version 1.28.7 \
  --registration-token hrt_xxxxxxxxxxxx \
  --hotel-name "Grand Palace Hotel" \
  --password "securepass123"
```

| Flag | Description | Default |
|------|-------------|---------|
| `--version VERSION` | Install specific version | latest release |
| `--registration-token TOKEN` | Portal project token (`hrt_…`) | — |
| `--portal-url URL` | Harmony Portal base URL | harmony-portal.inels.com |
| `--tarball PATH` | Use local tarball (offline) | — |
| `--non-interactive` | No prompts, use defaults | off |
| `--hotel-name NAME` | Hotel name | My Hotel |
| `--password PASSWORD` | Database password | webmodul |
| `--interface IFACE` | Network interface | auto-detect |
| `--landing-port PORT` | Landing page port | 80 |
| `--admin-port PORT` | Administration port | 81 |
| `--reception-port PORT` | Reception port | 82 |
| `--skip-portal` | Install without portal registration | off |
| `--auto-update` | Opt into automatic FW updates | off |

## Releases

Each GitHub release contains:
- `harmony-VERSION.tar.gz` — Docker install package (apps, SQL, **BUS_Driver**, **eLAN_Driver**, portal-agent)
- `SHA256SUMS` — integrity checksum

The `install.sh` script in this repo root is the smart installer used by the one-line `curl | bash` command.
