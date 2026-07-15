#!/bin/bash
#
# cf-failover-lib.sh
#
# Maktaba (library) inayoshirikiwa na SCRIPT MBILI tofauti:
#   1. cf-failover.sh       -> inakimbia kila dakika 1 kupitia cron
#                              (health-check + DNS failover TU)
#   2. cf-telegram-bot.sh   -> huduma ya systemd inayosikiliza Telegram
#                              muda wote (amri za /addip n.k., papo hapo)
#
# Faili hii haikimbizwi peke yake - ni lazima 'source'-iwe na moja ya
# script mbili hapo juu. Kusudi lake ni kuepusha kunakili msimbo mara
# mbili (Cloudflare API calls, uthibitishaji wa IP/domain, n.k.) na
# kuhakikisha zote mbili zinatumia mantiki ile ile kabisa.

########################################
# LOG
########################################
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

########################################
# TELEGRAM - KUTUMA UJUMBE
########################################
notify_telegram() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0   # arifa hazijawekwa, ruka kimya
  fi
  local response
  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=Markdown" 2>/dev/null)

  if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    # Ujumbe una alama za Markdown zisizolingana (_, *, `) - Telegram
    # inakataa kutuma kimya kimya. Jaribu tena BILA parse_mode ili
    # ujumbe ufike kwa hali yoyote, badala ya kupotea kabisa.
    response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" 2>/dev/null)
    if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
      log "ONYO: Kutuma Telegram alert kumeshindikana kabisa. Response: $response"
      return 1
    fi
  fi
  return 0
}

# Muundo wa keyboard - vitufe vinavyoonekana chini ya uwanja wa kuandika
MAIN_KEYBOARD_JSON='{"keyboard":[["➕ Ongeza Node","➖ Ondoa Node"],["🎯 Weka Priority","📋 Orodha Nodes"],["🌐 Ongeza Domain","🗑️ Ondoa Domain"],["📄 Orodha Domains","🔄 Refresh"],["ℹ️ Msaada"]],"resize_keyboard":true}'

notify_telegram_kb() {
  local message="$1"
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi
  local response
  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "reply_markup=${MAIN_KEYBOARD_JSON}" 2>/dev/null)

  if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" \
      --data-urlencode "reply_markup=${MAIN_KEYBOARD_JSON}" 2>/dev/null)
    if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
      log "ONYO: Kutuma Telegram alert (na keyboard) kumeshindikana kabisa. Response: $response"
      return 1
    fi
  fi
  return 0
}

########################################
# HEALTH CHECK (node moja)
########################################
check_node() {
  local ip="$1"
  if [[ "$CHECK_METHOD" == "http" ]]; then
    local code
    code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time "${CHECK_TIMEOUT:-5}" \
      "${CHECK_SCHEME}://${ip}:${CHECK_PORT}${HEALTH_PATH}" 2>/dev/null || echo "000")
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]
  else
    timeout "${CHECK_TIMEOUT:-5}" bash -c "cat < /dev/null > /dev/tcp/${ip}/${CHECK_PORT}" 2>/dev/null
  fi
}

# Inaangalia node ZOTE za NODE_PRIORITY sasa hivi (live), na kujaza:
#   PRIORITY_ARR, NODE_STATUS_ARR, DESIRED_IP
# Inatumika na cron (kwa failover) NA na bot (kwa /refresh ya papo hapo).
health_check_all() {
  IFS=',' read -ra PRIORITY_ARR <<< "$NODE_PRIORITY"
  NODE_STATUS_ARR=()
  DESIRED_IP=""
  local ip
  for ip in "${PRIORITY_ARR[@]}"; do
    if check_node "$ip"; then
      NODE_STATUS_ARR+=("1")
      [[ -z "$DESIRED_IP" ]] && DESIRED_IP="$ip"
    else
      NODE_STATUS_ARR+=("0")
    fi
  done
}

# Inatengeneza ujumbe wa ripoti kutoka PRIORITY_ARR/NODE_STATUS_ARR/DESIRED_IP
# zilizopo tayari (haifanyi health-check upya - tumia health_check_all kabla
# kama data hiyo bado haipo).
format_status_report() {
  local report="📊 *CF-Failover — Ripoti ya Hali*
━━━━━━━━━━━━━━━"
  local idx=1 ip
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
  echo "$report"
}

