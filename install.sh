#!/bin/bash
#
# install.sh - One-click installer kwa cf-failover
#
# Matumizi:
#   curl -sSL https://raw.githubusercontent.com/Kabut27/cf-failover/main/install.sh | sudo bash

set -euo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/Kabut27/cf-failover/main"
INSTALL_DIR="/opt/cf-failover"
CONFIG_DIR="/etc/cf-failover"
CONFIG_FILE="${CONFIG_DIR}/config.env"

echo "=============================================="
echo " Cloudflare Failover - Installer"
echo "=============================================="
echo ""

if [[ $EUID -ne 0 ]]; then
  echo "Tafadhali kimbiza script hii na sudo/root."
  exit 1
fi

# Muhimu: script inapokimbizwa kupitia "curl | bash", stdin ya kawaida
# inakuwa imeshikwa na curl - hivyo tunailazimisha 'read' isome moja kwa
# moja kutoka kwenye terminal yako (tty) ili maswali yaonekane na kufanya kazi.
if [[ -t 0 ]]; then
  : # stdin tayari ni terminal, hakuna cha kufanya
elif [[ -e /dev/tty ]]; then
  exec < /dev/tty
else
  echo "ERROR: Haiwezi kusoma input ya terminal. Pakua script kisha kimbiza moja kwa moja:"
  echo "  curl -sSL ${0} -o install.sh && sudo bash install.sh"
  exit 1
fi

read -rp "Cloudflare API Token (Zone.DNS Edit): " CF_API_TOKEN
read -rp "Cloudflare Zone ID: " CF_ZONE_ID
echo ""
echo "Weka node IP kwa mpangilio wa priority (ya kwanza ndio unayoitegemea zaidi)."
echo "Zinaweza kuwa 2, 3, au zaidi."
read -rp "Node priority (comma separated, mfano 3.3.3.3,2.2.2.2,1.1.1.1): " NODE_PRIORITY
echo ""
echo "Weka domain records ambazo zitabadilishwa pamoja (1, 2, au zaidi)."
read -rp "Target records (comma separated, mfano cdn1.domain.com,cdn2.domain.com): " TARGET_RECORDS
echo ""
read -rp "Port ya kucheck [443]: " CHECK_PORT
CHECK_PORT=${CHECK_PORT:-443}
read -rp "Fail threshold (mara ngapi ishindwe kabla ya kubadili) [2]: " FAIL_THRESHOLD
FAIL_THRESHOLD=${FAIL_THRESHOLD:-2}

echo ""
echo "Aina ya health check: 'tcp' (inaangalia tu port iko wazi) au 'http'"
echo "(inaangalia jibu halisi la panel/service - sahihi zaidi)."
read -rp "Check method [tcp]: " CHECK_METHOD
CHECK_METHOD=${CHECK_METHOD:-tcp}

HEALTH_PATH="/"
CHECK_SCHEME="https"
if [[ "$CHECK_METHOD" == "http" ]]; then
  read -rp "Health check scheme (http/https) [https]: " CHECK_SCHEME
  CHECK_SCHEME=${CHECK_SCHEME:-https}
  read -rp "Health check path [/]: " HEALTH_PATH
  HEALTH_PATH=${HEALTH_PATH:-/}
fi

echo ""
echo "Arifa za Telegram ni hiari. Acha wazi (Enter) kama hutaki."
read -rp "Telegram Bot Token (hiari): " TELEGRAM_BOT_TOKEN
read -rp "Telegram Chat ID (hiari): " TELEGRAM_CHAT_ID

STATUS_REPORT_MINUTES=360
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo ""
  echo "Ripoti ya hali ya node zote (siyo tu mabadiliko) inaweza kutumwa mara kwa mara."
  read -rp "Tuma ripoti kila dakika ngapi? [360 = masaa 6, weka 0 kuzima]: " STATUS_REPORT_MINUTES
  STATUS_REPORT_MINUTES=${STATUS_REPORT_MINUTES:-360}
fi

echo ""
echo "Inaweka faili..."

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

curl -sSL "${REPO_RAW_URL}/cf-failover.sh" -o "${INSTALL_DIR}/cf-failover.sh"
chmod +x "${INSTALL_DIR}/cf-failover.sh"

cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN}"
CF_ZONE_ID="${CF_ZONE_ID}"
NODE_PRIORITY="${NODE_PRIORITY}"
TARGET_RECORDS="${TARGET_RECORDS}"
CHECK_PORT="${CHECK_PORT}"
FAIL_THRESHOLD="${FAIL_THRESHOLD}"
CHECK_METHOD="${CHECK_METHOD}"
CHECK_SCHEME="${CHECK_SCHEME}"
HEALTH_PATH="${HEALTH_PATH}"
CURL_TIMEOUT="10"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
STATUS_REPORT_MINUTES="${STATUS_REPORT_MINUTES}"
EOF

chmod 600 "$CONFIG_FILE"

# Cron - inakimbia kila dakika
CRON_LINE="* * * * * ${INSTALL_DIR}/cf-failover.sh >> /var/log/cf-failover.log 2>&1"
( crontab -l 2>/dev/null | grep -v "cf-failover.sh" ; echo "$CRON_LINE" ) | crontab -

# Log rotation - inazuia log kujaza disk
if [[ -d /etc/logrotate.d ]]; then
  cat > /etc/logrotate.d/cf-failover <<'EOF'
/var/log/cf-failover.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
fi

echo ""
echo "=============================================="
echo " Imekamilika!"
echo "=============================================="
echo "Config: $CONFIG_FILE"
echo "Script: ${INSTALL_DIR}/cf-failover.sh"
echo "Logs:   /var/log/cf-failover.log"
echo ""
echo "Kimbiza installer hii vivyo hivyo kwenye node zako zote (input sawa kila mahali)."
echo "Angalia logs kwa: tail -f /var/log/cf-failover.log"
