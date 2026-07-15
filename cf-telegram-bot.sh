#!/bin/bash
#
# cf-telegram-bot.sh
# Huduma inayosikiliza amri za Telegram MUDA WOTE (/addip, vitufe, n.k.)
# na kujibu ndani ya sekunde 1-2, badala ya kusubiri run ya cron.
#
# Kimbiza script hii (systemd service) kwenye SERVER ZOTE, sawa kabisa
# na cf-failover.sh - hakuna server "kuu". Kila node inaendesha huduma
# hii kwa kujitegemea, ikisoma/kuandika NODE_PRIORITY/TARGET_RECORDS
# kwenye TXT record ile ile ya Cloudflare kama kawaida.
#
# Inatumia 'long polling' (getUpdates?timeout=25) - ombi moja linabaki
# wazi hadi ujumbe mpya ufike (au sekunde 25 zipite), badala ya
# kuuliza kila baada ya dakika - ndiyo maana majibu yanakuja papo hapo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/cf-failover/config.env"
LIB_FILE="${SCRIPT_DIR}/cf-failover-lib.sh"
TELEGRAM_STATE_FILE="/etc/cf-failover/telegram-state.env"
OLD_STATE_FILE="/etc/cf-failover/state.env"   # kwa uhamisho wa TELEGRAM_OFFSET ya zamani

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file haipo. Kimbiza install.sh kwanza."
  exit 1
fi
if [[ ! -f "$LIB_FILE" ]]; then
  echo "ERROR: cf-failover-lib.sh haipo (inatarajiwa kwenye ${SCRIPT_DIR})."
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' haipo kwenye mfumo huu. Sakinisha kwa: apt-get install -y jq"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1090
source "$LIB_FILE"

for var in CF_API_TOKEN CF_ZONE_ID NODE_PRIORITY TARGET_RECORDS CONFIG_RECORD_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} haipo au haina thamani kwenye ${CONFIG_FILE}. Rekebisha kisha jaribu tena."
    exit 1
  fi
done

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID haziko kwenye ${CONFIG_FILE}."
  echo "Huduma hii haina maana bila hizo - haitaanza."
  exit 1
fi

CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
CHECK_PORT="${CHECK_PORT:-443}"
CHECK_METHOD="${CHECK_METHOD:-tcp}"
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
DNS_TTL="${DNS_TTL:-60}"

# Jina la TXT record ya "uongozi" wa Telegram - linatokana na
# CONFIG_RECORD_NAME ile ile uliyoweka wakati wa install.sh, hivyo
# halihitaji swali jipya kwa mtumiaji.
TG_LEADER_RECORD_NAME="tgleader.${CONFIG_RECORD_NAME}"
ensure_node_id

########################################
# LOCK - inazuia instance mbili za huduma hii kwenye node HII HII
# (mfano ukikimbiza script kwa mkono wakati systemd tayari inaiendesha)
########################################
LOCK_FILE="/var/lock/cf-telegram-bot.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "ERROR: cf-telegram-bot.sh tayari inaendesha (lock ipo). Ninatoka."
  exit 1
fi

########################################
# STATE - TELEGRAM_OFFSET na PENDING_ACTION PEKEE (faili tofauti na
# state ya health-check, ili script mbili zisigongane kuandika faili
# moja).
########################################
TELEGRAM_OFFSET=0
PENDING_ACTION=""

