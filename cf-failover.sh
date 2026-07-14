#!/bin/bash
#
# cf-failover.sh
# Automatic health-check + Cloudflare DNS failover
#
# Sasa inasaidia: kuedit NODE_PRIORITY na TARGET_RECORDS moja kwa moja
# kupitia Telegram (/addip, /removeip, /setpriority, /addrecord,
# /removerecord, /listips, /listrecords, /help). Config hii inahifadhiwa
# kwenye TXT record MOJA kwenye Cloudflare (CONFIG_RECORD_NAME) - hivyo
# server ZOTE zinazoendesha script hii zinasoma config ile ile kila run,
# bila kujali ni server ipi iliyopokea amri ya Telegram.
#
# Weka script hii kwenye SERVER ZOTE (node zote) - kila moja inafanya kazi
# kwa kujitegemea, ikiangalia hali halisi ya DNS/config kwenye Cloudflare
# kila run.

set -euo pipefail

CONFIG_FILE="/etc/cf-failover/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file haipo. Kimbiza install.sh kwanza."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: 'jq' haipo kwenye mfumo huu. Sakinisha kwa: apt-get install -y jq"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Hakikisha fields muhimu zipo - kuzuia matatizo kimya kimya kama config
# imehaririwa kwa mkono na sehemu muhimu ikafutwa kimakosa
for var in CF_API_TOKEN CF_ZONE_ID NODE_PRIORITY TARGET_RECORDS CONFIG_RECORD_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} haipo au haina thamani kwenye ${CONFIG_FILE}. Rekebisha kisha jaribu tena."
    exit 1
  fi
done

# Onyesha wapi hasa script ilipovunjika, ikitokea (husaidia kwenye logs)
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
CHECK_METHOD="${CHECK_METHOD:-tcp}"        # tcp au http
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
STATUS_REPORT_MINUTES="${STATUS_REPORT_MINUTES:-360}"   # 0 = zima ripoti za mara kwa mara
DNS_TTL="${DNS_TTL:-60}"   # Cloudflare inahitaji kati ya 60-86400, au 1 kwa Automatic

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
# VALIDATION
########################################
is_valid_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local part
  for part in "${BASH_REMATCH[@]:1}"; do
    (( part <= 255 )) || return 1
  done
  return 0
}

is_valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

########################################
# STATE (fail-count, telegram offset, n.k. - hii ni ya LOKALI kwa server hii)
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
PREV_NODE_STATUS="${NODE_STATUS_JOINED:-}"
EOF
}

########################################
# CLOUDFLARE API - DNS records za kawaida (A records za failover)
########################################
get_record_info() {
  local record_name="$1"
  local response
  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  local rid rip
  rid=$(echo "$response" | jq -r '.result[0].id // empty')
  rip=$(echo "$response" | jq -r '.result[0].content // empty')
  echo "${rid}|${rip}"
}

create_dns() {
  local record_name="$1"
  local new_ip="$2"
  local payload response
  payload=$(jq -n --arg name "$record_name" --arg ip "$new_ip" --argjson ttl "$DNS_TTL" \
    '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:false}')

  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload")

  if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
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

  local payload response
  payload=$(jq -n --arg name "$record_name" --arg ip "$new_ip" --argjson ttl "$DNS_TTL" \
    '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:false}')

  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload")

  if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    log "${record_name} imebadilishwa kuelekeza ${new_ip}"
    return 0
  else
    log "ERROR: Kubadilisha ${record_name} kumeshindikana. Response: $response"
    return 1
  fi
}

########################################
# SHARED CONFIG (NODE_PRIORITY / TARGET_RECORDS) - imehifadhiwa kwenye
# Cloudflare TXT record moja, inayosomwa na server ZOTE kila run. Hii
# ndiyo inayowezesha /addip, /removeip n.k. kutumika kwa server nyingi
# bila kuhitaji kunakili config kwa mkono.
########################################
SHARED_CONFIG_RECORD_ID=""

