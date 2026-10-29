#!/bin/bash
#
# install.sh (v2.0 Professional Installer & Upgrader)
# Kisakinishi cha Mfumo wa Cloudflare Failover + Telegram Bot (Long-Polling)
#
# Matumizi:
#   sudo bash install.sh             # Usakinishaji mpya au kubadilisha mipangilio
#   sudo bash install.sh --upgrade   # Kusasisha scripts pekee bila kuuliza maswali
#   sudo bash install.sh --uninstall # Kuondoa huduma kwenye server hii

set -uo pipefail

########################################
# 1. RANGI NA MIPANGILIO YA MSINGI
########################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/cf-failover"
CONFIG_DIR="/etc/cf-failover"
CONFIG_FILE="${CONFIG_DIR}/config.env"
NODE_ID_FILE="${CONFIG_DIR}/node-id"

SYSTEMD_DIR="/etc/systemd/system"
BOT_SERVICE="${SYSTEMD_DIR}/cf-telegram-bot.service"
FAILOVER_SERVICE="${SYSTEMD_DIR}/cf-failover.service"
FAILOVER_TIMER="${SYSTEMD_DIR}/cf-failover.timer"

info()  { printf "${CYAN}[INFO]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[SAWA]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[ONYO]${NC} %s\n" "$*"; }
err()   { printf "${RED}[KOSA]${NC} %s\n" "$*" >&2; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "Tafadhali endesha script hii kama root: sudo bash install.sh"
  exit 1
fi

MODE="${1:-install}"

########################################
# 2. KUONDOA MFUMO (--uninstall)
########################################
if [[ "$MODE" == "--uninstall" || "$MODE" == "uninstall" ]]; then
  warn "Inaondoa huduma za Cloudflare Failover kwenye server hii..."
  systemctl stop cf-telegram-bot.service cf-failover.timer cf-failover.service 2>/dev/null || true
  systemctl disable cf-telegram-bot.service cf-failover.timer 2>/dev/null || true
  rm -f "$BOT_SERVICE" "$FAILOVER_SERVICE" "$FAILOVER_TIMER"
  systemctl daemon-reload 2>/dev/null || true

  rm -f /usr/local/bin/cf-failover.sh /usr/local/bin/cf-telegram-bot.sh /usr/local/bin/cf-failover-lib.sh
  rm -rf "$INSTALL_DIR"
  rm -f /var/lock/cf-telegram-bot.lock /var/lock/cf-failover-check.lock

  read -r -p "Je, unataka kufuta pia folder la mipangilio (/etc/cf-failover)? [y/N]: " del_cfg
  if [[ "${del_cfg,,}" == "y" || "${del_cfg,,}" == "yes" ]]; then
    rm -rf "$CONFIG_DIR"
    ok "Mipangilio (/etc/cf-failover) imefutwa."
  else
    info "Mipangilio imeachwa salama kwenye ${CONFIG_DIR}."
  fi
  ok "Mfumo umeondolewa kikamilifu."
  exit 0
fi

########################################
# 3. KUKAGUA FAILI NA KUSAKINISHA VIFURUSHI
########################################
for req_file in cf-failover-lib.sh cf-failover.sh cf-telegram-bot.sh; do
  if [[ ! -f "${SRC_DIR}/${req_file}" ]]; then
    err "Faili '${req_file}' halikupatikana ndani ya ${SRC_DIR}!"
    err "Hakikisha install.sh iko kwenye folder moja na cf-failover-lib.sh, cf-failover.sh, na cf-telegram-bot.sh."
    exit 1
  fi
done

install_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq >/dev/null 2>&1   || missing+=("jq")
  command -v flock >/dev/null 2>&1 || missing+=("util-linux")

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  info "Inasakinisha vifurushi vinavyohitajika: ${missing[*]}..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "${missing[@]}" ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "${missing[@]}" ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}" ca-certificates bash
  else
    err "Imeshindikana kutambua package manager. Tafadhali sakinisha: curl, jq, flock."
    exit 1
  fi
  ok "Vifurushi vimesakinishwa."
}

install_dependencies

########################################
# 4. KUSOMA MIPANGILIO YA ZAMANI (KAMA IPO)
########################################
mkdir -p "$CONFIG_DIR" "$INSTALL_DIR"
chmod 700 "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" || true
fi