load_telegram_state() {
  if [[ -f "$TELEGRAM_STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TELEGRAM_STATE_FILE"
  elif [[ -f "$OLD_STATE_FILE" ]]; then
    # Uhamisho wa mara moja tu: toleo la zamani lilihifadhi TELEGRAM_OFFSET/
    # PENDING_ACTION kwenye state.env ile ile ya health-check.
    local old_offset old_pending
    old_offset=$(grep -o 'TELEGRAM_OFFSET=[0-9]*' "$OLD_STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
    old_pending=$(grep -o 'PENDING_ACTION="[^"]*"' "$OLD_STATE_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    [[ -n "$old_offset" ]] && TELEGRAM_OFFSET="$old_offset"
    [[ -n "$old_pending" ]] && PENDING_ACTION="$old_pending"
    log "Imehamisha TELEGRAM_OFFSET/PENDING_ACTION kutoka state.env ya zamani."
  fi
}

save_telegram_state() {
  mkdir -p "$(dirname "$TELEGRAM_STATE_FILE")"
  cat > "$TELEGRAM_STATE_FILE" <<EOF
TELEGRAM_OFFSET=${TELEGRAM_OFFSET:-0}
PENDING_ACTION="${PENDING_ACTION:-}"
EOF
}

trap 'save_telegram_state 2>/dev/null || true; log "cf-telegram-bot.sh inasimama (signal)."; exit 0' TERM INT

########################################
# VITUFE (Reply Keyboard) - vinavyohitaji taarifa ya ziada
########################################
prompt_pending() {
  local action="$1" question="$2"
  PENDING_ACTION="$action"
  save_telegram_state
  notify_telegram "$question"
}

handle_pending_reply() {
  local action="$1" value="$2"
  case "$action" in
    addip) handle_addip "$value" ;;
    removeip) handle_removeip "$value" ;;
    setpriority) handle_setpriority "$value" ;;
    addrecord) handle_addrecord "$value" ;;
    removerecord) handle_removerecord "$value" ;;
    *) : ;;
  esac
  PENDING_ACTION=""
  save_telegram_state
}

handle_menu_button() {
  local text="$1"
  case "$text" in
    "➕ Ongeza Node")
      prompt_pending "addip" "➕ Tuma IP ya node unayotaka kuongeza (mfano: 1.2.3.4)" ;;
    "➖ Ondoa Node")
      prompt_pending "removeip" "➖ Tuma IP ya node unayotaka kuondoa" ;;
    "🎯 Weka Priority")
      prompt_pending "setpriority" "🎯 Tuma orodha mpya ya IP kwa mpangilio (mfano: 3.3.3.3,2.2.2.2,1.1.1.1)" ;;
    "🌐 Ongeza Domain")
      prompt_pending "addrecord" "🌐 Tuma domain unayotaka kuongeza (mfano: cdn1.domain.com)" ;;
    "🗑️ Ondoa Domain")
      prompt_pending "removerecord" "🗑️ Tuma domain unayotaka kuondoa" ;;
    "📋 Orodha Nodes") handle_listips ;;
    "📄 Orodha Domains") handle_listrecords ;;
    "🔄 Refresh") send_status_report_live ;;
    "ℹ️ Msaada") handle_help ;;
    *) return 1 ;;
  esac
  return 0
}

handle_telegram_command() {
  local text="$1"
  local cmd arg1 arg2
  cmd=$(awk '{print tolower($1)}' <<< "$text")
  arg1=$(awk '{print $2}' <<< "$text")
  arg2=$(awk '{print $3}' <<< "$text")

  case "$cmd" in
    /refresh|/status) send_status_report_live ;;
    /addip)
      [[ -n "$arg1" ]] && handle_addip "$arg1" "$arg2" || notify_telegram "Tumia: /addip <ip> [nafasi]" ;;
    /removeip)
      [[ -n "$arg1" ]] && handle_removeip "$arg1" || notify_telegram "Tumia: /removeip <ip>" ;;
    /setpriority)
      [[ -n "$arg1" ]] && handle_setpriority "$arg1" || notify_telegram "Tumia: /setpriority <ip1,ip2,ip3>" ;;
    /listips) handle_listips ;;
    /addrecord)
      [[ -n "$arg1" ]] && handle_addrecord "$arg1" || notify_telegram "Tumia: /addrecord <domain>" ;;
    /removerecord)
      [[ -n "$arg1" ]] && handle_removerecord "$arg1" || notify_telegram "Tumia: /removerecord <domain>" ;;
    /listrecords) handle_listrecords ;;
    /help|/start) handle_help ;;
    *) : ;;  # amri isiyojulikana - puuza kimya
  esac
}

