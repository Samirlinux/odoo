#!/bin/bash
#
# odoo-backup.sh
# ---------------------------------------------------------------------------
# Author : Eng. Samir (Eng.Samir)
# Version: 4.1 — auto-detect edition
# ---------------------------------------------------------------------------
#
# Auto-detects the Postgres + Odoo Docker containers, credentials, the
# largest real database, and the filestore path on ANY server that matches
# this stack — no per-server DB config needed. Dumps DB + filestore, ships
# to a remote backup server, and triggers remote processing. Sends
# Telegram / Slack / Email alerts on success and failure.
#
# Recommended cron entry (runs at 2am daily, logs already handled inside):
#   0 2 * * * /usr/local/bin/odoo-backup.sh
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Backup-server config — loaded from /etc/odoo-backup/config.env
# (this part IS the same for every server, so it stays in a small config file)
# ---------------------------------------------------------------------------
CONFIG_ENV="/etc/odoo-backup/config.env"
if [ ! -f "$CONFIG_ENV" ]; then
    echo "ERROR: Missing ${CONFIG_ENV}. Copy config.env.example there and fill it in." >&2
    exit 1
fi
# shellcheck source=/etc/odoo-backup/config.env
source "$CONFIG_ENV"

: "${BACKUP_SERVER:?BACKUP_SERVER not set in ${CONFIG_ENV}}"
: "${BACKUP_USER:?BACKUP_USER not set in ${CONFIG_ENV}}"
: "${SSH_KEY:?SSH_KEY not set in ${CONFIG_ENV}}"

DATE=$(date +%Y-%m-%d)
HOSTNAME=$(hostname)

WORKDIR="/tmp/odoo-backup-$$"
DEST="/backup/incoming/${HOSTNAME}/${DATE}"
LOCKFILE="/var/lock/odoo-backup.lock"
LOGFILE="/var/log/odoo-backup.log"

SSH_OPTS="-i ${SSH_KEY} -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
MIN_FREE_KB=5000000   # ~5GB minimum free space before dumping

# --- Notifications -----------------------------------------------------
# All secrets live OUTSIDE this script, in /etc/odoo-backup/notify.env
# (chmod 600, owned by root). This file just sources it.
NOTIFY_ENV="/etc/odoo-backup/notify.env"
if [ -f "$NOTIFY_ENV" ]; then
    # shellcheck source=/etc/odoo-backup/notify.env
    source "$NOTIFY_ENV"
fi

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
MAIL_TO="${MAIL_TO:-}"
MAIL_FROM="${MAIL_FROM:-}"

# ---------------------------------------------------------------------------
# Logging: send all stdout/stderr to logfile + console
# ---------------------------------------------------------------------------
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# Locking: prevent overlapping runs
# ---------------------------------------------------------------------------
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log "Another backup run is already in progress. Exiting."
    exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup + failure notification
# ---------------------------------------------------------------------------
notify_telegram() {
    local message="$1"
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 0
    fi
    curl -s -m 10 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="Markdown" \
        --data-urlencode text="${message}" \
        >/dev/null || log "WARNING: Telegram notification failed."
}

notify_slack() {
    local message="$1"
    if [ -z "$SLACK_WEBHOOK_URL" ]; then
        return 0
    fi
    curl -s -m 10 -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"${message}\"}" \
        "$SLACK_WEBHOOK_URL" \
        >/dev/null || log "WARNING: Slack notification failed."
}

notify_email() {
    local subject="$1"
    local message="$2"
    if ! command -v mail >/dev/null 2>&1; then
        log "WARNING: 'mail' command not found, skipping email notification."
        return 0
    fi
    echo "$message" | mail -s "$subject" -r "$MAIL_FROM" "$MAIL_TO" \
        || log "WARNING: Email notification failed."
}

notify_failure() {
    local exit_code=$1
    local msg="🔴 Odoo backup FAILED on *${HOSTNAME}* (exit code ${exit_code}). Check ${LOGFILE}."
    log "Backup FAILED (exit code ${exit_code}) on ${HOSTNAME}"
    notify_telegram "$msg"
    notify_slack "$msg"
    notify_email "Odoo backup FAILED - ${HOSTNAME}" "$msg"
}

notify_success() {
    local msg="✅ Odoo backup completed successfully on *${HOSTNAME}* (${DATE})."
    notify_telegram "$msg"
    notify_slack "$msg"
    # Email on success is often noisy; uncomment if you want it anyway:
    # notify_email "Odoo backup OK - ${HOSTNAME}" "$msg"
}

