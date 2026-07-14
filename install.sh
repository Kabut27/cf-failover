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

# Hakikisha zana muhimu zipo - baadhi ya VPS minimal hazina cron/curl kwa default
for dep in curl flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "ERROR: '$dep' haipo kwenye mfumo huu. Sakinisha kwanza (mfano: apt-get install -y $dep)."
    exit 1
  fi
done
if ! command -v crontab >/dev/null 2>&1; then
  echo "cron haijasakinishwa - ninasakinisha sasa..."
  apt-get update -qq && apt-get install -y -qq cron
  systemctl enable --now cron >/dev/null 2>&1 || true
fi

# Husomea input isiyo tupu - inarudia kuuliza mpaka mtumiaji ajaze
require_input() {
  local prompt="$1"
  local __resultvar="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rp "$prompt" value
    if [[ -z "$value" ]]; then
      echo "  -> Sehemu hii haiwezi kuachwa wazi, jaribu tena."
    fi
  done
  printf -v "$__resultvar" '%s' "$value"
}

# Muhimu: script inapokimbizwa kupitia "curl | bash", stdin ya kawaida
# inakuwa imeshikwa na curl - hivyo tunailazimisha 'read' isome moja kwa
# moja kutoka kwenye terminal yako (tty) ili maswali yaonekane na kufanya kazi.
if [[ -t 0 ]]; then
  : # stdin tayari ni terminal, hakuna cha kufanya
elif [[ -e /dev/tty ]]; then
  exec < /dev/tty
else
  echo "ERROR: Haiwezi kusoma input ya terminal. Pakua script kisha kimbiza moja kwa moja:"
  echo "  curl -sSL ${REPO_RAW_URL}/install.sh -o install.sh && sudo bash install.sh"
  exit 1
fi

require_input "Cloudflare API Token (Zone.DNS Edit): " CF_API_TOKEN
require_input "Cloudflare Zone ID: " CF_ZONE_ID
echo ""
echo "Weka node IP kwa mpangilio wa priority (ya kwanza ndio unayoitegemea zaidi)."
echo "Zinaweza kuwa 2, 3, au zaidi."
require_input "Node priority (comma separated, mfano 3.3.3.3,2.2.2.2,1.1.1.1): " NODE_PRIORITY
echo ""
echo "Weka domain records ambazo zitabadilishwa pamoja (1, 2, au zaidi)."
require_input "Target records (comma separated, mfano cdn1.domain.com,cdn2.domain.com): " TARGET_RECORDS
echo ""

read -rp "Port ya kucheck [443]: " CHECK_PORT
CHECK_PORT=${CHECK_PORT:-443}
while ! [[ "$CHECK_PORT" =~ ^[0-9]+$ ]] || [[ "$CHECK_PORT" -lt 1 ]] || [[ "$CHECK_PORT" -gt 65535 ]]; do
  echo "  -> Port lazima iwe namba kati ya 1-65535."
  read -rp "Port ya kucheck [443]: " CHECK_PORT
  CHECK_PORT=${CHECK_PORT:-443}
done

read -rp "Fail threshold (mara ngapi ishindwe kabla ya kubadili) [2]: " FAIL_THRESHOLD
FAIL_THRESHOLD=${FAIL_THRESHOLD:-2}
while ! [[ "$FAIL_THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$FAIL_THRESHOLD" -lt 1 ]]; do
  echo "  -> Weka namba kamili (mfano 2, 3)."
  read -rp "Fail threshold (mara ngapi ishindwe kabla ya kubadili) [2]: " FAIL_THRESHOLD
  FAIL_THRESHOLD=${FAIL_THRESHOLD:-2}
done

echo ""
echo "Aina ya health check: 'tcp' (inaangalia tu port iko wazi) au 'http'"
echo "(inaangalia jibu halisi la panel/service - sahihi zaidi)."
read -rp "Check method [tcp]: " CHECK_METHOD
CHECK_METHOD=${CHECK_METHOD:-tcp}
CHECK_METHOD=$(echo "$CHECK_METHOD" | tr '[:upper:]' '[:lower:]')
while [[ "$CHECK_METHOD" != "tcp" && "$CHECK_METHOD" != "http" ]]; do
  echo "  -> Weka 'tcp' au 'http' pekee."
  read -rp "Check method [tcp]: " CHECK_METHOD
  CHECK_METHOD=${CHECK_METHOD:-tcp}
  CHECK_METHOD=$(echo "$CHECK_METHOD" | tr '[:upper:]' '[:lower:]')
done

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
while [[ -n "$TELEGRAM_CHAT_ID" ]] && ! [[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; do
  echo "  -> Chat ID lazima iwe namba (inaweza kuanza na - kwa group chat)."
  read -rp "Telegram Chat ID (hiari): " TELEGRAM_CHAT_ID
done

STATUS_REPORT_MINUTES=360
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo ""
  echo "Ripoti ya hali ya node zote (siyo tu mabadiliko) inaweza kutumwa mara kwa mara."
  read -rp "Tuma ripoti kila dakika ngapi? [360 = masaa 6, weka 0 kuzima]: " STATUS_REPORT_MINUTES
  STATUS_REPORT_MINUTES=${STATUS_REPORT_MINUTES:-360}
  while ! [[ "$STATUS_REPORT_MINUTES" =~ ^[0-9]+$ ]]; do
    echo "  -> Weka namba kamili (mfano 360), au 0 kuzima."
    read -rp "Tuma ripoti kila dakika ngapi? [360]: " STATUS_REPORT_MINUTES
    STATUS_REPORT_MINUTES=${STATUS_REPORT_MINUTES:-360}
  done
fi

echo ""
echo "Inathibitisha uhalali wa Cloudflare Token/Zone ID..."
CF_CHECK=$(curl -s --connect-timeout 5 --max-time 10 \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" 2>/dev/null || echo "")
if echo "$CF_CHECK" | grep -q '"success":true'; then
  echo "  -> Token na Zone ID vimethibitika. ✅"
else
  echo "  -> ONYO: Imeshindwa kuthibitisha Token/Zone ID (huenda si sahihi, au mtandao)."
  echo "     Installation itaendelea, lakini script haitafanya kazi mpaka hii ikamilishwe."
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
DNS_TTL="30"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
STATUS_REPORT_MINUTES="${STATUS_REPORT_MINUTES}"
EOF

chmod 600 "$CONFIG_FILE"

# Cron - inakimbia kila dakika (failover check + ripoti ikiwa muda umefika)
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
