# plex

Self-hosted Plex Media Server with automatic GPU detection and hardware transcoding.

Built from `debian:12-slim`. Works with Intel, AMD, and NVIDIA GPUs. Runs on `amd64` and `arm64`.

## Features

- Auto-detects GPU: Intel Quick Sync (iHD/i965), AMD VAAPI (radeonsi), NVIDIA NVENC/NVDEC
- HDR → SDR tone mapping via `tonemap_vaapi` with OpenCL (Intel/AMD)
- Timezone inherited from host automatically
- Automatic uid/gid remapping — no permission headaches
- Works on Docker, Podman, and Dockge
- Published to GHCR: `ghcr.io/argyle-labs/plex:latest`

## GPU Support

| GPU | Generations | Driver | Notes |
|---|---|---|---|
| Intel iHD | Gen8+ (Broadwell → Arrow Lake, UHD 600+) | `iHD` | HDR tone mapping via OpenCL |
| Intel i965 | Gen4–9 (HD 2000–6000, Haswell, Skylake) | `i965` | Open source |
| AMD | GCN+ (RX 400+), RDNA 1/2/3 | `radeonsi` | Via Mesa, no proprietary driver |
| NVIDIA | GTX 900+ / RTX | NVENC/NVDEC | Requires `nvidia-container-toolkit` on host |

`LIBVA_DRIVER_NAME=auto` (the default) probes the available hardware and selects the right driver automatically.

## Quick Start

```sh
docker run -d \
  --name plex \
  --network=host \
  --shm-size=4g \
  --restart=unless-stopped \
  -e PLEX_UID=$(id -u) \
  -e PLEX_GID=$(id -g) \
  -e PLEX_CLAIM=claim-xxxxxxxxxxxx \
  -v /etc/localtime:/etc/localtime:ro \
  -v /opt/plex/config:/config \
  -v /opt/plex/transcode:/transcode \
  -v /mnt/media:/mnt/media:ro \
  --device /dev/dri/renderD128 \
  --device /dev/dri/card0 \
  ghcr.io/argyle-labs/plex:latest
```

Get a claim token at [plex.tv/claim](https://plex.tv/claim) — expires in 4 minutes.

## Compose Examples

See the [`examples/`](examples/) directory:

| File | Description |
|---|---|
| `docker-compose.basic.yml` | Minimal setup — works for Intel and AMD |
| `docker-compose.dockge.yml` | Dockge-managed deployment with healthcheck |
| `docker-compose.tmpfs-transcode.yml` | RAM-backed transcode dir (fastest, no disk wear) |
| `docker-compose.nvidia.yml` | NVIDIA GPU via nvidia-container-toolkit |

All examples use `LIBVA_DRIVER_NAME: auto` and inherit timezone from the host.

```sh
cp examples/docker-compose.dockge.yml compose.yml
# edit: set PLEX_UID, PLEX_GID, volume paths
docker compose up -d
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PLEX_UID` | `1000` | UID for the plex process |
| `PLEX_GID` | `1000` | GID for the plex process |
| `LIBVA_DRIVER_NAME` | `auto` | `auto`, `iHD`, `i965`, `radeonsi` |
| `LIBVA_DRIVERS_PATH` | _(arch-detected)_ | Path to VA driver `.so` files |
| `PLEX_CLAIM` | _(unset)_ | Claim token from plex.tv/claim — first run only |
| `CONFIG_DIR` | `/config/Library/Application Support` | Plex application support dir |
| `TRANSCODE_DIR` | `/transcode` | Transcode temp dir |

## Volumes

| Mount | Description |
|---|---|
| `/etc/localtime` | Mount from host (`ro`) — sets container timezone automatically |
| `/config` | Plex library, database, preferences — **must be persistent** |
| `/transcode` | Transcode working directory — can be tmpfs |
| `/mnt/media` | Your media library (any path, read-only recommended) |

## NVIDIA Prerequisites

NVIDIA requires `nvidia-container-toolkit` on the host:

```sh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Then use `examples/docker-compose.nvidia.yml`.

## Proxmox LXC

For LXC containers (Docker inside LXC), add to `/etc/pve/lxc/<vmid>.conf`:

```
features: nesting=1
dev0: /dev/dri/renderD128,gid=44
dev1: /dev/dri/card0,gid=44
lxc.seccomp.profile =
```

## Enabling Hardware Transcoding in Plex

After first run, open Plex Settings:

1. **Settings → Transcoder → Enable Hardware-Accelerated Encoding** ✓
2. **Settings → Transcoder → Use Hardware-Accelerated Video Encoding** ✓
3. **Settings → Transcoder → Enable HDR tone mapping** ✓

Verify inside the container:

```sh
docker exec plex vainfo
```

## Plex Pass

Hardware transcoding requires an active [Plex Pass](https://www.plex.tv/plex-pass/) subscription.

## Building Locally

```sh
git clone https://github.com/argyle-labs/plex
cd plex
docker build -t plex-local .
```

## Published Image

GitHub Actions builds and pushes to GHCR on every push to `main` and on version tags.
Supports `linux/amd64` and `linux/arm64`.

```
ghcr.io/argyle-labs/plex:latest
ghcr.io/argyle-labs/plex:v1.0.0
```
