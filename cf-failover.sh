#!/bin/bash
#
# cf-failover.sh
# Automatic health-check + Cloudflare DNS failover (Premium Edition)
# Inasaidia: priority list ya nodes (2+), domain records kadhaa (1+),
# lock file, arifa za Telegram zenye Latency + Server Stats, na TCP/HTTP health check.

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
STATE_FILE="/etc/cf-failover/state.env"
mkdir -p "$(dirname "$STATE_FILE")"
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
DNS_TTL="${DNS_TTL:-30}"

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
  curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    -d "parse_mode=Markdown" >/dev/null 2>&1 || log "ONYO: Kutuma Telegram alert kumeshindikana"
}

########################################
# HEALTH CHECK & LATENCY CALCULATION
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

get_latency() {
  local ip="$1"
  local t
  if [[ "$CHECK_METHOD" == "http" ]]; then
    t=$(curl -k -s -o /dev/null -w '%{time_total}' --max-time 2 "${CHECK_SCHEME}://${ip}:${CHECK_PORT}${HEALTH_PATH}" 2>/dev/null || echo "0")
  else
    t=$(curl -s -o /dev/null -w '%{time_connect}' --max-time 2 "telnet://${ip}:${CHECK_PORT}" 2>/dev/null || echo "0")
  fi

  if [[ "$t" == "0" || "$t" == "0.000000" || "$t" == "0.000" ]]; then
    echo "Timeout"
  elif [[ "$t" =~ ^0\.([0-9]{3}) ]]; then
    local ms="${BASH_REMATCH[1]}"
    echo "$((10#$ms))ms"
  elif [[ "$t" =~ ^([0-9]+)\.([0-9]{3}) ]]; then
    local sec="${BASH_REMATCH[1]}"
    local milli="${BASH_REMATCH[2]}"
    echo "$((sec * 1000 + 10#$milli))ms"
  else
    echo "${t}s"
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
    TELEGRAM_OFFSET=0
    PREV_NODE_STATUS=""
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
FAIL_COUNT=$FAIL_COUNT
ALL_DOWN_NOTIFIED=$ALL_DOWN_NOTIFIED
LAST_REPORT_EPOCH=$LAST_REPORT_EPOCH
TELEGRAM_OFFSET=${TELEGRAM_OFFSET:-0}
PREV_NODE_STATUS="${NODE_STATUS_JOINED:-${PREV_NODE_STATUS:-}}"
EOF
}

########################################
# CLOUDFLARE API
########################################
get_record_info() {
  local record_name="$1"
  local response
  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  local rid
  local rip
  rid=$(echo "$response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*' | head -1 | cut -d'"' -f4)
  rip=$(echo "$response" | grep -o '"content"[[:space:]]*:[[:space:]]*"[^"]*' | head -1 | cut -d'"' -f4)
  echo "${rid}|${rip}"
}

create_dns() {
  local record_name="$1"
  local new_ip="$2"

  local response
  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"${record_name}\",\"content\":\"${new_ip}\",\"ttl\":${DNS_TTL},\"proxied\":false}")

  if echo "$response" | grep -q '"success":true'; then
    log "${record_name} imetengenezwa mpya ikielekeza ${new_ip}"
    return 0
  else
    log "ERROR: Kutengeneza ${record_name} kumeshindikana. Response: $response"
    return 1
  fi
}

upsert_dns() {
  local record_name="$1"
  local record_id="$2"
  local new_ip="$3"

  if [[ -z "$record_id" ]]; then
    create_dns "$record_name" "$new_ip"
    return $?
  fi

  local response
  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"${record_name}\",\"content\":\"${new_ip}\",\"ttl\":${DNS_TTL},\"proxied\":false}")

  if echo "$response" | grep -q '"success":true'; then
    log "${record_name} imebadilishwa kuelekeza ${new_ip}"
    return 0
  else
    log "ERROR: Kubadilisha ${record_name} kumeshindikana. Response: $response"
    return 1
  fi
}

