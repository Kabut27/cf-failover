#!/bin/bash
#
# cf-failover.sh
# Automatic health-check + Cloudflare DNS failover
#
# FIX (2026-07-15): Kabla, kama script ilisimama (crash) kwa sababu yoyote
# KABLA ya kufika mwishoni, TELEGRAM_OFFSET na PREV_NODE_STATUS havikuwa
# vinahifadhiwa - hivyo amri za Telegram (/addrecord, /addip n.k.) na
# arifa za "node imerudi hewani" zilikuwa zikirudiwa kila run (kila
# dakika) badala ya mara moja tu. Sasa TELEGRAM_OFFSET inahifadhiwa MARA
# MOJA baada ya kusoma ujumbe (kabla ya sehemu yoyote inayoweza kukwama),
# na kuna 'trap EXIT' inayohakikisha state inahifadhiwa hata script
# ikitoka mapema kwa sababu ya error.
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

set -uo pipefail
# NOTA: 'set -e' imeondolewa kimakusudi. Kwa script hii, amri nyingi za
# mtandao (curl kwenda Cloudflare/Telegram) zinaweza kushindwa mara kwa
# mara kwa sababu za muda (timeout, DNS blip). Kabla, 'set -e' ilisababisha
# script kusimama ghafla mahali popote ikiwa amri moja tu ingeshindwa,
# kabla ya kufika kwenye save_state() - matokeo yake state (TELEGRAM_OFFSET,
# PREV_NODE_STATUS) haikuhifadhiwa na kila kitu kilijirudia run ijayo.
# Sasa makosa yanashughulikiwa wazi (return codes / if-checks) kwenye kila
# function muhimu badala ya kutegemea 'set -e'.

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

# State ya awali (itabadilishwa na load_state)
FAIL_COUNT=0
ALL_DOWN_NOTIFIED=0
LAST_REPORT_EPOCH=0
TELEGRAM_OFFSET=0
PREV_NODE_STATUS=""
NODE_STATUS_JOINED=""

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
  fi
}

# save_state ya JUMLA - inahifadhi kila kitu (fail count, offset, prev status)
save_state() {
  cat > "$STATE_FILE" <<EOF
FAIL_COUNT=$FAIL_COUNT
ALL_DOWN_NOTIFIED=$ALL_DOWN_NOTIFIED
LAST_REPORT_EPOCH=$LAST_REPORT_EPOCH
TELEGRAM_OFFSET=${TELEGRAM_OFFSET:-0}
PREV_NODE_STATUS="${NODE_STATUS_JOINED:-${PREV_NODE_STATUS:-}}"
EOF
}

# FIX: save_offset - inahifadhi TELEGRAM_OFFSET PEKEE, mara tu baada ya
# kusoma ujumbe wa Telegram na KABLA ya sehemu yoyote ya DNS/Cloudflare
# inayoweza kukwama. Hii inazuia amri (/addip, /addrecord n.k.) kusomwa
# na kujibiwa tena na tena kama script itakwama baadaye kwenye run hiyo hiyo.
save_offset() {
  # Andika/badilisha state file bila kupoteza thamani nyingine zilizopo
  local tmp_fail="${FAIL_COUNT:-0}"
  local tmp_alldown="${ALL_DOWN_NOTIFIED:-0}"
  local tmp_report="${LAST_REPORT_EPOCH:-0}"
  local tmp_prev="${PREV_NODE_STATUS:-}"
  cat > "$STATE_FILE" <<EOF
FAIL_COUNT=$tmp_fail
ALL_DOWN_NOTIFIED=$tmp_alldown
LAST_REPORT_EPOCH=$tmp_report
TELEGRAM_OFFSET=${TELEGRAM_OFFSET:-0}
PREV_NODE_STATUS="${tmp_prev}"
EOF
}

# FIX: hakikisha state (hasa TELEGRAM_OFFSET) inahifadhiwa hata script
# ikitoka ghafla (error yoyote isiyotarajiwa) kabla ya kufika mwisho.
trap 'save_state 2>/dev/null || true' EXIT

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

    # FIX: sasisha TELEGRAM_OFFSET na uihifadhi MARA MOJA kwa kila ujumbe
    # unaosomwa (siyo mwishoni mwa script). Hivyo hata script ikikwama
    # baadaye (mfano wakati wa kuwasiliana na Cloudflare), ujumbe huu
    # hautasomwa tena run ijayo.
    if [[ -n "$uid" ]]; then
      TELEGRAM_OFFSET="$uid"
      save_offset
    fi

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
                         # (TELEGRAM_OFFSET tayari imehifadhiwa ndani ya function hii, mara moja kwa kila ujumbe)

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
TOP_IP_UP="${NODE_STATUS_AR