# Ripoti ya PAPO HAPO - inafanya health-check yake yenyewe (haitegemei cron).
# Hii ndiyo inayotumiwa na bot kwa /refresh, /status, na kitufe "🔄 Refresh"
# ili jibu lipatikane ndani ya sekunde chache bila kusubiri run ya cron.
send_status_report_live() {
  health_check_all
  notify_telegram "$(format_status_report)"
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
# CLOUDFLARE API - DNS records za kawaida (A records za failover)
########################################
get_record_info() {
  local record_name="$1"
  local response
  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X GET \
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
  payload=$(jq -n --arg name "$record_name" --arg ip "$new_ip" --argjson ttl "${DNS_TTL:-60}" \
    '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:false}')

  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X POST \
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
  payload=$(jq -n --arg name "$record_name" --arg ip "$new_ip" --argjson ttl "${DNS_TTL:-60}" \
    '{type:"A",name:$name,content:$ip,ttl:$ttl,proxied:false}')

  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X PUT \
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
# TELEGRAM LEADER ELECTION - inaruhusu server ZOTE kuendesha
# cf-telegram-bot.sh (usanifu ule ule wa "hakuna server kuu"), lakini
# NODE MOJA TU ndiyo inayozungumza na Telegram kwa wakati mmoja
# (Telegram haikubali watumaji wawili wa getUpdates kwa token moja).
#
# Jinsi inavyofanya kazi: TXT record MOJA kwenye Cloudflare inashikilia
# "NODE_ID=<id>;TS=<epoch>" ya node inayoongoza sasa (heartbeat). Kila
# node isiyo kiongozi inaangalia record hii mara kwa mara; kiongozi
# akikaa kimya zaidi ya CF_TG_LEADER_TTL sekunde (amezima/amekufa),
# node ya kwanza kugundua inajitangaza kiongozi papo hapo - hakuna
# mtu wa kubofya chochote, inatokea kiotomatiki.
########################################
CF_TG_LEADER_TTL="${CF_TG_LEADER_TTL:-45}"      # sekunde - kiongozi akikaa kimya zaidi ya hii, anahesabiwa amekufa
CF_TG_HEARTBEAT_INTERVAL="${CF_TG_HEARTBEAT_INTERVAL:-15}"  # kila sekunde ngapi kiongozi anasasisha heartbeat yake
TG_LEADER_RECORD_ID=""
LEADER_NODE_ID=""
LEADER_TS=0

# Kitambulisho cha kudumu cha node hii - kinabaki kile kile hata baada
# ya reboot/restart, ili "uongozi" usibadilike bila sababu.
ensure_node_id() {
  local id_file="/etc/cf-failover/node-id"
  if [[ -f "$id_file" ]]; then
    NODE_ID="$(cat "$id_file")"
  else
    NODE_ID="$(hostname 2>/dev/null || echo node)-$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c6)"
    mkdir -p "$(dirname "$id_file")"
    echo "$NODE_ID" > "$id_file"
  fi
}

get_leader_info() {
  local response rid content
  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=${TG_LEADER_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  rid=$(echo "$response" | jq -r '.result[0].id // empty')
  content=$(echo "$response" | jq -r '.result[0].content // empty')
  TG_LEADER_RECORD_ID="$rid"
  LEADER_NODE_ID=$(echo "$content" | grep -o 'NODE_ID=[^;]*' | cut -d= -f2- || true)
  LEADER_TS=$(echo "$content" | grep -o 'TS=[0-9]*' | cut -d= -f2- || echo 0)
  [[ -z "$LEADER_TS" ]] && LEADER_TS=0
}

# Node hii inajitangaza (au inathibitisha) kuwa kiongozi sasa hivi.
claim_leadership() {
  local now content payload response
  now=$(date +%s)
  content="NODE_ID=${NODE_ID};TS=${now}"
  payload=$(jq -n --arg name "$TG_LEADER_RECORD_NAME" --arg content "$content" \
    '{type:"TXT",name:$name,content:$content,ttl:60}')

  if [[ -z "$TG_LEADER_RECORD_ID" ]]; then
    response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X POST \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload")
    TG_LEADER_RECORD_ID=$(echo "$response" | jq -r '.result.id // empty')
  else
    response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X PUT \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${TG_LEADER_RECORD_ID}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload")
  fi

  if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    LEADER_NODE_ID="$NODE_ID"
    LEADER_TS="$now"
    return 0
  else
    log "ERROR: Kuandika leader record kumeshindikana. Response: $response"
    return 1
  fi
}

# Inarudisha 0 (kweli) kama node HII ndiyo kiongozi wa sasa (kwa
# kuangalia heartbeat halisi kutoka Cloudflare, siyo kumbukumbu ya ndani).
am_i_leader() {
  get_leader_info
  local now
  now=$(date +%s)
  if [[ "$LEADER_NODE_ID" == "$NODE_ID" ]] && (( now - LEADER_TS <= CF_TG_LEADER_TTL )); then
    return 0
  fi
  if [[ -z "$LEADER_NODE_ID" ]] || (( now - LEADER_TS > CF_TG_LEADER_TTL )); then
    # Hakuna kiongozi, au kiongozi wa zamani amekaa kimya muda mrefu -
    # node hii inachukua nafasi papo hapo.
    if claim_leadership; then
      log "Node hii (${NODE_ID}) imekuwa KIONGOZI wa huduma ya Telegram."
      return 0
    fi
  fi
  return 1
}

########################################
# SHARED CONFIG (NODE_PRIORITY / TARGET_RECORDS) - TXT record moja
# kwenye Cloudflare, inayosomwa na server ZOTE kila run.
########################################
SHARED_CONFIG_RECORD_ID=""

get_shared_config() {
  local response rid content
  response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=TXT&name=${CONFIG_RECORD_NAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  rid=$(echo "$response" | jq -r '.result[0].id // empty')
  content=$(echo "$response" | jq -r '.result[0].content // empty')
  SHARED_CONFIG_RECORD_ID="$rid"

  if [[ -z "$rid" ]]; then
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
    response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X POST \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$payload")
    SHARED_CONFIG_RECORD_ID=$(echo "$response" | jq -r '.result.id // empty')
  else
    response=$(curl -s --connect-timeout 5 --max-time "${CURL_TIMEOUT:-10}" --retry 1 --retry-delay 1 -X PUT \
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
# AMRI ZA KUBADILI CONFIG (addip, removeip, n.k.)
# Zinatumika na cf-telegram-bot.sh PEKEE (hizi ndizo amri za mtumiaji).
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
  local d="${1,,}"
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
  local d="${1,,}"
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
  notify_telegram_kb "🤖 *CF-Failover*
━━━━━━━━━━━━━━━
Tumia vitufe hapo chini, au amri za maandishi:

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
