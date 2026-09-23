#!/bin/bash
#
# install.sh — one-shot installer for odoo-backup.sh
# Author : Eng. Samir (Eng.Samir)
# Version: 1.0
#
# Run this ONCE on any new server. It does everything:
#   - installs msmtp/mailutils
#   - downloads odoo-backup.sh from GitHub
#   - generates an SSH key for this server (if missing)
#   - copies it to the backup server (asks for the backup server's
#     root password ONE time, interactively, to install the key)
#   - writes /etc/odoo-backup/config.env
#   - writes /etc/odoo-backup/notify.env (Telegram/Slack/Email)
#   - sets correct permissions
#   - adds the daily 2am cron job
#   - runs a first backup immediately so you see it works
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Samirlinux/odoo/main/install.sh -o install.sh
#   chmod +x install.sh
#   sudo ./install.sh

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Samirlinux/odoo/main"
BACKUP_SERVER="188.40.242.120"
BACKUP_USER="root"
SSH_KEY="/root/.ssh/odoo_backup_key"

TELEGRAM_BOT_TOKEN="8848314913:AAFqUpjErxSj4M3T6vRra-ry2ZXxaMJt7HM"
TELEGRAM_CHAT_ID="1878170522"
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/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"
MAIL_FROM="linux.system25@gmail.com"
MAIL_TO="linux.system25@gmail.com"
GMAIL_APP_PASSWORD="cnysxgbfcgtgghkf"

echo "=== [1/8] Installing dependencies (msmtp, mailutils) ==="
apt-get update -qq
apt-get install -y -qq msmtp msmtp-mta mailutils

echo "=== [2/8] Downloading odoo-backup.sh ==="
curl -fsSL "${REPO_RAW}/odoo-backup.sh" -o /usr/local/bin/odoo-backup.sh
chmod +x /usr/local/bin/odoo-backup.sh

echo "=== [3/8] Setting up SSH key for this server ==="
if [ ! -f "${SSH_KEY}" ]; then
    ssh-keygen -t ed25519 -C "odoo-backup-$(hostname)" -f "${SSH_KEY}" -N ""
    echo "New key generated. You'll be asked for the backup server's root"
    echo "password ONCE now, to install the key:"
    ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=accept-new \
        "${BACKUP_USER}@${BACKUP_SERVER}"
else
    echo "Key already exists at ${SSH_KEY}, skipping generation."
fi

echo "=== [4/8] Writing /etc/odoo-backup/config.env ==="
mkdir -p /etc/odoo-backup
cat > /etc/odoo-backup/config.env << EOF
# Server: $(hostname)
BACKUP_SERVER="${BACKUP_SERVER}"
BACKUP_USER="${BACKUP_USER}"
SSH_KEY="${SSH_KEY}"
EOF
chown root:root /etc/odoo-backup/config.env
chmod 600 /etc/odoo-backup/config.env

echo "=== [5/8] Writing /etc/odoo-backup/notify.env ==="
cat > /etc/odoo-backup/notify.env << EOF
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}"
MAIL_FROM="${MAIL_FROM}"
MAIL_TO="${MAIL_TO}"
EOF
chown root:root /etc/odoo-backup/notify.env
chmod 600 /etc/odoo-backup/notify.env

echo "=== [6/8] Configuring msmtp (Gmail SMTP) ==="
cat > /etc/msmtprc << EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        gmail
host           smtp.gmail.com
port           587
from           ${MAIL_FROM}
user           ${MAIL_FROM}
password       ${GMAIL_APP_PASSWORD}

account default : gmail
EOF
chown root:root /etc/msmtprc
chmod 600 /etc/msmtprc

echo "=== [7/8] Adding daily cron job (2:00 AM) ==="
CRON_LINE="0 2 * * * /usr/local/bin/odoo-backup.sh"
( crontab -l 2>/dev/null | grep -v "odoo-backup.sh" ; echo "$CRON_LINE" ) | crontab -

echo "=== [8/8] Running first backup now ==="
/usr/local/bin/odoo-backup.sh

echo ""
echo "✅ Installation complete on $(hostname)."
echo "   Check Telegram/Slack for the success notification."
echo "   Logs: /var/log/odoo-backup.log"
