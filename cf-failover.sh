#!/bin/bash
#
# cf-failover.sh
# Health-check ya node + DNS failover kwenye Cloudflare - PEKEE.
#
# Script hii sasa HAISOMI TENA amri za Telegram (/addip, vitufe, n.k.) -
# kazi hiyo imehamishiwa kwenye 'cf-telegram-bot.sh', huduma tofauti
# (systemd) inayoendesha kwenye server zile zile, ikisikiliza muda
# wote na kujibu ndani ya sekunde 1-2 badala ya kusubiri run ya cron.
#
# Sababu ya mgawanyo: health-check + kubadili DNS lazima ibaki kila
# dakika 1 (kuifanya ya papo hapo kungesababisha DNS kubadilika kila
# node ikipepesuka kidogo [flap], na kuharibu utulivu wa mfumo) - lakini
# kusoma amri za Telegram hakuna sababu ya kusubiri dakika nzima, hivyo
# hiyo sasa ni huduma inayoendesha papo hapo, tofauti kabisa na hii.
#
# Weka script hii (pamoja na cf-failover-lib.sh) kwenye SERVER ZOTE
# (node zote) - kila moja inafanya health-check + failover kwa
# kujitegemea, ikisoma NODE_PRIORITY/TARGET_RECORDS ile ile kutoka
# Cloudflare TXT record kila run.

set -uo pipefail
# NOTA: 'set -e' imeondolewa kimakusudi - amri za mtandao (curl kwenda
# Cloudflare) zinaweza kushindwa mara kwa mara kwa sababu za muda tu.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/cf-failover/config.env"
LIB_FILE="${SCRIPT_DIR}/cf-failover-lib.sh"

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

# NOTA: NODE_PRIORITY na TARGET_RECORDS HAZIHITAJIKI tena kwenye
# config.env - zinasomwa MOJA KWA MOJA kutoka Cloudflare (get_shared_config,
# chini) kila run. VPS hii haihifadhi domain/IP yoyote yenyewe - unaziweka
# tu kupitia amri za Telegram baada ya usakinishaji.
for var in CF_API_TOKEN CF_ZONE_ID CONFIG_RECORD_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} haipo au haina thamani kwenye ${CONFIG_FILE}. Rekebisha kisha jaribu tena."
    exit 1
  fi
done
NODE_PRIORITY="${NODE_PRIORITY:-}"
TARGET_RECORDS="${TARGET_RECORDS:-}"

trap 'echo "$(date "+%Y-%m-%d %H:%M:%S") - ERROR: script imesimama bila kutarajiwa kwenye line $LINENO" >&2' ERR

########################################
# LOCK - kuzuia run mbili kwa wakati mmoja (kwenye server hii hii)
########################################
LOCK_FILE="/var/lock/cf-failover.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - Run nyingine bado inaendelea, ninaruka run hii."
  exit 0
fi

########################################
# DEFAULTS
########################################
STATE_FILE="/etc/cf-failover/state.env"
mkdir -p "$(dirname "$STATE_FILE")"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
CHECK_PORT="${CHECK_PORT:-443}"
CHECK_METHOD="${CHECK_METHOD:-tcp}"
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
STATUS_REPORT_MINUTES="${STATUS_REPORT_MINUTES:-360}"
DNS_TTL="${DNS_TTL:-60}"

# State ya health-check TU (TELEGRAM_OFFSET/PENDING_ACTION sasa ziko
# kwenye faili tofauti inayotumiwa na cf-telegram-bot.sh pekee).
FAIL_COUNT=0
ALL_DOWN_NOTIFIED=0
LAST_REPORT_EPOCH=0
PREV_NODE_STATUS=""

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
FAIL_COUNT=$FAIL_COUNT
ALL_DOWN_NOTIFIED=$ALL_DOWN_NOTIFIED
LAST_REPORT_EPOCH=$LAST_REPORT_EPOCH
PREV_NODE_STATUS="${NODE_STATUS_JOINED:-${PREV_NODE_STATUS:-}}"
EOF
}

trap 'save_state 2>/dev/null || true' EXIT

########################################
# MAIN
########################################
load_state
get_shared_config   # NODE_PRIORITY / TARGET_RECORDS kutoka Cloudflare (chanzo kimoja)

if [[ -z "$NODE_PRIORITY" || -z "$TARGET_RECORDS" ]]; then
  log "Hakuna node/domain iliyowekwa bado (NODE_PRIORITY/TARGET_RECORDS tupu kwenye Cloudflare). Tumia Telegram (Ongeza Node / Ongeza Domain) kuanzisha."
  exit 0
fi

health_check_all    # inajaza PRIORITY_ARR, NODE_STATUS_ARR, DESIRED_IP
TOP_IP="${PRIORITY_ARR[0]}"
TOP_IP_UP="${NODE_STATUS_ARR[0]}"
NODE_STATUS_JOINED=$(IFS=,; echo "${NODE_STATUS_ARR[*]}")

