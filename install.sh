#!/bin/bash
#
# install.sh - One-click installer kwa cf-failover
#
# Matumizi:
#   curl -sSL https://raw.githubusercontent.com/Kabut27/cf-failover/main/install.sh | sudo bash
#
# USANIFU: Kazi mbili zimetenganishwa kwenye faili/huduma mbili, zote
# mbili zinasakinishwa kwenye SERVER ZOTE (hakuna server "kuu"):
#   1. Health-check + DNS-failover (cf-failover.sh) -> CRON, kila
#      dakika 1. Hii ndiyo inayolinda utulivu wa mfumo - usiifanye ya
#      papo hapo maana node ikipepesuka (flap) DNS itabadilika mno na
#      kuharibu utulivu.
#   2. Amri za Telegram (/addip, vitufe, n.k.) -> SYSTEMD SERVICE
#      (cf-telegram-bot.sh) inayosikiliza muda wote - majibu yanakuja
#      ndani ya sekunde 1-2 badala ya kusubiri run ya cron.

set -euo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/Kabut27/cf-failover/main"
INSTALL_DIR="/opt/cf-failover"
CONFIG_DIR="/etc/cf-failover"
CONFIG_FILE="${CONFIG_DIR}/config.env"
SYSTEMD_UNIT="/etc/systemd/system/cf-failover-telegram.service"

echo "=============================================="
echo " Cloudflare Failover - Installer"
echo "=============================================="
echo ""

if [[ $EUID -ne 0 ]]; then
  echo "Tafadhali kimbiza script hii na sudo/root."
  exit 1
fi

# Hakikisha zana muhimu zipo - baadhi ya VPS minimal hazina cron/curl/jq kwa default
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
if ! command -v jq >/dev/null 2>&1; then
  echo "jq haijasakinishwa - ninasakinisha sasa (inahitajika kwa amri za Telegram)..."
  apt-get update -qq && apt-get install -y -qq jq
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemd (systemctl) haipo kwenye mfumo huu - inahitajika kwa huduma ya Telegram."
  exit 1
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
echo "cf-failover inahifadhi orodha ya node (IP) na domain kwenye TXT record"
echo "MOJA kwenye Cloudflare - HAIHIFADHIWI kwenye VPS hii kabisa. Utaziongeza"
echo "baadaye kupitia amri za Telegram (baada ya usakinishaji kukamilika)."
echo "Weka jina la TXT record hii (chagua jina lolote lisilotumika, mfano"
echo "_cf-failover-config.domain.com) - LAZIMA liwe SAWA kwenye server zote."
require_input "Config record name: " CONFIG_RECORD_NAME
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
echo "Arifa za Telegram ni hiari, LAKINI zinahitajika kama unataka kutumia"
echo "amri za /addip, /removeip, /addrecord n.k. Acha wazi (Enter) kama hutaki."
echo "MUHIMU: tumia bot iliyotengwa kwa cf-failover peke yake (siyo bot"
echo "inayotumika na huduma nyingine), na tumia Bot Token/Chat ID SAWA"
echo "kwenye server zote unazosakinisha."
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

curl -sSL "${REPO_RAW_URL}/cf-failover-lib.sh" -o "${INSTALL_DIR}/cf-failover-lib.sh"
curl -sSL "${REPO_RAW_URL}/cf-failover.sh" -o "${INSTALL_DIR}/cf-failover.sh"
chmod +x "${INSTALL_DIR}/cf-failover-lib.sh" "${INSTALL_DIR}/cf-failover.sh"

cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN}"
CF_ZONE_ID="${CF_ZONE_ID}"
CONFIG_RECORD_NAME="${CONFIG_RECORD_NAME}"
CHECK_PORT="${CHECK_PORT}"
FAIL_THRESHOLD="${FAIL_THRESHOLD}"
CHECK_METHOD="${CHECK_METHOD}"
CHECK_SCHEME="${CHECK_SCHEME}"
HEALTH_PATH="${HEALTH_PATH}"
CURL_TIMEOUT="10"
DNS_TTL="60"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
STATUS_REPORT_MINUTES="${STATUS_REPORT_MINUTES}"
EOF

chmod 600 "$CONFIG_FILE"

# Cron - health-check + DNS-failover TU, kila dakika, kwenye node HII
# (weka kwenye node zote unazosakinisha).
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

# Huduma ya Telegram (systemd) - kwenye server HII (weka kwenye node
# zote unazosakinisha, sawa na cron - hakuna server "kuu"). Inasakinishwa
# tu kama Bot Token/Chat ID zimewekwa.
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo ""
  echo "Inaweka huduma ya Telegram (systemd) kwenye server hii..."
  curl -sSL "${REPO_RAW_URL}/cf-telegram-bot.sh" -o "${INSTALL_DIR}/cf-telegram-bot.sh"
  chmod +x "${INSTALL_DIR}/cf-telegram-bot.sh"
  curl -sSL "${REPO_RAW_URL}/cf-failover-telegram.service" -o "$SYSTEMD_UNIT"
  systemctl daemon-reload
  systemctl enable --now cf-failover-telegram.service
  echo "  -> Huduma ya Telegram imewashwa. Amri zitajibiwa ndani ya sekunde 1-2."
  echo "  -> Angalia kwa: journalctl -u cf-failover-telegram -f"
else
  if systemctl list-unit-files 2>/dev/null | grep -q "cf-failover-telegram.service"; then
    systemctl disable --now cf-failover-telegram.service >/dev/null 2>&1 || true
  fi
fi

echo ""
echo "=============================================="
echo " Imekamilika!"
echo "=============================================="
echo "Config: $CONFIG_FILE"
echo "Scripts: ${INSTALL_DIR}/"
echo "Logs (health-check/cron): /var/log/cf-failover.log"
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "Logs (Telegram bot):      journalctl -u cf-failover-telegram -f"
fi
echo ""
echo "MUHIMU: Kimbiza installer hii kwenye node zako ZOTE ukitumia CF_API_TOKEN,"
echo "CF_ZONE_ID, CONFIG_RECORD_NAME, TELEGRAM_BOT_TOKEN na TELEGRAM_CHAT_ID"
echo "SAWA kila mahali."
echo ""
echo "HATUA INAYOFUATA: Server hii bado HAINA node wala domain yoyote"
echo "iliyowekwa (hazihifadhiwi kwenye VPS kabisa). Fungua Telegram kwenye bot"
echo "yako na tumia vitufe '➕ Ongeza Node' na '🌐 Ongeza Domain' kuanzisha -"
echo "mara utakapoongeza, server ZOTE ulizosakinisha zitafuata kiotomatiki."