CF_API_TOKEN="${CF_API_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CONFIG_RECORD_NAME="${CONFIG_RECORD_NAME:-}"
NODE_PRIORITY="${NODE_PRIORITY:-}"
TARGET_RECORDS="${TARGET_RECORDS:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
CHECK_METHOD="${CHECK_METHOD:-tcp}"
CHECK_PORT="${CHECK_PORT:-443}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
DNS_TTL="${DNS_TTL:-60}"
DEFAULT_PROXIED="${DEFAULT_PROXIED:-false}"
CF_TG_HEARTBEAT_INTERVAL="${CF_TG_HEARTBEAT_INTERVAL:-30}"
CF_TG_LEADER_TTL="${CF_TG_LEADER_TTL:-90}"

########################################
# 5. KAZI ZA KUSAKINISHA FAILI NA SYSTEMD
########################################
deploy_files_and_services() {
  info "Inanakili scripts kwenye ${INSTALL_DIR}..."
  cp -f "${SRC_DIR}/cf-failover-lib.sh" "${INSTALL_DIR}/cf-failover-lib.sh"
  cp -f "${SRC_DIR}/cf-failover.sh" "${INSTALL_DIR}/cf-failover.sh"
  cp -f "${SRC_DIR}/cf-telegram-bot.sh" "${INSTALL_DIR}/cf-telegram-bot.sh"

  chmod 750 "${INSTALL_DIR}/cf-failover-lib.sh" "${INSTALL_DIR}/cf-failover.sh" "${INSTALL_DIR}/cf-telegram-bot.sh"

  # Weka symlinks kwenye /usr/local/bin ili ziweze kuitwa popote
  ln -sf "${INSTALL_DIR}/cf-failover-lib.sh" /usr/local/bin/cf-failover-lib.sh
  ln -sf "${INSTALL_DIR}/cf-failover.sh" /usr/local/bin/cf-failover.sh
  ln -sf "${INSTALL_DIR}/cf-telegram-bot.sh" /usr/local/bin/cf-telegram-bot.sh

  # Hakiki syntax ya Bash
  bash -n "${INSTALL_DIR}/cf-failover-lib.sh"
  bash -n "${INSTALL_DIR}/cf-failover.sh"
  bash -n "${INSTALL_DIR}/cf-telegram-bot.sh"
  ok "Scripts zimehakikiwa na kunakiliwa kikamilifu."

  # Ondoa cron ya zamani (kama ilikuwepo kwenye v1) ili isigongane na systemd timer
  if crontab -l 2>/dev/null | grep -q 'cf-failover\.sh'; then
    info "Inaondoa cron job ya zamani ya cf-failover.sh (inahamia kwenye systemd timer)..."
    crontab -l 2>/dev/null | grep -v 'cf-failover\.sh' | crontab - || true
  fi
  rm -f /etc/cron.d/cf-failover

  info "Inaunda Systemd Services na Timer..."

  cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Cloudflare Failover Telegram Bot Service (v2.0 Long-Polling)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/cf-telegram-bot.sh
Restart=always
RestartSec=3
TimeoutStopSec=10
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  cat > "$FAILOVER_SERVICE" <<EOF
[Unit]
Description=Cloudflare Auto-Failover Health Check (v2.0)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/cf-failover.sh
NoNewPrivileges=true
PrivateTmp=true
EOF

  cat > "$FAILOVER_TIMER" <<EOF
[Unit]
Description=Run Cloudflare Auto-Failover Health Check every 60 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable cf-telegram-bot.service cf-failover.timer >/dev/null 2>&1
  systemctl restart cf-telegram-bot.service
  systemctl restart cf-failover.timer
  systemctl start cf-failover.service || true

  ok "Huduma za Systemd (cf-telegram-bot.service & cf-failover.timer) zimewashwa!"
}

