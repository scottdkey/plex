#!/usr/bin/env bash
# Creates and configures a Plex LXC on Proxmox VE.
# Run on the Proxmox host as root.
#
# Usage: provision.sh <vmid> [options]
#
# Options:
#   --hostname NAME       LXC hostname (default: plex)
#   --storage POOL        Proxmox storage pool for rootfs (default: local-lvm)
#   --disk SIZE           Root disk size (default: 32G)
#   --memory MB           RAM in MB (default: 4096)
#   --cores N             CPU cores (default: 4)
#   --bridge BRIDGE       Network bridge (default: vmbr0)
#   --ip IP/CIDR          Static IP with prefix (e.g. 192.168.1.50/24)
#   --gw GATEWAY          Default gateway IP
#   --media PATH          Host path to media directory (mounted read-only at /mnt/media)
#   --config PATH         Host path for Plex config (mounted at /var/lib/plexmediaserver)
#   --plex-version VER    Plex version to install (default: latest)
#   --render-gid GID      GID of /dev/dri/renderD128 on the host (auto-detected if omitted)
#   --card-gid GID        GID of /dev/dri/card0 on the host (auto-detected if omitted)
#   --no-gpu              Skip GPU passthrough (software transcode only)
set -euo pipefail

VMID="${1:?Usage: $0 <vmid> [options]}"
shift

HOSTNAME="plex"
STORAGE="local-lvm"
DISK="32G"
MEMORY="4096"
CORES="4"
BRIDGE="vmbr0"
IP=""
GW=""
MEDIA_PATH=""
CONFIG_PATH="/opt/plex/config"
PLEX_VERSION="latest"
RENDER_GID=""
CARD_GID=""
NO_GPU=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)    HOSTNAME="$2";      shift 2 ;;
        --storage)     STORAGE="$2";       shift 2 ;;
        --disk)        DISK="$2";          shift 2 ;;
        --memory)      MEMORY="$2";        shift 2 ;;
        --cores)       CORES="$2";         shift 2 ;;
        --bridge)      BRIDGE="$2";        shift 2 ;;
        --ip)          IP="$2";            shift 2 ;;
        --gw)          GW="$2";            shift 2 ;;
        --media)       MEDIA_PATH="$2";    shift 2 ;;
        --config)      CONFIG_PATH="$2";   shift 2 ;;
        --plex-version) PLEX_VERSION="$2"; shift 2 ;;
        --render-gid)  RENDER_GID="$2";    shift 2 ;;
        --card-gid)    CARD_GID="$2";      shift 2 ;;
        --no-gpu)      NO_GPU=1;           shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Auto-detect GPU device GIDs from host if not overridden
if [[ $NO_GPU -eq 0 ]]; then
    if [[ -z "$RENDER_GID" ]] && [[ -e /dev/dri/renderD128 ]]; then
        RENDER_GID=$(stat -c '%g' /dev/dri/renderD128)
    fi
    if [[ -z "$CARD_GID" ]] && [[ -e /dev/dri/card0 ]]; then
        CARD_GID=$(stat -c '%g' /dev/dri/card0)
    fi
    if [[ -z "$RENDER_GID" ]]; then
        echo "[provision] Warning: /dev/dri/renderD128 not found — skipping GPU passthrough" >&2
        NO_GPU=1
    fi
fi

# Resolve the latest available Debian 12 standard template
TEMPLATE_STORE="local"
TEMPLATE=$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' \
    | grep '^debian-12-standard' \
    | sort -V \
    | tail -1)

if [[ -z "$TEMPLATE" ]]; then
    echo "[provision] No Debian 12 standard template found in available list." >&2
    echo "[provision] Run: pveam update && pveam download local <template-name>" >&2
    exit 1
fi

if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -qF "$TEMPLATE"; then
    echo "[provision] Downloading ${TEMPLATE}..."
    pveam update
    pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi

# Network config
NET_ARGS="name=eth0,bridge=${BRIDGE},firewall=1"
if [[ -n "$IP" ]]; then
    NET_ARGS="${NET_ARGS},ip=${IP}"
    [[ -n "$GW" ]] && NET_ARGS="${NET_ARGS},gw=${GW}"
else
    NET_ARGS="${NET_ARGS},ip=dhcp"
fi

# Create the container (privileged — required for GPU passthrough)
echo "[provision] Creating LXC ${VMID} (${HOSTNAME})..."
pct create "$VMID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "$NET_ARGS" \
    --ostype debian \
    --unprivileged 0 \
    --features nesting=1 \
    --start 0

# GPU passthrough and runtime config
{
    echo "lxc.apparmor.profile: unconfined"
    echo "lxc.seccomp.profile:"
    echo "lxc.mount.entry: tmpfs dev/shm tmpfs nodev,nosuid,size=4g,mode=1777,create=dir 0 0"
    if [[ $NO_GPU -eq 0 ]]; then
        echo "dev0: /dev/dri/renderD128,gid=${RENDER_GID}"
        [[ -n "$CARD_GID" ]] && echo "dev1: /dev/dri/card0,gid=${CARD_GID}"
    fi
} >> "/etc/pve/lxc/${VMID}.conf"

# Mount points — sequential from 0
MP_INDEX=0
if [[ -n "$MEDIA_PATH" ]]; then
    echo "mp${MP_INDEX}: ${MEDIA_PATH},mp=/mnt/media,ro=1" >> "/etc/pve/lxc/${VMID}.conf"
    MP_INDEX=$((MP_INDEX + 1))
fi
mkdir -p "$CONFIG_PATH"
echo "mp${MP_INDEX}: ${CONFIG_PATH},mp=/var/lib/plexmediaserver" >> "/etc/pve/lxc/${VMID}.conf"

echo "[provision] Starting LXC ${VMID}..."
pct start "$VMID"

# Wait for network
echo "[provision] Waiting for network..."
for _i in $(seq 1 30); do
    if pct exec "$VMID" -- curl -fsSL --max-time 3 https://downloads.plex.tv > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Copy and run install script
echo "[provision] Installing Plex ${PLEX_VERSION}..."
pct push "$VMID" "${SCRIPT_DIR}/../scripts/install.sh" /tmp/install.sh --mode 0755
pct exec "$VMID" -- bash /tmp/install.sh "$PLEX_VERSION"

# Copy and run configure script
echo "[provision] Configuring Plex..."
pct push "$VMID" "${SCRIPT_DIR}/../scripts/configure.sh" /tmp/configure.sh --mode 0755
pct exec "$VMID" -- bash /tmp/configure.sh

LXC_IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
echo ""
echo "[provision] Done. LXC ${VMID} (${HOSTNAME}) is running Plex."
echo "            Open http://${LXC_IP}:32400/web to set up."
[[ $NO_GPU -eq 0 ]] && echo "            GPU: render GID=${RENDER_GID}" || echo "            GPU: disabled (software transcode)"
