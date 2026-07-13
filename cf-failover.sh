#!/bin/bash
#
# cf-failover.sh
# Automatic health-check + Cloudflare DNS failover
# Inasaidia: priority list ya nodes (2+), domain records kadhaa (1+),
# lock file (kuzuia overlapping runs), arifa za Telegram, HTTP au TCP
# health check, na curl timeouts kuzuia kunasa (hang).
#
# Weka script hii kwenye SERVER ZOTE (node zote) - kila moja inafanya kazi
# kwa kujitegemea, ikiangalia hali halisi ya DNS kwenye Cloudflare kila run.

set -euo pipefail

CONFIG_FILE="/etc/cf-failover/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file haipo. Kimbiza install.sh kwanza."
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

########################################
# LOCK - kuzuia run mbili kwa wakati mmoja
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
STATE_FILE="/var/tmp/cf-failover-state"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
CHECK_PORT="${CHECK_PORT:-443}"
CHECK_METHOD="${CHECK_METHOD:-tcp}"        # tcp au http
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
STATUS_REPORT_MINUTES="${STATUS_REPORT_MINUTES:-360}"   # 0 = zima ripoti za mara kwa mara

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

########################################
# TELEGRAM ALERT
########################################
notify_telegram() {
  local message="$1"
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    return 0   # arifa hazijawekwa, ruka kimya
  fi
  curl -s --max-time "$CURL_TIMEOUT" -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=Markdown" >/dev/null 2>&1 || log "ONYO: Kutuma Telegram alert kumeshindikana"
}

########################################
# HEALTH CHECK
########################################
check_node() {
  local ip="$1"
  if [[ "$CHECK_METHOD" == "http" ]]; then
    local code
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time "$CHECK_TIMEOUT" \
      "${CHECK_SCHEME}://${ip}:${CHECK_PORT}${HEALTH_PATH}" 2>/dev/null || echo "000")
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]
  else
    timeout "$CHECK_TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/${ip}/${CHECK_PORT}" 2>/dev/null
  fi
}

########################################
# STATE
########################################
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    FAIL_COUNT=0
    ALL_DOWN_NOTIFIED=0
    LAST_REPORT_EPOCH=0
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
FAIL_COUNT=$FAIL_COUNT
ALL_DOWN_NOTIFIED=$ALL_DOWN_NOTIFIED
LAST_REPORT_EPOCH=$LAST_REPORT_EPOCH
EOF
}

########################################
# CLOUDFLARE API (imeunganishwa - call moja badala ya mbili)
########################################
# Inarudisha "record_id|current_ip" kwa record moja
get_record_info() {
  local record_name="$1"
  local response
  response=$(curl -s --max-time "$CURL_TIMEOUT" -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  local rid
  local rip
  rid=$(echo "$response" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
  rip=$(echo "$response" | grep -o '"content":"[^"]*' | head -1 | cut -d'"' -f4)
  echo "${rid}|${rip}"
}

update_dns() {
  local record_name="$1"
  local record_id="$2"
  local new_ip="$3"

  if [[ -z "$record_id" ]]; then
    log "ERROR: Imeshindwa kupata DNS record ID kwa ${record_name}"
    return 1
  fi

  local response
  response=$(curl -s --max-time "$CURL_TIMEOUT" -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"${record_name}\",\"content\":\"${new_ip}\",\"ttl\":60,\"proxied\":false}")

  if echo "$response" | grep -q '"success":true'; then
    log "${record_name} imebadilishwa kuelekeza ${new_ip}"
    return 0
  else
    log "ERROR: Kubadilisha ${record_name} kumeshindikana. Response: $response"
    return 1
  fi
}

########################################
# STATUS REPORT (mara kwa mara)
########################################
send_status_report() {
  local report="📊 *CF-Failover — Ripoti ya Hali*
━━━━━━━━━━━━━━━"
  local idx=1
  for ip in "${PRIORITY_ARR[@]}"; do
    if check_node "$ip"; then
      report="${report}
✅ Node ${idx} (\`${ip}\`) — Iko hai"
    else
      report="${report}
❌ Node ${idx} (\`${ip}\`) — Haipatikani"
    fi
    idx=$((idx + 1))
  done
  report="${report}
━━━━━━━━━━━━━━━
🎯 Inayotumika sasa: \`${DESIRED_IP}\`
🕒 $(date '+%H:%M:%S | %d-%m-%Y')"
  notify_telegram "$report"
}

########################################
# MAIN
########################################

load_state

# NODE_PRIORITY: list ya IP kwa mpangilio - inaweza kuwa 2, 3, au zaidi
IFS=',' read -ra PRIORITY_ARR <<< "$NODE_PRIORITY"
TOP_IP="${PRIORITY_ARR[0]}"

DESIRED_IP=""
for ip in "${PRIORITY_ARR[@]}"; do
  if check_node "$ip"; then
    DESIRED_IP="$ip"
    break
  fi
done

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
  fi
fi

if ! check_node "$TOP_IP"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "TOP priority node ($TOP_IP) hairespondi. Fail count: $FAIL_COUNT/$FAIL_THRESHOLD"
else
  FAIL_COUNT=0
fi

# TARGET_RECORDS: domain 1, 2, 3 au zaidi - comma separated
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
  if update_dns "$record" "$record_id" "$DESIRED_IP"; then
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
📉 Kutoka: \`${current_ip:-haipo}\`
📈 Kwenda: \`${DESIRED_IP}\`
🕒 ${TIMESTAMP}
━━━━━━━━━━━━━━━
⚠️ Node ya awali haijibu - inafuatiliwa"
    fi
  fi
done

# Ripoti ya mara kwa mara ya hali ya node zote (siyo tu wakati kuna mabadiliko)
if [[ "$STATUS_REPORT_MINUTES" -gt 0 ]]; then
  NOW_EPOCH=$(date '+%s')
  ELAPSED_MIN=$(( (NOW_EPOCH - ${LAST_REPORT_EPOCH:-0}) / 60 ))
  if [[ "$ELAPSED_MIN" -ge "$STATUS_REPORT_MINUTES" ]]; then
    send_status_report
    LAST_REPORT_EPOCH="$NOW_EPOCH"
  fi
fi

save_state
