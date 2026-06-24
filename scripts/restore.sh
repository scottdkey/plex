#!/usr/bin/env bash
# Restores Plex Media Server config from a backup created by backup.sh.
# Supports tar.gz backups (default) and PBS backups (--pbs).
#
# Usage (tar.gz):
#   restore.sh <backup-file.tar.gz> [--force]
#
# Usage (PBS):
#   restore.sh --pbs [--snapshot TIMESTAMP] [--force]
#
# PBS env vars (required for --pbs):
#   PBS_REPOSITORY   e.g. backup@pbs@192.168.1.10:datastore
#   PBS_FINGERPRINT  server certificate fingerprint (optional if trusted)
#   PBS_PASSWORD     (optional)
#
# Invocation:
#   LXC (inside container):
#     bash restore.sh /mnt/backups/plex-backup-minimal-20260624-010000.tar.gz
#
#   Docker (inside container):
#     docker exec plex bash -c "curl -fsSL https://raw.githubusercontent.com/scottdkey/plex/main/scripts/restore.sh | bash -s -- /backups/plex-backup-minimal-20260624-010000.tar.gz"
#
#   Docker host (stops/starts container around restore):
#     curl -fsSL https://raw.githubusercontent.com/scottdkey/plex/main/scripts/restore.sh \
#       | bash -s -- /opt/plex/backups/plex-backup-minimal-20260624-010000.tar.gz --container plex
set -euo pipefail

BACKUP_FILE=""
CONTAINER=""
PBS=0
PBS_SNAPSHOT=""
FORCE=0

# First arg may be positional (tar.gz path) or a flag
if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
    BACKUP_FILE="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)  CONTAINER="$2";      shift 2 ;;
        --pbs)        PBS=1;               shift ;;
        --snapshot)   PBS_SNAPSHOT="$2";   shift 2 ;;
        --force)      FORCE=1;             shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Auto-detect Plex data dir ─────────────────────────────────────────────────
if [[ -n "$CONTAINER" ]]; then
    DATA_DIR=$(docker inspect "$CONTAINER" \
        --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
    [[ -n "$DATA_DIR" ]] || { echo "[restore] Error: could not determine /config volume for '${CONTAINER}'" >&2; exit 1; }
elif [[ -d /var/lib/plexmediaserver ]]; then
    DATA_DIR="/var/lib/plexmediaserver"
elif [[ -d /config ]]; then
    DATA_DIR="/config"
else
    echo "[restore] Error: Plex data dir not found. Use --container NAME for host-side Docker." >&2
    exit 1
fi

PMS_DIR="${DATA_DIR}/Library/Application Support/Plex Media Server"

# ── Runtime detection ─────────────────────────────────────────────────────────
HAS_SYSTEMCTL=0
command -v systemctl > /dev/null 2>&1 && systemctl is-system-running > /dev/null 2>&1 && HAS_SYSTEMCTL=1 || true

plex_stop() {
    if [[ -n "$CONTAINER" ]]; then
        echo "[restore] Stopping Docker container: ${CONTAINER}..."
        docker stop "$CONTAINER" 2>/dev/null || true
    elif [[ $HAS_SYSTEMCTL -eq 1 ]]; then
        echo "[restore] Stopping plexmediaserver (systemctl)..."
        systemctl stop plexmediaserver 2>/dev/null || true
    elif pgrep -f "Plex Media Server" > /dev/null 2>&1; then
        echo "[restore] Stopping Plex Media Server (pkill)..."
        pkill -f "Plex Media Server" || true
        sleep 3
    fi
}

plex_start() {
    if [[ -n "$CONTAINER" ]]; then
        echo "[restore] Starting Docker container: ${CONTAINER}..."
        docker start "$CONTAINER" 2>/dev/null || true
    elif [[ $HAS_SYSTEMCTL -eq 1 ]]; then
        echo "[restore] Starting plexmediaserver (systemctl)..."
        systemctl start plexmediaserver 2>/dev/null || true
        echo "[restore] Plex started."
    fi
}

# ── PBS path ─────────────────────────────────────────────────────────────────
if [[ $PBS -eq 1 ]]; then
    [[ -n "${PBS_REPOSITORY:-}" ]] || { echo "[restore] PBS_REPOSITORY is required for --pbs" >&2; exit 1; }
    command -v proxmox-backup-client > /dev/null 2>&1 || {
        echo "[restore] proxmox-backup-client not found." >&2; exit 1
    }

    # List snapshots if no specific one requested
    if [[ -z "$PBS_SNAPSHOT" ]]; then
        echo "[restore] Available PBS snapshots for host/plex:"
        proxmox-backup-client snapshots "host/plex"
        echo ""
        # Pick latest
        PBS_SNAPSHOT=$(proxmox-backup-client snapshots "host/plex" 2>/dev/null \
            | grep -v '^Backup' | awk '{print $3}' | sort | tail -1)
        [[ -n "$PBS_SNAPSHOT" ]] || { echo "[restore] No PBS snapshots found for host/plex" >&2; exit 1; }
        echo "[restore] Using latest snapshot: ${PBS_SNAPSHOT}"
    fi

    echo "[restore] PBS snapshot: ${PBS_SNAPSHOT}"
    echo "[restore] Target: ${PMS_DIR}"

    if [[ $FORCE -eq 0 ]]; then
        read -r -p "[restore] This will overwrite existing Plex config. Continue? [y/N] " confirm
        [[ "${confirm,,}" == "y" ]] || { echo "[restore] Aborted."; exit 0; }
    fi

    plex_stop
    trap plex_start EXIT

    mkdir -p "$PMS_DIR"
    echo "[restore] Restoring from PBS..."
    proxmox-backup-client restore "host/plex/${PBS_SNAPSHOT}" "plex-config.pxar" "$PMS_DIR"

    if getent passwd plex > /dev/null 2>&1; then
        chown -R plex:plex "$DATA_DIR"
    fi

    echo "[restore] Done. Restored to: ${PMS_DIR}"
    exit 0
fi

# ── tar.gz path ───────────────────────────────────────────────────────────────
[[ -n "$BACKUP_FILE" ]] || { echo "Usage: $0 <backup-file.tar.gz> [--force]  OR  $0 --pbs [--snapshot TS] [--force]" >&2; exit 1; }
[[ -f "$BACKUP_FILE" ]] || { echo "[restore] Error: backup file not found: $BACKUP_FILE" >&2; exit 1; }

echo "[restore] Backup: ${BACKUP_FILE}"
echo "[restore] Target: ${DATA_DIR}"

if [[ $FORCE -eq 0 ]]; then
    read -r -p "[restore] This will overwrite existing Plex config. Continue? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { echo "[restore] Aborted."; exit 0; }
fi

plex_stop
trap plex_start EXIT

echo "[restore] Extracting..."
tar -xzf "$BACKUP_FILE" -C "$DATA_DIR"

if getent passwd plex > /dev/null 2>&1; then
    chown -R plex:plex "$DATA_DIR"
fi

echo "[restore] Done. Restored to: ${DATA_DIR}"
