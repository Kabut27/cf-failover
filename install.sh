#!/bin/bash
#
# install.sh - One-click installer kwa cf-failover
#
# Matumizi (baada ya kuweka kwenye GitHub):
#   curl -sSL https://raw.githubusercontent.com/USERNAME_YAKO/REPO_YAKO/main/install.sh | sudo bash
#
# Script hii inakuuliza maswali kisha inaweka kila kitu automatiki:
#  - Inapakua cf-failover.sh
#  - Inatengeneza config file
#  - Inaweka cron job

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

read -rp "Cloudflare API Token (Zone.DNS Edit): " CF_API_TOKEN
read -rp "Cloudflare Zone ID: " CF_ZONE_ID
echo ""
echo "Weka node IP kwa mpangilio wa priority (ya kwanza ndio unayoitegemea zaidi)."
read -rp "Node priority (comma separated, mfano 3.3.3.3,2.2.2.2,1.1.1.1): " NODE_PRIORITY
echo ""
echo "Weka domain records ambazo zitabadilishwa pamoja kuelekeza IP hiyo hiyo."
read -rp "Target records (comma separated, mfano cdn1.domain.com,cdn2.domain.com,cdn3.domain.com): " TARGET_RECORDS
echo ""
read -rp "Port ya kucheck [443]: " CHECK_PORT
CHECK_PORT=${CHECK_PORT:-443}
read -rp "Fail threshold (mara ngapi ishindwe kabla ya kubadili) [2]: " FAIL_THRESHOLD
FAIL_THRESHOLD=${FAIL_THRESHOLD:-2}

echo ""
echo "Inaweka faili..."

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

# Pakua script kuu
curl -sSL "${REPO_RAW_URL}/cf-failover.sh" -o "${INSTALL_DIR}/cf-failover.sh"
chmod +x "${INSTALL_DIR}/cf-failover.sh"

# Andika config
cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN}"
CF_ZONE_ID="${CF_ZONE_ID}"
NODE_PRIORITY="${NODE_PRIORITY}"
TARGET_RECORDS="${TARGET_RECORDS}"
CHECK_PORT="${CHECK_PORT}"
FAIL_THRESHOLD="${FAIL_THRESHOLD}"
EOF

chmod 600 "$CONFIG_FILE"

# Weka cron - inakimbia kila dakika
CRON_LINE="* * * * * ${INSTALL_DIR}/cf-failover.sh >> /var/log/cf-failover.log 2>&1"
( crontab -l 2>/dev/null | grep -v "cf-failover.sh" ; echo "$CRON_LINE" ) | crontab -

echo ""
echo "=============================================="
echo " Imekamilika!"
echo "=============================================="
echo "Config: $CONFIG_FILE"
echo "Script: ${INSTALL_DIR}/cf-failover.sh"
echo "Logs:   /var/log/cf-failover.log"
echo ""
echo "Kimbiza installer hii vivyo hivyo kwenye node zako zote 3 (input sawa kila mahali)."
echo "Angalia logs kwa: tail -f /var/log/cf-failover.log"
