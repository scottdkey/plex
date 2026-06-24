#!/usr/bin/env bash
# Installs Plex Media Server + GPU drivers on Debian 12.
# Works in Docker (called from Dockerfile) and bare LXC/VM.
# Usage: install.sh [plex-version]   — defaults to "latest"
set -euo pipefail

PLEX_VERSION="${1:-latest}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    tzdata \
    udev \
    xmlstarlet \
    uuid-runtime \
    ocl-icd-libopencl1 \
    mesa-va-drivers \
    gosu \
    vainfo

# Enable non-free repos for Intel drivers (idempotent).
# Debian 12 Docker image uses DEB822 format; Proxmox LXC templates use legacy sources.list.
if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    if ! grep -q 'non-free' /etc/apt/sources.list.d/debian.sources; then
        sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
            /etc/apt/sources.list.d/debian.sources
    fi
elif [ -f /etc/apt/sources.list ]; then
    if ! grep -q 'non-free' /etc/apt/sources.list; then
        sed -i 's/^\(deb .*debian\.org\/debian bookworm main\)$/\1 contrib non-free non-free-firmware/' \
            /etc/apt/sources.list
    fi
fi

# Intel drivers are x86-only
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    apt-get update
    apt-get install -y --no-install-recommends \
        intel-media-va-driver-non-free \
        i965-va-driver \
        intel-opencl-icd
fi

# Install Plex
if [ "$PLEX_VERSION" = "latest" ]; then
    curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key \
        | gpg --dearmor -o /usr/share/keyrings/plex-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/plex-archive-keyring.gpg] https://downloads.plex.tv/repo/deb public main" \
        > /etc/apt/sources.list.d/plexmediaserver.list
    apt-get update
    apt-get install -y --no-install-recommends plexmediaserver
else
    curl -fsSL \
        "https://downloads.plex.tv/plex-media-server-new/${PLEX_VERSION}/debian/plexmediaserver_${PLEX_VERSION}_${ARCH}.deb" \
        -o /tmp/plex.deb
    dpkg -i /tmp/plex.deb || apt-get install -y -f
    rm /tmp/plex.deb
fi

apt-get clean
find /var/lib/apt/lists -type f -delete