# Kama mtumiaji amechagua --upgrade na config.env tayari ipo, sasisha moja kwa moja!
if [[ "$MODE" == "--upgrade" || "$MODE" == "upgrade" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Hakuna ${CONFIG_FILE} iliyopatikana kwa ajili ya upgrade. Kimbiza 'sudo bash install.sh' bila --upgrade."
    exit 1
  fi
  info "Inafanya Upgrade ya haraka kwenda v2.0..."
  deploy_files_and_services
  ok "Upgrade ya v2.0 imekamilika kikamilifu!"
  exit 0
fi

########################################
# 6. MAHOJIANO NA UTHIBITISHAJI (INTERACTIVE SETUP)
########################################
printf "\n${BOLD}============================================================${NC}\n"
printf "${BOLD}   CLOUDFLARE FAILOVER & TELEGRAM BOT v2.0 - USAKINISHAJI   ${NC}\n"
printf "${BOLD}============================================================${NC}\n\n"

prompt_input() {
  local prompt_text="$1"
  local default_val="$2"
  local is_secret="${3:-0}"
  local input_val=""

  if [[ -n "$default_val" ]]; then
    if (( is_secret == 1 )); then
      local masked="${default_val:0:4}****${default_val: -4}"
      read -r -p "${prompt_text} [${masked}]: " input_val
    else
      read -r -p "${prompt_text} [${default_val}]: " input_val
    fi
    printf '%s' "${input_val:-$default_val}"
  else
    while [[ -z "$input_val" ]]; do
      read -r -p "${prompt_text}: " input_val
    done
    printf '%s' "$input_val"
  fi
}

# --- HATUA YA 1: CLOUDFLARE API & ZONE ---
while true; do
  CF_API_TOKEN="$(prompt_input "1. Ingiza Cloudflare API Token (yenye ruhusa ya DNS Edit)" "$CF_API_TOKEN" 1)"

  info "Inahakiki Cloudflare API Token na kutafuta Zones..."
  zones_resp=$(curl -sS --connect-timeout 5 --max-time 10 \
    -H "Content-Type: application/json" \
    --config - <<EOF 2>/dev/null || true
url = "https://api.cloudflare.com/client/v4/zones?per_page=50"
header = "Authorization: Bearer ${CF_API_TOKEN}"
EOF
  )

  if jq -e '.success == true' <<< "$zones_resp" >/dev/null 2>&1; then
    zone_count=$(jq -r '.result | length' <<< "$zones_resp")
    if (( zone_count == 1 )) && [[ -z "$CF_ZONE_ID" ]]; then
      CF_ZONE_ID=$(jq -r '.result[0].id' <<< "$zones_resp")
      zone_name=$(jq -r '.result[0].name' <<< "$zones_resp")
      ok "Imegundua Zone moja kiotomatiki: ${zone_name} (${CF_ZONE_ID})"
    elif (( zone_count > 1 )); then
      printf "\n${CYAN}Zones zilizopatikana kwenye akaunti yako:${NC}\n"
      jq -r '.result[] | "  • \(.name)  ->  Zone ID: \(.id)"' <<< "$zones_resp"
      printf "\n"
    fi
  fi

  CF_ZONE_ID="$(prompt_input "2. Ingiza Cloudflare Zone ID" "$CF_ZONE_ID" 0)"

  # Hakiki Zone ID
  zone_check=$(curl -sS --connect-timeout 5 --max-time 10 \
    -H "Content-Type: application/json" \
    --config - <<EOF 2>/dev/null || true
url = "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}"
header = "Authorization: Bearer ${CF_API_TOKEN}"
EOF
  )

  if jq -e '.success == true' <<< "$zone_check" >/dev/null 2>&1; then
    ZONE_DOMAIN=$(jq -r '.result.name // "domain.com"' <<< "$zone_check")
    ok "Cloudflare imeunganishwa kikamilifu! (Domain Kuu: ${ZONE_DOMAIN})"
    break
  else
    err "Imeshindikana kuunganisha na Zone ID '${CF_ZONE_ID}'. Hakikisha Token ina ruhusa ya Zone:DNS:Edit."
    CF_API_TOKEN=""
    CF_ZONE_ID=""
  fi
done

# --- HATUA YA 2: CONFIG TXT RECORD & AUTO-DISCOVERY ---
default_cfg_rec="${CONFIG_RECORD_NAME:-_cf-failover.${ZONE_DOMAIN}}"
CONFIG_RECORD_NAME="$(prompt_input "3. Jina la TXT Record ya kuhifadhi mipangilio ya pamoja" "$default_cfg_rec" 0)"

info "Inakagua kama kuna mipangilio iliyopo kwenye TXT record (${CONFIG_RECORD_NAME})..."
txt_resp=$(curl -sS --connect-timeout 5 --max-time 10 \
  -H "Content-Type: application/json" \
  --config - <<EOF 2>/dev/null || true
url = "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=${CONFIG_RECORD_NAME}"
header = "Authorization: Bearer ${CF_API_TOKEN}"
EOF
)

existing_txt=$(jq -r '.result[0].content // empty' <<< "$txt_resp" 2>/dev/null || true)
existing_txt="${existing_txt#\"}"
existing_txt="${existing_txt%\"}"

if [[ -n "$existing_txt" ]]; then
  ok "Mipangilio ya Cluster imepatikana kwenye Cloudflare: ${existing_txt}"
  IFS=';' read -r -a kv_parts <<< "$existing_txt"
  for part in "${kv_parts[@]}"; do
    k="${part%%=*}"
    v="${part#*=}"
    case "$k" in
      PRIORITY|NODE_PRIORITY) [[ -n "$v" ]] && NODE_PRIORITY="$v" ;;
      RECORDS|TARGET_RECORDS) [[ -n "$v" ]] && TARGET_RECORDS="$v" ;;
    esac
  done
  info "Imepakia kiotomatiki -> Nodes: [${NODE_PRIORITY:-Tupu}] | Domains: [${TARGET_RECORDS:-Tupu}]"
