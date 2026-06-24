# plex

Self-hosted Plex Media Server with Intel VAAPI hardware transcoding and HDR tone mapping.

Built from `debian:12-slim`. Supports Docker, Podman, and Dockge.

## Features

- Intel Quick Sync hardware transcoding (encode + decode via VAAPI)
- HDR → SDR tone mapping via `tonemap_vaapi` (requires OpenCL)
- Wide Intel GPU support: Gen4–9 (i965) and Gen8+ iHD
- Debian 12 base — no glibc/musl shim required
- Automatic uid/gid remapping at runtime
- Published to GHCR: `ghcr.io/scottdkey/plex:latest`

## Intel GPU Support

| Generation | Examples | Driver |
|---|---|---|
| Gen4–9 | HD 2000–6000, Haswell, Broadwell, Skylake | `i965` |
| Gen8–12+ | UHD 600+, Alder Lake, Raptor Lake, Arrow Lake | `iHD` (default) |

Set `LIBVA_DRIVER_NAME=auto` to detect automatically, or pin to `iHD` / `i965`.

## Prerequisites

### Host requirements

```sh
# Verify GPU render node is present
ls /dev/dri/renderD128

# Add your user to the render/video group if needed
usermod -aG render,video $USER
```

### Proxmox LXC

For LXC containers, pass through the render device in the CT config:

```
# /etc/pve/lxc/<vmid>.conf
features: nesting=1
dev0: /dev/dri/renderD128,gid=44
dev1: /dev/dri/card0,gid=44
lxc.seccomp.profile =
```

Docker must be installed inside the LXC with `nesting=1`.

## Quick Start

```sh
docker run -d \
  --name plex \
  --network=host \
  --shm-size=4g \
  --restart=unless-stopped \
  -e TZ=America/New_York \
  -e PLEX_UID=$(id -u) \
  -e PLEX_GID=$(id -g) \
  -e PLEX_CLAIM=claim-xxxxxxxxxxxx \
  -v /opt/plex/config:/config \
  -v /opt/plex/transcode:/transcode \
  -v /mnt/media:/mnt/media:ro \
  --device /dev/dri/renderD128 \
  --device /dev/dri/card0 \
  ghcr.io/scottdkey/plex:latest
```

Get a claim token at [plex.tv/claim](https://plex.tv/claim) — it expires in 4 minutes.

## Compose Examples

See the [`examples/`](examples/) directory:

| File | Description |
|---|---|
| `docker-compose.basic.yml` | Minimal setup |
| `docker-compose.dockge.yml` | Dockge-managed deployment |
| `docker-compose.tmpfs-transcode.yml` | RAM-backed transcode dir (fastest, no disk wear) |
| `docker-compose.older-intel.yml` | Gen4–9 iGPUs using i965 driver |

Copy and adjust the example that fits your setup:

```sh
cp examples/docker-compose.dockge.yml compose.yml
# edit compose.yml — set TZ, PLEX_UID, PLEX_GID, volume paths
docker compose up -d
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PLEX_UID` | `1000` | UID for the plex process |
| `PLEX_GID` | `1000` | GID for the plex process |
| `TZ` | `UTC` | Timezone |
| `LIBVA_DRIVER_NAME` | `iHD` | VA driver: `iHD`, `i965`, or `auto` |
| `LIBVA_DRIVERS_PATH` | `/usr/lib/x86_64-linux-gnu/dri` | Path to VA driver `.so` files |
| `PLEX_CLAIM` | _(unset)_ | Claim token from plex.tv/claim — first run only |
| `CONFIG_DIR` | `/config/Library/Application Support` | Plex application support dir |
| `TRANSCODE_DIR` | `/transcode` | Transcode temp dir |

## Volumes

| Mount | Description |
|---|---|
| `/config` | Plex library, database, preferences — **must be persistent** |
| `/transcode` | Transcode working directory — can be tmpfs |
| `/mnt/media` | Mount your media here (any path, read-only recommended) |

## Enabling Hardware Transcoding

After first run, open Plex Settings:

1. **Settings → Transcoder → Enable Hardware-Accelerated Encoding** ✓
2. **Settings → Transcoder → Use Hardware-Accelerated Video Encoding** ✓
3. **Settings → Transcoder → Enable HDR tone mapping** ✓

Verify from inside the container:

```sh
docker exec plex vainfo
# expect: iHD driver ... VAProfileH264 / VAProfileHEVC entrypoints
```

## Plex Pass

Hardware transcoding requires an active [Plex Pass](https://www.plex.tv/plex-pass/) subscription.

## Building Locally

```sh
git clone https://github.com/scottdkey/plex
cd plex
docker build -t plex-local .
```

## CI / Published Image

GitHub Actions builds and pushes to GHCR on every push to `main` and on version tags:

```
ghcr.io/scottdkey/plex:latest
ghcr.io/scottdkey/plex:v1.0.0
```