get_shared_config() {
  local response rid content
  response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=${CONFIG_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  rid=$(echo "$response" | jq -r '.result[0].id // empty')
  content=$(echo "$response" | jq -r '.result[0].content // empty')
  SHARED_CONFIG_RECORD_ID="$rid"

  if [[ -z "$rid" ]]; then
    # Record haipo bado kwenye Cloudflare - itengeneze kwa kutumia
    # NODE_PRIORITY/TARGET_RECORDS za config.env kama thamani za awali
    log "Shared config record (${CONFIG_RECORD_NAME}) haipo bado - inatengenezwa kwa mara ya kwanza."
    save_shared_config
    return 0
  fi

  local np tr
  np=$(echo "$content" | grep -o 'NODE_PRIORITY=[^;]*' | cut -d= -f2- || true)
  tr=$(echo "$content" | grep -o 'TARGET_RECORDS=[^;]*' | cut -d= -f2- || true)
  [[ -n "$np" ]] && NODE_PRIORITY="$np"
  [[ -n "$tr" ]] && TARGET_RECORDS="$tr"
}

save_shared_config() {
  local content="NODE_PRIORITY=${NODE_PRIORITY};TARGET_RECORDS=${TARGET_RECORDS}"
  local payload response
  payload=$(jq -n --arg name "$CONFIG_RECORD_NAME" --arg content "$content" \
    '{type:"TXT",name:$name,content:$content,ttl:60}')

  if [[ -z "$SHARED_CONFIG_RECORD_ID" ]]; then
    response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X POST \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload")
    SHARED_CONFIG_RECORD_ID=$(echo "$response" | jq -r '.result.id // empty')
  else
    response=$(curl -s --connect-timeout 5 --max-time "$CURL_TIMEOUT" --retry 1 --retry-delay 1 -X PUT \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${SHARED_CONFIG_RECORD_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload")
  fi

  if ! echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    log "ERROR: Kuhifadhi shared config (${CONFIG_RECORD_NAME}) kumeshindikana. Response: $response"
    notify_telegram "⚠️ Kuhifadhi mabadiliko ya config kwenye Cloudflare kumeshindikana. Angalia logs."
  fi
}

########################################
# STATUS REPORT
########################################
send_status_report() {
  local report="📊 *CF-Failover — Ripoti ya Hali*
━━━━━━━━━━━━━━━"
  local idx=1
  for ip in "${PRIORITY_ARR[@]}"; do
    if [[ "${NODE_STATUS_ARR[$((idx-1))]:-0}" == "1" ]]; then
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
🎯 Inayotumika sasa: \`${DESIRED_IP:-hakuna}\`
🕒 $(date '+%H:%M:%S | %d-%m-%Y')"
  notify_telegram "$report"
}

########################################
# TELEGRAM - AMRI ZA KUBADILI CONFIG (addip, removeip, n.k.)
########################################
handle_addip() {
  local ip="$1" pos="${2:-}"
  if ! is_valid_ip "$ip"; then
    notify_telegram "❌ IP si sahihi: \`${ip}\`"
    return
  fi
  IFS=',' read -ra arr <<< "$NODE_PRIORITY"
  local existing
  for existing in "${arr[@]}"; do
    if [[ "$existing" == "$ip" ]]; then
      notify_telegram "⚠️ \`${ip}\` tayari ipo kwenye orodha."
      return
    fi
  done
  if [[ -n "$pos" && "$pos" =~ ^[0-9]+$ && "$pos" -ge 1 && "$pos" -le $((${#arr[@]}+1)) ]]; then
    arr=("${arr[@]:0:$((pos-1))}" "$ip" "${arr[@]:$((pos-1))}")
  else
    arr+=("$ip")
  fi
  NODE_PRIORITY=$(IFS=,; echo "${arr[*]}")
  save_shared_config
  notify_telegram "✅ Node imeongezwa: \`${ip}\`
📋 Priority mpya: \`${NODE_PRIORITY}\`"
}

handle_removeip() {
  local ip="$1"
  IFS=',' read -ra arr <<< "$NODE_PRIORITY"
  local newarr=() found=0 existing
  for existing in "${arr[@]}"; do
    if [[ "$existing" == "$ip" ]]; then found=1; continue; fi
    newarr+=("$existing")
  done
  if [[ "$found" -eq 0 ]]; then
    notify_telegram "⚠️ \`${ip}\` haipo kwenye orodha."
    return
  fi
  if [[ "${#newarr[@]}" -eq 0 ]]; then
    notify_telegram "❌ Haiwezekani kuondoa - lazima kuwe na node moja angalau."
    return
  fi
  NODE_PRIORITY=$(IFS=,; echo "${newarr[*]}")
  save_shared_config
  notify_telegram "✅ Node imeondolewa: \`${ip}\`
📋 Priority mpya: \`${NODE_PRIORITY}\`"
}

handle_setpriority() {
  local list="$1"
  IFS=',' read -ra arr <<< "$list"
  if [[ "${#arr[@]}" -eq 0 ]]; then
    notify_telegram "❌ Orodha haiwezi kuwa tupu."
    return
  fi
  local ip
  for ip in "${arr[@]}"; do
    if ! is_valid_ip "$ip"; then
      notify_telegram "❌ IP si sahihi: \`${ip}\` - hakuna kilichobadilishwa."
      return
    fi
  done
  NODE_PRIORITY="$list"
  save_shared_config
  notify_telegram "✅ Priority mpya imewekwa: \`${NODE_PRIORITY}\`"
}

handle_listips() {
  local msg="📋 *Node Priority (kwa mpangilio)*" idx=1 ip
  IFS=',' read -ra arr <<< "$NODE_PRIORITY"
  for ip in "${arr[@]}"; do
    msg="${msg}
${idx}. \`${ip}\`"
    idx=$((idx+1))
  done
  notify_telegram "$msg"
}

handle_addrecord() {
  local d="$1"
  if ! is_valid_domain "$d"; then
    notify_telegram "❌ Domain si sahihi: \`${d}\`"
    return
  fi
  IFS=',' read -ra arr <<< "$TARGET_RECORDS"
  local existing
  for existing in "${arr[@]}"; do
    if [[ "$existing" == "$d" ]]; then
      notify_telegram "⚠️ \`${d}\` tayari ipo kwenye orodha."
      return
    fi
  done
  arr+=("$d")
  TARGET_RECORDS=$(IFS=,; echo "${arr[*]}")
  save_shared_config
  notify_telegram "✅ Domain imeongezwa: \`${d}\`
📋 Records mpya: \`${TARGET_RECORDS}\`"
}

handle_removerecord() {
  local d="$1"
  IFS=',' read -ra arr <<< "$TARGET_RECORDS"
  local newarr=() found=0 existing
  for existing in "${arr[@]}"; do
    if [[ "$existing" == "$d" ]]; then found=1; continue; fi
    newarr+=("$existing")
  done
  if [[ "$found" -eq 0 ]]; then
    notify_telegram "⚠️ \`${d}\` haipo kwenye orodha."
    return
  fi
  if [[ "${#newarr[@]}" -eq 0 ]]; then
    notify_telegram "❌ Haiwezekani kuondoa - lazima kuwe na domain moja angalau."
    return
  fi
  TARGET_RECORDS=$(IFS=,; echo "${newarr[*]}")
  save_shared_config
  notify_telegram "✅ Domain imeondolewa: \`${d}\`
📋 Records mpya: \`${TARGET_RECORDS}\`"
}

handle_listrecords() {
  local msg="📋 *Domain Records*" idx=1 d
  IFS=',' read -ra arr <<< "$TARGET_RECORDS"
  for d in "${arr[@]}"; do
    msg="${msg}
${idx}. \`${d}\`"
    idx=$((idx+1))
  done
  notify_telegram "$msg"
}

handle_help() {
  notify_telegram "🤖 *CF-Failover — Amri za Telegram*
━━━━━━━━━━━━━━━
/addip <ip> [nafasi] — ongeza node
/removeip <ip> — ondoa node
/setpriority <ip1,ip2,ip3> — badilisha orodha yote
/listips — onyesha node zote
/addrecord <domain> — ongeza domain
/removerecord <domain> — ondoa domain
/listrecords — onyesha domain zote
/refresh au /status — ripoti ya papo hapo
/help — onyesha ujumbe huu"
}

handle_telegram_command() {
  local text="$1"
  local cmd arg1 arg2
  cmd=$(awk '{print tolower($1)}' <<< "$text")
  arg1=$(awk '{print $2}' <<< "$text")
  arg2=$(awk '{print $3}' <<< "$text")

  case "$cmd" in
    /refresh|/status) REFRESH_REQUESTED=1 ;;
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
# TELEGRAM - KUSOMA UJUMBE MPYA (poll)
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

  echo "$response" | jq -e '.ok == true' >/dev/null 2>&1 || return 0

  local row uid chat_id text
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    uid=$(echo "$row" | jq -r '.update_id // empty')
    chat_id=$(echo "$row" | jq -r '.message.chat.id // empty')
    text=$(echo "$row" | jq -r '.message.text // empty')

    [[ -n "$uid" ]] && TELEGRAM_OFFSET="$uid"

    [[ -z "$chat_id" || "$chat_id" != "$TELEGRAM_CHAT_ID" ]] && continue
    [[ -z "$text" ]] && continue

    handle_telegram_command "$text"
  done < <(echo "$response" | jq -c '.result[]' 2>/dev/null || true)
}

########################################
# MAIN
########################################

load_state
get_shared_config        # NODE_PRIORITY / TARGET_RECORDS kutoka Cloudflare (chanzo kimoja kwa server zote)
poll_telegram_commands   # inaweza kubadilisha na kuhifadhi NODE_PRIORITY/TARGET_RECORDS papo hapo

# NODE_PRIORITY: list ya IP kwa mpangilio - inaweza kuwa 2, 3, au zaidi
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

# Arifa za kila node ikibadilika hali (up<->down), siyo tu ile inayoathiri DNS
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

if [[ "$TOP_IP_UP" -eq 0 ]]; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  if [[ "$FAIL_COUNT" -eq 1 ]] || [[ "$FAIL_COUNT" -eq "$FAIL_THRESHOLD" ]]; then
    log "TOP priority node ($TOP_IP) hairespondi. Fail count: $FAIL_COUNT/$FAIL_THRESHOLD"
  fi
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
      notify_telegram "🔁 *FAILOVER* — DNS imebadilish