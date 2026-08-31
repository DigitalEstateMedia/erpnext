#!/bin/bash
# Periodic site backup, run as a supervisord program.
#
# Frappe schedules no backups of its own — the only backup entry in
# frappe/hooks.py is delete_downloadable_backups, which cleans up rather than
# creates. Upstream frappe_docker covers this with a separate backup-cron
# service (overrides/compose.backup-cron.yaml); Railway's single-container
# layout has no room for a sidecar, so it runs here instead.
#
# SCOPE: these land on the sites volume. They protect against a bad migration,
# an accidental delete, or logical corruption — NOT against loss of the volume
# itself. For that the archive has to leave the box; `restic` is already in the
# base image for exactly that, and needs object-storage credentials to enable.
set -u

: "${SITE_NAME:?SITE_NAME is required}"

INTERVAL="${BACKUP_INTERVAL_SECONDS:-86400}"   # daily
SETTLE="${BACKUP_SETTLE_SECONDS:-300}"         # let boot/migrate finish first

cd /home/frappe/frappe-bench

echo "[backup] daily backups armed: first run in ${SETTLE}s, then every ${INTERVAL}s"
sleep "$SETTLE"

while true; do
    echo "[backup] starting $(date -u +%FT%TZ)"
    # Retention is handled by the site's backup_limit config, set at boot.
    if bench --site "$SITE_NAME" backup --with-files; then
        echo "[backup] completed $(date -u +%FT%TZ)"
    else
        echo "[backup] FAILED $(date -u +%FT%TZ)" >&2
    fi
    sleep "$INTERVAL"
done