########################################
# TELEGRAM - LONG POLLING (jibu ndani ya sekunde 1-2)
########################################
poll_once() {
  local offset=$(( ${TELEGRAM_OFFSET:-0} + 1 ))
  local response
  # timeout=25: ombi hili linabaki wazi hadi ujumbe mpya ufike (au
  # sekunde 25 zipite bila ujumbe) - hii ndiyo inayofanya majibu kuwa
  # ya papo hapo badala ya kusubiri ratiba ya dakika.
  response=$(curl -s --connect-timeout 5 --max-time 30 \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${offset}&limit=20&timeout=25") || return 1

  echo "$response" | jq -e '.ok == true' >/dev/null 2>&1 || return 1

  local row uid chat_id text
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    uid=$(echo "$row" | jq -r '.update_id // empty')
    chat_id=$(echo "$row" | jq -r '.message.chat.id // empty')
    text=$(echo "$row" | jq -r '.message.text // empty')

    # Sasisha na uhifadhi offset MARA MOJA kwa kila ujumbe unaosomwa,
    # kabla ya kushughulikia (ili ujumbe usisomwe tena run/loop ijayo
    # kama kitu kitakwama wakati wa kushughulikia).
    if [[ -n "$uid" ]]; then
      TELEGRAM_OFFSET="$uid"
      save_telegram_state
    fi

    [[ -z "$chat_id" || "$chat_id" != "$TELEGRAM_CHAT_ID" ]] && continue
    [[ -z "$text" ]] && continue

    # Data ya NODE_PRIORITY/TARGET_RECORDS ibaki mpya kabla ya kila amri,
    # ikiwa server nyingine tayari imebadilisha kitu.
    get_shared_config

    if [[ -n "${PENDING_ACTION:-}" ]]; then
      handle_pending_reply "$PENDING_ACTION" "$text"
    elif handle_menu_button "$text"; then
      :
    else
      handle_telegram_command "$text"
    fi
  done < <(echo "$response" | jq -c '.result[]' 2>/dev/null || true)

  return 0
}

########################################
# MAIN LOOP - na "leader election"
#
# Node ZOTE zinaendesha huduma hii (kama ilivyoelezwa juu), lakini
# NODE MOJA TU ndiyo inayozungumza na Telegram (getUpdates) kwa wakati
# mmoja - Telegram haikubali watumaji wawili wa token moja kwa wakati
# mmoja (hutoa 409 Conflict na kusababisha majibu ya mara mbili/tatu au
# amri kukwama). Node zisizo kiongozi zinasubiri kimya, zikiangalia kila
# baada ya sekunde chache kama kiongozi bado "yuko hai" (heartbeat).
# Kiongozi akizima kwa sababu yoyote, node nyingine INACHUKUA NAFASI
# kiotomatiki ndani ya CF_TG_LEADER_TTL sekunde - hakuna hatua ya mkono.
########################################
log "cf-telegram-bot.sh imeanza. Node ID: ${NODE_ID}"
load_telegram_state
get_shared_config

while true; do
  if am_i_leader; then
    log "Ninaendesha huduma ya Telegram kama KIONGOZI (${NODE_ID})."
    last_heartbeat_ts=$(date +%s)
    while true; do
      if ! poll_once; then
        sleep 3
      fi
      now=$(date +%s)
      if (( now - last_heartbeat_ts >= CF_TG_HEARTBEAT_INTERVAL )); then
        if ! claim_leadership; then
          log "ONYO: Kusasisha heartbeat kumeshindikana - nitajaribu tena hivi karibuni."
        fi
        last_heartbeat_ts=$now
      fi
      # Endapo node nyingine imedai uongozi (nadra sana, lakini
      # inawezekana kama mtandao ulikatika kwa muda mrefu), acha
      # kuzungumza na Telegram mara moja ili kuepusha mgongano.
      if [[ "$LEADER_NODE_ID" != "$NODE_ID" ]]; then
        log "Node nyingine (${LEADER_NODE_ID}) imekuwa kiongozi - ninasubiri."
        break
      fi
    done
  else
    # Siyo kiongozi kwa sasa - subiri kimya (bila kuzungumza na Telegram)
    # kisha angalia tena kama kiongozi wa sasa bado yuko hai.
    sleep 5
  fi
done