cleanup() {
    local exit_code=$?
    rm -rf "$WORKDIR"
    if [ "$exit_code" -ne 0 ]; then
        notify_failure "$exit_code"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
mkdir -p "$WORKDIR"

log "Starting Odoo backup on ${HOSTNAME}... (odoo-backup.sh v4.1 - Eng.Samir)"

available_kb=$(df --output=avail "$WORKDIR" | tail -n1 | tr -d ' ')
if [ "$available_kb" -lt "$MIN_FREE_KB" ]; then
    log "ERROR: Not enough free space in ${WORKDIR} (${available_kb}KB available, ${MIN_FREE_KB}KB required)."
    exit 1
fi

if ! ssh $SSH_OPTS "${BACKUP_USER}@${BACKUP_SERVER}" "echo ok" >/dev/null 2>&1; then
    log "ERROR: Cannot reach backup server ${BACKUP_SERVER} via SSH."
    exit 1
fi

# ---------------------------------------------------------------------------
# Auto-detect: postgres container, odoo container, credentials, DB, filestore
# ---------------------------------------------------------------------------
log "Auto-detecting Odoo/Postgres containers..."

DB_CONTAINER=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' 'tolower($2) ~ /postgres/ {print $1; exit}')
ODOO_CONTAINER=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' 'tolower($2) ~ /odoo/ {print $1; exit}')

if [ -z "$DB_CONTAINER" ]; then
    log "ERROR: No running container with a 'postgres' image found (docker ps)."
    exit 1
fi
if [ -z "$ODOO_CONTAINER" ]; then
    log "ERROR: No running container with an 'odoo' image found (docker ps)."
    exit 1
fi
log "Found DB container: ${DB_CONTAINER} / Odoo container: ${ODOO_CONTAINER}"

DB_USER=$(docker exec "$DB_CONTAINER" env | awk -F= '/^POSTGRES_USER=/{print $2; exit}')
DB_PASSWORD=$(docker exec "$DB_CONTAINER" env | awk -F= '/^POSTGRES_PASSWORD=/{print $2; exit}')

if [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    log "ERROR: Could not read POSTGRES_USER/POSTGRES_PASSWORD from ${DB_CONTAINER}."
    exit 1
fi

# Pick the largest real database (skips template0/template1/postgres)
DB=$(docker exec -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" \
    psql -U "$DB_USER" -d postgres -tAc \
    "SELECT datname FROM pg_database
     WHERE datname NOT IN ('template0','template1','postgres')
     ORDER BY pg_database_size(datname) DESC LIMIT 1;" | tr -d '[:space:]')

if [ -z "$DB" ]; then
    log "ERROR: Could not determine target database inside ${DB_CONTAINER}."
    exit 1
fi
log "Selected database: ${DB} (largest by size)"

# Filestore lives on the host wherever the odoo container's /var/lib/odoo is mounted
ODOO_DATA_SOURCE=$(docker inspect "$ODOO_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/var/lib/odoo"}}{{.Source}}{{end}}{{end}}')

if [ -z "$ODOO_DATA_SOURCE" ]; then
    log "ERROR: Could not find a /var/lib/odoo mount on container ${ODOO_CONTAINER}."
    exit 1
fi
FILESTORE_HOST_PATH="${ODOO_DATA_SOURCE}/filestore"
log "Filestore base path: ${FILESTORE_HOST_PATH}"

# ---------------------------------------------------------------------------
# Dump PostgreSQL database (running inside Docker container)
# ---------------------------------------------------------------------------
log "Dumping PostgreSQL database '${DB}' from container '${DB_CONTAINER}'..."
docker exec -e PGPASSWORD="${DB_PASSWORD}" "${DB_CONTAINER}" \
    pg_dump -U "${DB_USER}" -Fc "${DB}" > "$WORKDIR/database.dump"

# ---------------------------------------------------------------------------
# Archive filestore (from the Docker volume's host-side path)
# ---------------------------------------------------------------------------
log "Archiving filestore from ${FILESTORE_HOST_PATH}/${DB}..."
if [ ! -d "${FILESTORE_HOST_PATH}/${DB}" ]; then
    log "ERROR: Filestore path not found: ${FILESTORE_HOST_PATH}/${DB}"
    exit 1
fi
tar -czf "$WORKDIR/filestore.tar.gz" -C "$FILESTORE_HOST_PATH" "$DB"

# ---------------------------------------------------------------------------
# Checksums (integrity verification)
# ---------------------------------------------------------------------------
log "Generating checksums..."
(cd "$WORKDIR" && sha256sum database.dump filestore.tar.gz > checksums.sha256)

# ---------------------------------------------------------------------------
# Transfer to backup server (rsync: resumable, compressed, verifiable)
# ---------------------------------------------------------------------------
log "Creating remote destination directory..."
ssh $SSH_OPTS "${BACKUP_USER}@${BACKUP_SERVER}" "mkdir -p ${DEST}"

log "Transferring backup files via rsync..."
rsync -avz --checksum -e "ssh $SSH_OPTS" \
    "$WORKDIR/database.dump" \
    "$WORKDIR/filestore.tar.gz" \
    "$WORKDIR/checksums.sha256" \
    "${BACKUP_USER}@${BACKUP_SERVER}:${DEST}/"

# ---------------------------------------------------------------------------
# Verify checksums on remote side
# ---------------------------------------------------------------------------
log "Verifying checksums on remote server..."
ssh $SSH_OPTS "${BACKUP_USER}@${BACKUP_SERVER}" \
    "cd ${DEST} && sha256sum -c checksums.sha256"

# ---------------------------------------------------------------------------
# Trigger remote processing
# ---------------------------------------------------------------------------
log "Triggering remote processing script..."
ssh $SSH_OPTS "${BACKUP_USER}@${BACKUP_SERVER}" \
    "/usr/local/bin/process-odoo-backup.sh ${HOSTNAME} ${DATE}"

log "Backup completed successfully."
notify_success