# Arifa za kila node ikibadilika hali (up<->down)
if [[ -n "${PREV_NODE_STATUS:-}" ]]; then
  IFS=',' read -ra PREV_STATUS_ARR <<< "$PREV_NODE_STATUS"
  idx=0
  for ip in "${PRIORITY_ARR[@]}"; do
    old_status="${PREV_STATUS_ARR[$idx]:-1}"
    new_status="${NODE_STATUS_ARR[$idx]}"
    if [[ "$old_status" != "$new_status" ]]; then
      TIMESTAMP=$(date '+%H:%M:%S | %d-%m-%Y')
      if [[ "$new_status" == "1" ]]; then
        notify_telegram "🟢 *Node $((idx+1))* (\`${ip}\`) imerudi hewani
🕒 ${TIMESTAMP}"
      else
        notify_telegram "🔴 *Node $((idx+1))* (\`${ip}\`) imeshuka
🕒 ${TIMESTAMP}"
      fi
    fi
    idx=$((idx+1))
  done
fi

save_state

if [[ -z "$DESIRED_IP" ]]; then
  TIMESTAMP=$(date '+%H:%M:%S | %d-%m-%Y')
  log "ONYO: Node ZOTE hazirespondi!"
  if [[ "${ALL_DOWN_NOTIFIED:-0}" -eq 0 ]]; then
    notify_telegram "🚨🚨 *DHARURA* 🚨🚨
━━━━━━━━━━━━━━━
Node ZOTE hazirespondi!
📍 \`${NODE_PRIORITY}\`
🕒 ${TIMESTAMP}
━━━━━━━━━━━━━━━
❌ Hakuna DNS iliyobadilishwa
👉 Tafadhali angalia servers zako haraka

_Arifa hii itatumwa tena tu ikiwa hali haitabadilika._"
    ALL_DOWN_NOTIFIED=1
  fi
  save_state
  exit 0
else
  if [[ "${ALL_DOWN_NOTIFIED:-0}" -eq 1 ]]; then
    notify_telegram "🟢 *NAFUU* — angalau node moja imerudi hewani (\`${DESIRED_IP}\`)"
    ALL_DOWN_NOTIFIED=0
    save_state
  fi
fi

if [[ "$TOP_IP_UP" -eq 0 ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  if [[ "$FAIL_COUNT" -eq 1 ]] || [[ "$FAIL_COUNT" -eq "$FAIL_THRESHOLD" ]]; then
    log "TOP priority node ($TOP_IP) hairespondi. Fail count: $FAIL_COUNT/$FAIL_THRESHOLD"
  fi
else
  FAIL_COUNT=0
fi
save_state

IFS=',' read -ra RECORDS_ARR <<< "$TARGET_RECORDS"
for record in "${RECORDS_ARR[@]}"; do
  info=$(get_record_info "$record")
  record_id="${info%%|*}"
  current_ip="${info##*|}"

  if [[ "$current_ip" == "$DESIRED_IP" ]]; then
    continue
  fi
  if [[ "$current_ip" == "$TOP_IP" ]] && [[ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]]; then
    continue
  fi

  log "${record}: ${current_ip:-haipo} -> ${DESIRED_IP}"
  if upsert_dns "$record" "$record_id" "$DESIRED_IP"; then
    TIMESTAMP=$(date '+%H:%M:%S | %d-%m-%Y')
    if [[ "$DESIRED_IP" == "$TOP_IP" ]]; then
      notify_telegram "✅ *RESTORED* — Node kuu imerudi hewani!
━━━━━━━━━━━━━━━
🌐 Record: \`${record}\`
🔙 Imerudi: \`${DESIRED_IP}\` (top priority)
🕒 ${TIMESTAMP}
━━━━━━━━━━━━━━━
Kila kitu kinaendelea sawa 🎉"
    else
      notify_telegram "🔁 *FAILOVER* — DNS imebadilishwa
━━━━━━━━━━━━━━━
🌐 Record: \`${record}\`
➡️ IP mpya: \`${DESIRED_IP}\`
🕒 ${TIMESTAMP}"
    fi
  fi
done

########################################
# STATUS REPORT ya ratiba (siyo /refresh - hiyo sasa inashughulikiwa
# papo hapo na cf-telegram-bot.sh moja kwa moja)
########################################
NOW_EPOCH=$(date +%s)
if [[ "$STATUS_REPORT_MINUTES" -gt 0 ]]; then
  ELAPSED_MIN=$(( (NOW_EPOCH - LAST_REPORT_EPOCH) / 60 ))
  if [[ "$ELAPSED_MIN" -ge "$STATUS_REPORT_MINUTES" ]]; then
    notify_telegram "$(format_status_report)"
    LAST_REPORT_EPOCH="$NOW_EPOCH"
  fi
fi

save_state
exit 0