########################################
# STATUS REPORT (PREMIUM INTERFACE)
########################################
send_status_report() {
  # Kusoma Resource za Server ya sasa
  local cpu_load ram_info
  cpu_load=$(cat /proc/loadavg 2>/dev/null | cut -d' ' -f1 || echo "N/A")
  ram_info=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%d / %d MB", $3, $2}' || echo "N/A")

  local report="📊 *CF-FAILOVER — RIPOTI YA HALI*
━━━━━━━━━━━━━━━━━━"
  
  local idx=1
  for ip in "${PRIORITY_ARR[@]}"; do
    if [[ "${NODE_STATUS_ARR[$((idx-1))]}" == "1" ]]; then
      local latency
      latency=$(get_latency "$ip")
      report="${report}
✅ *Node ${idx}* (\`${ip}\`)
├─ Hali: \`Iko Hai\`
└─ Kasi: \`${latency}\`"
    else
      report="${report}
❌ *Node ${idx}* (\`${ip}\`)
└─ Hali: \`Haipatikani\`"
    fi
    report="${report}
"
    idx=$((idx + 1))
  done

  report="${report}━━━━━━━━━━━━━━━━━━
🎯 *Inayotumika:* \`${DESIRED_IP}\`

🖥️ *Afya ya Server Hii:*
├─ CPU Load: \`${cpu_load}\`
└─ RAM Usage: \`${ram_info}\`

🕒 *Muda:* $(date '+%H:%M:%S | %d-%m-%Y')"
  notify_telegram "$report"
}

########################################
# TELEGRAM COMMANDS (/refresh au /status)
########################################
REFRESH_REQUESTED=0
poll_telegram_commands() {
  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    return 0
  fi
  local offset=$(( ${TELEGRAM_OFFSET:-0} + 1 ))
  local response
  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${offset}&limit=20&timeout=0" 2>/dev/null) || return 0

  local max_update_id
  max_update_id=$( { echo "$response" | grep -o '"update_id":[0-9]*' | grep -o '[0-9]*' | sort -n | tail -1; } || true)
  if [[ -n "$max_update_id" ]]; then
    TELEGRAM_OFFSET="$max_update_id"
  fi

  if echo "$response" | grep -q "\"chat\":{\"id\":${TELEGRAM_CHAT_ID}" && \
     echo "$response" | grep -qi '"text":"\/refresh"\|"text":"\/status"'; then
    REFRESH_REQUESTED=1
  fi
}

########################################
# MAIN
########################################

load_state
poll_telegram_commands

IFS=',' read -ra PRIORITY_ARR <<< "$NODE_PRIORITY"
TOP_IP="${PRIORITY_ARR[0]}"

DESIRED_IP=""
NODE_STATUS_ARR=()
for ip in "${PRIORITY_ARR[@]}"; do
  if check_node "$ip"; then
    NODE_STATUS_ARR+=("1")
    [[ -z "$DESIRED_IP" ]] && DESIRED_IP="$ip"
  else
    NODE_STATUS_ARR+=("0")
  fi
done
TOP_IP_UP="${NODE_STATUS_ARR[0]}"
NODE_STATUS_JOINED=$(IFS=,; echo "${NODE_STATUS_ARR[*]}")

if [[ -n "${PREV_NODE_STATUS:-}" ]]; then
  IFS=',' read -ra PREV_STATUS_ARR <<< "$PREV_NODE_STATUS"
  idx=0
  for ip in "${PRIORITY_ARR[@]}"; do
    old_status="${PREV_STATUS_ARR[$idx]:-1}"
    new_status="${NODE_STATUS_ARR[$idx]}"
    if [[ "$old_status" != "$new_status" ]]; then
      TIMESTAMP=$(date '+%H:%M:%S | %d-%m-%Y')
      if [[ "$new_status" == "1" ]]; then
        local lat
        lat=$(get_latency "$ip")
        notify_telegram "🟢 *Node $((idx+1))* (\`${ip}\`) imerudi hewani!
⚡ Kasi: \`${lat}\`
🕒 ${TIMESTAMP}"
      else
        notify_telegram "🔴 *Node $((idx+1))* (\`${ip}\`) imeshuka!
🕒 ${TIMESTAMP}"
      fi
    fi
    idx=$((idx+1))
  done
fi

if [[ -z "$DESIRED_IP" ]]; then
  TIMESTAMP=$(date '+%H:%M:%S | %d-%m-%Y')
  log "ONYO: Node ZOTE hazirespondi!"
  if [[ "${ALL_DOWN_NOTIFIED:-0}" -eq 0 ]]; then
    notify_telegram "🚨🚨 *DHARURA* 🚨🚨
━━━━━━━━━━━━━━━━━━
Node ZOTE hazirespondi!
📍 \`${NODE_PRIORITY}\`
🕒 ${TIMESTAMP}
━━━━━━━━━━━━━━━━━━
❌ Hakuna DNS iliyobadilishwa
👉 Tafadhali angalia servers yako haraka"
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

if [[ "$TOP_IP_UP" -eq 0 ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  if [[ "$FAIL_COUNT" -eq 1 ]] || [[ "$FAIL_COUNT" -eq "$FAIL_THRESHOLD" ]]; then
    log "TOP priority node ($TOP_IP) hairespondi. Fail count: $FAIL_COUNT/$FAIL_THRESHOLD"
  fi
else
  FAIL_COUNT=0
fi

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
━━━━━━━━━━━━━━━━━━
🌐 Record: \`${record}\`
🔙 Imerudi: \`${DESIRED_IP}\` (top priority)
🕒 ${TIMESTAMP}
━━━━━━━━━━━━━━━━━━
Kila kitu kinaendelea sawa 🎉"
    else
      notify_telegram "🔁 *FAILOVER* — DNS imebadilishwa
━━━━━━━━━━━━━━━━━━
🌐 Record: \`${record}\`
📉 Kutoka: \`${current_ip:-haipo}\`
📈 Kwenda: \`${DESIRED_IP}\`
🕒 ${TIMESTAMP}
━━━━━━━━━━━━━━━━━━
⚠️ Node ya awali haijibu - inafuatiliwa"
    fi
  fi
done

if [[ "$REFRESH_REQUESTED" -eq 1 ]]; then
  send_status_report
  NOW_EPOCH=$(date '+%s')
  LAST_REPORT_EPOCH="$NOW_EPOCH"
elif [[ "$STATUS_REPORT_MINUTES" -gt 0 ]]; then
  NOW_EPOCH=$(date '+%s')
  ELAPSED_MIN=$(( (NOW_EPOCH - ${LAST_REPORT_EPOCH:-0}) / 60 ))
  if [[ "$ELAPSED_MIN" -ge "$STATUS_REPORT_MINUTES" ]]; then
    send_status_report
    LAST_REPORT_EPOCH="$NOW_EPOCH"
  fi
fi

save_state