else
  info "Hakuna TXT record ya zamani iliyopatikana. Hii inaonekana ni server ya kwanza kwenye Cluster."
fi

# Tambua IP ya server hii
MY_PUBLIC_IP=$(curl -4 -sS --connect-timeout 4 --max-time 5 https://api.ipify.org 2>/dev/null || \
               curl -4 -sS --connect-timeout 4 --max-time 5 https://ifconfig.me 2>/dev/null || true)

if [[ -n "$MY_PUBLIC_IP" ]]; then
  info "Public IP ya server hii imegunduliwa: ${MY_PUBLIC_IP}"
  if [[ ",${NODE_PRIORITY}," != *",${MY_PUBLIC_IP},"* ]]; then
    read -r -p "   Je, ungependa kuongeza IP ya server hii (${MY_PUBLIC_IP}) kwenye NODE_PRIORITY? [Y/n]: " add_my_ip
    if [[ -z "$add_my_ip" || "${add_my_ip,,}" == "y" || "${add_my_ip,,}" == "yes" ]]; then
      if [[ -n "$NODE_PRIORITY" ]]; then
        NODE_PRIORITY="${NODE_PRIORITY},${MY_PUBLIC_IP}"
      else
        NODE_PRIORITY="${MY_PUBLIC_IP}"
      fi
    fi
  fi
fi

read -r -p "4. Orodha ya IP za Nodes kwa mpangilio ( unaweza kuacha tupu na kuongeza kwa Bot ) [${NODE_PRIORITY:-Tupu}]: " in_prio
[[ -n "$in_prio" ]] && NODE_PRIORITY="${in_prio// /}"

read -r -p "5. Domains zinazolindwa (mfano: cdn1.${ZONE_DOMAIN},cdn2.${ZONE_DOMAIN}) [${TARGET_RECORDS:-Tupu}]: " in_recs
[[ -n "$in_recs" ]] && TARGET_RECORDS="${in_recs// /}"

# --- HATUA YA 3: MIPANGILIO YA HEALTH CHECK ---
CHECK_METHOD="$(prompt_input "6. Njia ya kukagua afya ya Nodes (tcp / https / http)" "$CHECK_METHOD" 0)"
CHECK_METHOD="${CHECK_METHOD,,}"
CHECK_PORT="$(prompt_input "7. Port ya kukagua (mfano: 443 au 80)" "$CHECK_PORT" 0)"

if [[ "$CHECK_METHOD" == "http" || "$CHECK_METHOD" == "https" ]]; then
  CHECK_SCHEME="$CHECK_METHOD"
  HEALTH_PATH="$(prompt_input "8. Health Check URL Path (mfano: / au /health)" "$HEALTH_PATH" 0)"
fi

# --- HATUA YA 4: TELEGRAM BOT TOKEN & CHAT ID ---
while true; do
  TELEGRAM_BOT_TOKEN="$(prompt_input "9. Ingiza Telegram Bot Token (kutoka @BotFather)" "$TELEGRAM_BOT_TOKEN" 1)"
  TELEGRAM_CHAT_ID="$(prompt_input "10. Ingiza Telegram Chat ID yako" "$TELEGRAM_CHAT_ID" 0)"

  info "Inatuma ujumbe wa majaribio kwenye Telegram..."
  test_kb='{"keyboard":[[{"text":"🔄 Refresh"},{"text":"📋 Orodha Nodes"},{"text":"📄 Orodha Domains"}],[{"text":"➕ Ongeza Node"},{"text":"➖ Ondoa Node"},{"text":"🎯 Weka Priority"}],[{"text":"🌐 Ongeza Domain"},{"text":"🗑️ Ondoa Domain"},{"text":"🧹 Safisha Marudio"}],[{"text":"ℹ️ Msaada"},{"text":"❌ Ghairi"}]],"resize_keyboard":true,"is_persistent":true}'

  tg_payload=$(jq -nc \
    --arg chat_id "$TELEGRAM_CHAT_ID" \
    --arg text "✅ *Cloudflare Failover v2.0 Imesakinishwa!*
🖥️ *Server IP:* \`${MY_PUBLIC_IP:-Unknown}\`
🌐 *Zone:* \`${ZONE_DOMAIN}\`

Tumia vitufe vya hapa chini kusimamia Nodes na Domains zako muda wowote." \
    --argjson reply_markup "$test_kb" \
    '{chat_id: $chat_id, text: $text, parse_mode: "Markdown", reply_markup: $reply_markup}')

  tg_resp=$(curl -sS --connect-timeout 5 --max-time 10 \
    -H "Content-Type: application/json" \
    --data "$tg_payload" \
    --config - <<EOF 2>/dev/null || true
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
EOF
  )

  if jq -e '.ok == true' <<< "$tg_resp" >/dev/null 2>&1; then
    ok "Ujumbe wa majaribio umetumwa kwenye Telegram yako kikamilifu!"
    break
  else
    tg_err=$(jq -r '.description // "Imeshindikana kuwasiliana na Telegram"' <<< "$tg_resp" 2>/dev/null || echo "Unknown Error")
    err "Kosa la Telegram: ${tg_err}"
    warn "Hakikisha umeanzisha mazungumzo na Bot wako (/start) na Chat ID ni sahihi."
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
  fi
done

########################################
# 7. KUHIFADHI CONFIG.ENV KWA USALAMA
########################################
info "Inahifadhi mipangilio kwenye ${CONFIG_FILE}..."
tmp_cfg="${CONFIG_FILE}.tmp.$$"

cat > "$tmp_cfg" <<EOF
# Cloudflare Failover v2.0 Configuration
# Faili hili lina siri muhimu (chmod 600)

CF_API_TOKEN="${CF_API_TOKEN}"
CF_ZONE_ID="${CF_ZONE_ID}"
CONFIG_RECORD_NAME="${CONFIG_RECORD_NAME}"

NODE_PRIORITY="${NODE_PRIORITY}"
TARGET_RECORDS="${TARGET_RECORDS}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

CHECK_METHOD="${CHECK_METHOD}"
CHECK_PORT="${CHECK_PORT}"
CHECK_SCHEME="${CHECK_SCHEME}"
HEALTH_PATH="${HEALTH_PATH}"
CHECK_TIMEOUT="${CHECK_TIMEOUT}"
CURL_TIMEOUT="${CURL_TIMEOUT}"
DNS_TTL="${DNS_TTL}"
DEFAULT_PROXIED="${DEFAULT_PROXIED}"

CF_TG_HEARTBEAT_INTERVAL="${CF_TG_HEARTBEAT_INTERVAL}"
CF_TG_LEADER_TTL="${CF_TG_LEADER_TTL}"
EOF

chmod 600 "$tmp_cfg"
mv -f "$tmp_cfg" "$CONFIG_FILE"
ok "Faili la ${CONFIG_FILE} limehifadhiwa kwa ulinzi wa chmod 600."

########################################
# 8. KUWASHA HUDUMA NA KUSASISHA CLOUDFLARE TXT
########################################
deploy_files_and_services

# Hifadhi NODE_PRIORITY na TARGET_RECORDS kwenye Cloudflare TXT kama zimewekwa
if [[ -n "$NODE_PRIORITY" || -n "$TARGET_RECORDS" ]]; then
  info "Inasasisha mipangilio ya pamoja kwenye Cloudflare TXT (${CONFIG_RECORD_NAME})..."
  (
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    # shellcheck disable=SC1090
    source "${INSTALL_DIR}/cf-failover-lib.sh"
    save_shared_config && ok "Cloudflare TXT imesasishwa!" || warn "Imeshindikana kusasisha Cloudflare TXT kwa sasa."
  )
fi

printf "\n${GREEN}${BOLD}============================================================${NC}\n"
printf "${GREEN}${BOLD}   🎉 USAKINISHAJI WA v2.0 UMEKAMILIKA KIKAMILIFU!          ${NC}\n"
printf "${GREEN}${BOLD}============================================================${NC}\n"
printf " • Kuangalia logi za Bot moja kwa moja:\n"
printf "   ${CYAN}sudo journalctl -u cf-telegram-bot -f${NC}\n\n"
printf " • Kuangalia logi za Health Check / Failover:\n"
printf "   ${CYAN}sudo journalctl -u cf-failover -f${NC}\n\n"
printf " • Kusasisha scripts pekee siku za usoni:\n"
printf "   ${CYAN}sudo bash install.sh --upgrade${NC}\n\n"
