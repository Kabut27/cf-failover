#!/bin/bash
#
# cf-failover-lib.sh (v2.0 Professional Edition)
# Maktaba kuu inayotumiwa na cf-failover.sh na cf-telegram-bot.sh

########################################
# 1. LOGGING & NODE IDENTITY
########################################
CF_TG_HEARTBEAT_INTERVAL="${CF_TG_HEARTBEAT_INTERVAL:-30}"
CF_TG_LEADER_TTL="${CF_TG_LEADER_TTL:-90}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
CHECK_PORT="${CHECK_PORT:-443}"
CHECK_METHOD="${CHECK_METHOD:-tcp}"
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
DNS_TTL="${DNS_TTL:-60}"
DEFAULT_PROXIED="${DEFAULT_PROXIED:-false}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

ensure_node_id() {
  local id_file="/etc/cf-failover/node-id"
  if [[ -n "${NODE_ID:-}" ]]; then
    return 0
  fi
  if [[ -f "$id_file" ]]; then
    NODE_ID="$(tr -d '[:space:]' < "$id_file")"
  fi
  if [[ -z "${NODE_ID:-}" ]]; then
    local host_part rand_part
    host_part="$(hostname -s 2>/dev/null | tr -cd 'a-zA-Z0-9_-' || echo "node")"
    rand_part="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    NODE_ID="${host_part}-${rand_part}"
    mkdir -p "$(dirname "$id_file")"
    printf '%s\n' "$NODE_ID" > "$id_file"
  fi
  export NODE_ID
}

########################################
# 2. VALIDATION HELPERS (PURE BASH)
########################################
is_valid_ip() {
  local ip="$1"
  local IFS='.'
  local -a octets
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
  done
  return 0
}

is_valid_domain() {
  local d="${1,,}"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
  return 0
}

########################################
# 3. SECURE CLOUDFLARE API ENGINE
########################################
# Inaficha CF_API_TOKEN isionekane kwenye 'ps aux' na inarudia mara 2 kukitokea hitilafu ya mtandao
cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local url="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}${endpoint}"
  local attempt=1 max_attempts=2 response=""

  while (( attempt <= max_attempts )); do
    if [[ -n "$data" ]]; then
      response=$(curl -sS --connect-timeout 5 --max-time "${CURL_TIMEOUT}" -X "$method" \
        -H "Content-Type: application/json" \
        --data "$data" \
        --config - <<EOF 2>/dev/null
url = "${url}"
header = "Authorization: Bearer ${CF_API_TOKEN}"
EOF
      ) && break
    else
      response=$(curl -sS --connect-timeout 5 --max-time "${CURL_TIMEOUT}" -X "$method" \
        -H "Content-Type: application/json" \
        --config - <<EOF 2>/dev/null
url = "${url}"
header = "Authorization: Bearer ${CF_API_TOKEN}"
EOF
      ) && break
    fi
    attempt=$(( attempt + 1 ))
    sleep 1
  done

  [[ -n "$response" ]] || return 1
  printf '%s' "$response"
}

########################################
# 4. SHARED CONFIG (CLOUDFLARE TXT RECORD)
########################################
update_txt_record() {
  local rec_name="$1"
  local content="$2"
  local resp rec_id payload

  resp=$(cf_api GET "/dns_records?type=TXT&name=${rec_name}") || return 1
  jq -e '.success == true' <<< "$resp" >/dev/null 2>&1 || return 1

  rec_id=$(jq -r '.result[0].id // empty' <<< "$resp")
  payload=$(jq -nc --arg name "$rec_name" --arg content "$content" \
    '{type:"TXT", name:$name, content:$content, ttl:60}')

  if [[ -n "$rec_id" ]]; then
    resp=$(cf_api PUT "/dns_records/${rec_id}" "$payload") || return 1
    # Futa marudio ya TXT record kama yapo
    local extra_ids
    extra_ids=$(jq -r '.result[1:][]?.id // empty' <<< "$resp" 2>/dev/null || true)
    local eid
    for eid in $extra_ids; do
      cf_api DELETE "/dns_records/${eid}" >/dev/null 2>&1 || true
    done
  else
    resp=$(cf_api POST "/dns_records" "$payload") || return 1
  fi

  jq -e '.success == true' <<< "$resp" >/dev/null 2>&1
}

get_shared_config() {
  local resp txt_val
  resp=$(cf_api GET "/dns_records?type=TXT&name=${CONFIG_RECORD_NAME}") || return 1
  jq -e '.success == true' <<< "$resp" >/dev/null 2>&1 || return 1

  txt_val=$(jq -r '.result[0].content // empty' <<< "$resp")
  txt_val="${txt_val#\"}"
  txt_val="${txt_val%\"}"

  if [[ -z "$txt_val" ]]; then
    # Kama TXT haipo bado Cloudflare, na tuna data kwenye config.env, ianzishe
    if [[ -n "${NODE_PRIORITY:-}" || -n "${TARGET_RECORDS:-}" ]]; then
      save_shared_config || true
    fi
    return 0
  fi

  # Format inayokubaliwa: PRIORITY=1.1.1.1,2.2.2.2;RECORDS=a.com,b.com
  local part key val
  IFS=';' read -r -a parts <<< "$txt_val"
  for part in "${parts[@]}"; do
    key="${part%%=*}"
    val="${part#*=}"
    case "$key" in
      PRIORITY|NODE_PRIORITY) NODE_PRIORITY="$val" ;;
      RECORDS|TARGET_RECORDS) TARGET_RECORDS="$val" ;;
    esac
  done
  export NODE_PRIORITY TARGET_RECORDS
  return 0
}

save_shared_config() {
  local content="PRIORITY=${NODE_PRIORITY:-};RECORDS=${TARGET_RECORDS:-}"
  update_txt_record "$CONFIG_RECORD_NAME" "$content"
}

########################################
# 5. DISTRIBUTED LEADER ELECTION (TELEGRAM)
########################################
claim_leadership() {
  ensure_node_id
  local now
  now=$(date +%s)
  if update_txt_record "$TG_LEADER_RECORD_NAME" "${NODE_ID}:${now}"; then
    LEADER_NODE_ID="$NODE_ID"
    return 0
  fi
  return 1
}

release_leadership() {
  ensure_node_id
  [[ -z "${TG_LEADER_RECORD_NAME:-}" ]] && return 0
  update_txt_record "$TG_LEADER_RECORD_NAME" "${NODE_ID}:0" >/dev/null 2>&1 || true
}

am_i_leader() {
  ensure_node_id
  local resp txt_val leader_id leader_ts now age

  resp=$(cf_api GET "/dns_records?type=TXT&name=${TG_LEADER_RECORD_NAME}") || return 1
  jq -e '.success == true' <<< "$resp" >/dev/null 2>&1 || return 1

  txt_val=$(jq -r '.result[0].content // empty' <<< "$resp")
  txt_val="${txt_val#\"}"
  txt_val="${txt_val%\"}"

  now=$(date +%s)

  if [[ -n "$txt_val" && "$txt_val" == *:* ]]; then
    leader_id="${txt_val%%:*}"
    leader_ts="${txt_val##*:}"
    [[ "$leader_ts" =~ ^[0-9]+$ ]] || leader_ts=0
    age=$(( now - leader_ts ))

    if [[ "$leader_id" == "$NODE_ID" ]] && (( age < CF_TG_LEADER_TTL )); then
      LEADER_NODE_ID="$NODE_ID"
      return 0
    elif (( age < CF_TG_LEADER_TTL )); then
      LEADER_NODE_ID="$leader_id"
      return 1
    fi
  fi

  # Hakuna kiongozi au muda wa kiongozi wa zamani umeisha -> Dai uongozi!
  if claim_leadership; then
    sleep 2
    # Hakiki tena baada ya sekunde 2 kuzuia race condition kama node 2 zilidai pamoja
    resp=$(cf_api GET "/dns_records?type=TXT&name=${TG_LEADER_RECORD_NAME}") || return 1
    txt_val=$(jq -r '.result[0].content // empty' <<< "$resp")
    txt_val="${txt_val#\"}"
    txt_val="${txt_val%\"}"
    leader_id="${txt_val%%:*}"
    LEADER_NODE_ID="$leader_id"
    [[ "$leader_id" == "$NODE_ID" ]] && return 0
  fi
  return 1
}

########################################
# 6. PARALLEL HEALTH CHECK ENGINE
########################################
check_node_health() {
  local ip="$1"
  local method="${CHECK_METHOD,,}"

  if [[ "$method" == "http" || "$method" == "https" ]]; then
    local url="${CHECK_SCHEME}://${ip}:${CHECK_PORT}${HEALTH_PATH}"
    local code
    code=$(curl -sS -k -o /dev/null -w "%{http_code}" \
      --connect-timeout "${CHECK_TIMEOUT}" \
      --max-time "${CHECK_TIMEOUT}" "$url" 2>/dev/null || echo "000")
    [[ "$code" =~ ^[23][0-9]{2}$ ]] && return 0
    return 1
  else
    # TCP check kupitia curl (inafanya kazi hata bila nc/netcat) au timeout + /dev/tcp
    if command -v timeout >/dev/null 2>&1; then
      timeout "${CHECK_TIMEOUT}" bash -c "exec 3<>/dev/tcp/${ip}/${CHECK_PORT}" 2>/dev/null && return 0
    fi
    curl -sS --connect-timeout "${CHECK_TIMEOUT}" --max-time "${CHECK_TIMEOUT}" \
      "telnet://${ip}:${CHECK_PORT}" >/dev/null 2>&1 &
    local pid=$!
    sleep 0.1
    kill "$pid" 2>/dev/null || true
    return 1
  fi
}

# Inakagua IP zote KWA WAKATI MMOJA (Parallel) na kuhifadhi matokeo kwenye associative array NODE_HEALTH_MAP
declare -gA NODE_HEALTH_MAP=()

check_all_nodes_parallel() {
  NODE_HEALTH_MAP=()
  [[ -z "${NODE_PRIORITY:-}" ]] && return 0

  local tmp_dir
  tmp_dir=$(mktemp -d "/tmp/cf-hc.XXXXXX")
  local -a ips
  IFS=',' read -r -a ips <<< "$NODE_PRIORITY"

  local ip
  for ip in "${ips[@]}"; do
    [[ -z "$ip" ]] && continue
    (
      if check_node_health "$ip"; then
        printf 'UP' > "${tmp_dir}/${ip}"
      else
        printf 'DOWN' > "${tmp_dir}/${ip}"
      fi
    ) &
  done
  wait

  for ip in "${ips[@]}"; do
    [[ -z "$ip" ]] && continue
    if [[ -f "${tmp_dir}/${ip}" && "$(cat "${tmp_dir}/${ip}")" == "UP" ]]; then
      NODE_HEALTH_MAP["$ip"]="UP"
    else
      NODE_HEALTH_MAP["$ip"]="DOWN"
    fi
  done

  rm -rf "$tmp_dir"
}

########################################
# 7. TELEGRAM UI & NOTIFICATIONS
########################################
notify_telegram() {
  local message="$1"
  [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0

  local keyboard payload
  keyboard=$(jq -nc '{
    keyboard: [
      [{text: "🔄 Refresh"}, {text: "📋 Orodha Nodes"}, {text: "📄 Orodha Domains"}],
      [{text: "➕ Ongeza Node"}, {text: "➖ Ondoa Node"}, {text: "🎯 Weka Priority"}],
      [{text: "🌐 Ongeza Domain"}, {text: "🗑️ Ondoa Domain"}, {text: "🧹 Safisha Marudio"}],
      [{text: "ℹ️ Msaada"}, {text: "❌ Ghairi"}]
    ],
    resize_keyboard: true,
    is_persistent: true
  }')

  payload=$(jq -nc \
    --arg chat_id "$TELEGRAM_CHAT_ID" \
    --arg text "$message" \
    --argjson reply_markup "$keyboard" \
    '{chat_id: $chat_id, text: $text, parse_mode: "Markdown", disable_web_page_preview: true, reply_markup: $reply_markup}')

  curl -sS --connect-timeout 5 --max-time "${CURL_TIMEOUT}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    --config - <<EOF >/dev/null 2>&1 || true
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
EOF
}

########################################
# 8. BOT COMMAND HANDLERS
########################################
handle_listips() {
  if [[ -z "${NODE_PRIORITY:-}" ]]; then
    notify_telegram "📋 *Orodha ya Nodes:* Hakuna IP iliyoongezwa bado. Bonyeza *➕ Ongeza Node*."
    return 0
  fi

  check_all_nodes_parallel

  local -a ips
  IFS=',' read -r -a ips <<< "$NODE_PRIORITY"
  local msg="📋 *Orodha ya Nodes kwa Kipaumbele (Priority):*"$'\n\n'
  local idx=1 ip status icon
  for ip in "${ips[@]}"; do
    [[ -z "$ip" ]] && continue
    status="${NODE_HEALTH_MAP[$ip]:-DOWN}"
    [[ "$status" == "UP" ]] && icon="🟢 ONLINE" || icon="🔴 OFFLINE"
    msg+="${idx}. \`${ip}\` — *${icon}*"$'\n'
    idx=$(( idx + 1 ))
  done
  notify_telegram "$msg"
}

handle_listrecords() {
  if [[ -z "${TARGET_RECORDS:-}" ]]; then
    notify_telegram "📄 *Orodha ya Domains:* Hakuna domain iliyoongezwa bado. Bonyeza *🌐 Ongeza Domain*."
    return 0
  fi

  local -a recs
  IFS=',' read -r -a recs <<< "$TARGET_RECORDS"
  local msg="📄 *Domains Zinazolindwa (Target Records):*"$'\n\n'
  local idx=1 rec resp current_ip proxied proxy_icon
  for rec in "${recs[@]}"; do
    [[ -z "$rec" ]] && continue
    resp=$(cf_api GET "/dns_records?type=A&name=${rec}" || true)
    current_ip=$(jq -r '.result[0].content // "Haijawekwa"' <<< "$resp" 2>/dev/null || echo "Haijawekwa")
    proxied=$(jq -r '.result[0].proxied // false' <<< "$resp" 2>/dev/null || echo "false")
    [[ "$proxied" == "true" ]] && proxy_icon="☁️ Proxied" || proxy_icon="🛡️ DNS Only"
    msg+="${idx}. \`${rec}\` ➡️ \`${current_ip}\` (${proxy_icon})"$'\n'
    idx=$(( idx + 1 ))
  done
  notify_telegram "$msg"
}

handle_addip() {
  local new_ip="${1:-}"
  local pos="${2:-}"

  if ! is_valid_ip "$new_ip"; then
    notify_telegram "❌ *IP si sahihi:* \`${new_ip}\`. Tafadhali tuma IPv4 sahihi (mfano: \`1.2.3.4\`)."
    return 1
  fi

  local -a ips=()
  [[ -n "${NODE_PRIORITY:-}" ]] && IFS=',' read -r -a ips <<< "$NODE_PRIORITY"

  local ip
  for ip in "${ips[@]}"; do
    if [[ "$ip" == "$new_ip" ]]; then
      notify_telegram "ℹ️ IP \`${new_ip}\` tayari ipo kwenye orodha."
      return 0
    fi
  done

  if [[ -n "$pos" && "$pos" =~ ^[0-9]+$ ]] && (( pos >= 1 && pos <= ${#ips[@]} + 1 )); then
    local idx=$(( pos - 1 ))
    ips=("${ips[@]:0:$idx}" "$new_ip" "${ips[@]:$idx}")
  else
    ips+=("$new_ip")
  fi

  local IFS=','
  NODE_PRIORITY="${ips[*]}"
  if save_shared_config; then
    notify_telegram "✅ Node \`${new_ip}\` imeongezwa kikamilifu!
📋 Priority mpya: \`${NODE_PRIORITY}\`"
  else
    notify_telegram "❌ Imeshindikana kuhifadhi mabadiliko kwenye Cloudflare TXT."
  fi
}

handle_removeip() {
  local target_ip="${1:-}"
  if [[ -z "${NODE_PRIORITY:-}" ]]; then
    notify_telegram "ℹ️ Hakuna nodes kwenye orodha kwa sasa."
    return 0
  fi

  local -a ips new_ips=()
  IFS=',' read -r -a ips <<< "$NODE_PRIORITY"
  local ip found=0
  for ip in "${ips[@]}"; do
    if [[ "$ip" == "$target_ip" ]]; then
      found=1
    elif [[ -n "$ip" ]]; then
      new_ips+=("$ip")
    fi
  done

  if (( found == 0 )); then
    notify_telegram "❌ IP \`${target_ip}\` haikupatikana kwenye orodha."
    return 1
  fi

  local IFS=','
  NODE_PRIORITY="${new_ips[*]}"
  if save_shared_config; then
    notify_telegram "🗑️ Node \`${target_ip}\` imeondolewa!
📋 Priority iliyobaki: \`${NODE_PRIORITY:-Tupu}\`"
  else
    notify_telegram "❌ Imeshindikana kuhifadhi mabadiliko kwenye Cloudflare TXT."
  fi
}

handle_setpriority() {
  local raw_list="${1// /}"
  local -a input_ips clean_ips=()
  IFS=',' read -r -a input_ips <<< "$raw_list"

  local ip
  for ip in "${input_ips[@]}"; do
    [[ -z "$ip" ]] && continue
    if ! is_valid_ip "$ip"; then
      notify_telegram "❌ IP \`${ip}\` si sahihi. Orodha haijabadilishwa."
      return 1
    fi
    # Zuia marudio ndani ya orodha
    local existing dup=0
    for existing in "${clean_ips[@]}"; do
      [[ "$existing" == "$ip" ]] && dup=1 && break
    done
    (( dup == 0 )) && clean_ips+=("$ip")
  done

  if (( ${#clean_ips[@]} == 0 )); then
    notify_telegram "❌ Orodha ya IP ni tupu au si sahihi."
    return 1
  fi

  local IFS=','
  NODE_PRIORITY="${clean_ips[*]}"
  if save_shared_config; then
    notify_telegram "🎯 *Priority Mpya Imehifadhiwa:*
\`${NODE_PRIORITY}\`"
  else
    notify_telegram "❌ Imeshindikana kuhifadhi priority mpya kwenye Cloudflare."
  fi
}

handle_addrecord() {
  local new_rec="${1,,}"
  new_rec="${new_rec%.}"

  if ! is_valid_domain "$new_rec"; then
    notify_telegram "❌ *Domain si sahihi:* \`${new_rec}\`. Tuma mfano: \`cdn1.domain.com\`"
    return 1
  fi

  local -a recs=()
  [[ -n "${TARGET_RECORDS:-}" ]] && IFS=',' read -r -a recs <<< "$TARGET_RECORDS"

  local r
  for r in "${recs[@]}"; do
    if [[ "${r,,}" == "$new_rec" ]]; then
      notify_telegram "ℹ️ Domain \`${new_rec}\` tayari ipo kwenye orodha."
      return 0
    fi
  done

  recs+=("$new_rec")
  local IFS=','
  TARGET_RECORDS="${recs[*]}"

  if save_shared_config; then
    notify_telegram "✅ Domain \`${new_rec}\` imeongezwa kwenye ulinzi wa Failover!
📄 Domains: \`${TARGET_RECORDS}\`"
  else
    notify_telegram "❌ Imeshindikana kuhifadhi domain kwenye Cloudflare TXT."
  fi
}

handle_removerecord() {
  local target_rec="${1,,}"
  target_rec="${target_rec%.}"

  local -a recs new_recs=()
  IFS=',' read -r -a recs <<< "${TARGET_RECORDS:-}"
  local r found=0
  for r in "${recs[@]}"; do
    if [[ "${r,,}" == "$target_rec" ]]; then
      found=1
    elif [[ -n "$r" ]]; then
      new_recs+=("$r")
    fi
  done

  if (( found == 0 )); then
    notify_telegram "❌ Domain \`${target_rec}\` haikupatikana kwenye orodha."
    return 1
  fi

  local IFS=','
  TARGET_RECORDS="${new_recs[*]}"
  if save_shared_config; then
    notify_telegram "🗑️ Domain \`${target_rec}\` imeondolewa kwenye orodha ya Failover.
📄 Domains zilizobaki: \`${TARGET_RECORDS:-Tupu}\`"
  else
    notify_telegram "❌ Imeshindikana kuhifadhi mabadiliko kwenye Cloudflare TXT."
  fi
}

handle_cleanup() {
  local removed_count=0
  local -a recs=()
  [[ -n "${TARGET_RECORDS:-}" ]] && IFS=',' read -r -a recs <<< "$TARGET_RECORDS"

  local rec resp extra_ids eid
  for rec in "${recs[@]}"; do
    [[ -z "$rec" ]] && continue
    resp=$(cf_api GET "/dns_records?type=A&name=${rec}" || true)
    extra_ids=$(jq -r '.result[1:][]?.id // empty' <<< "$resp" 2>/dev/null || true)
    for eid in $extra_ids; do
      if cf_api DELETE "/dns_records/${eid}" >/dev/null 2>&1; then
        removed_count=$(( removed_count + 1 ))
      fi
    done
  done

  # Safisha pia marudio kwenye TXT records za config na leader
  local txt_name
  for txt_name in "$CONFIG_RECORD_NAME" "${TG_LEADER_RECORD_NAME:-}"; do
    [[ -z "$txt_name" ]] && continue
    resp=$(cf_api GET "/dns_records?type=TXT&name=${txt_name}" || true)
    extra_ids=$(jq -r '.result[1:][]?.id // empty' <<< "$resp" 2>/dev/null || true)
    for eid in $extra_ids; do
      if cf_api DELETE "/dns_records/${eid}" >/dev/null 2>&1; then
        removed_count=$(( removed_count + 1 ))
      fi
    done
  done

  notify_telegram "🧹 *Usafishaji Umekamilika!*
Rekodi za marudio (duplicates) zilizofutwa: *${removed_count}*"
}

send_status_report_live() {
  ensure_node_id
  check_all_nodes_parallel

  local msg="📊 *RIPOTI YA HALI YA FAILOVER (LIVE)*"$'\n'
  msg+="🤖 *Kiongozi wa Bot:* \`${NODE_ID}\`"$'\n'
  msg+="🔍 *Check:* \`${CHECK_METHOD^^}:${CHECK_PORT}\` (Timeout: ${CHECK_TIMEOUT}s)"$'\n\n'

  msg+="🖥️ *Hali ya Nodes (Priority Order):*"$'\n'
  if [[ -z "${NODE_PRIORITY:-}" ]]; then
    msg+="_Hakuna node iliyowekwa_"$'\n'
  else
    local -a ips
    IFS=',' read -r -a ips <<< "$NODE_PRIORITY"
    local i=1 ip st icon best_ip=""
    for ip in "${ips[@]}"; do
      [[ -z "$ip" ]] && continue
      st="${NODE_HEALTH_MAP[$ip]:-DOWN}"
      if [[ "$st" == "UP" ]]; then
        icon="🟢 UP"
        [[ -z "$best_ip" ]] && best_ip="$ip"
      else
        icon="🔴 DOWN"
      fi
      msg+="${i}. \`${ip}\` — *${icon}*"$'\n'
      i=$(( i + 1 ))
    done
  fi

  msg+=$'\n'"🌐 *Domains Zinazolindwa:*"$'\n'
  if [[ -z "${TARGET_RECORDS:-}" ]]; then
    msg+="_Hakuna domain iliyowekwa_"$'\n'
  else
    local -a recs
    IFS=',' read -r -a recs <<< "$TARGET_RECORDS"
    local rec resp cur_ip
    for rec in "${recs[@]}"; do
      [[ -z "$rec" ]] && continue
      resp=$(cf_api GET "/dns_records?type=A&name=${rec}" || true)
      cur_ip=$(jq -r '.result[0].content // "N/A"' <<< "$resp" 2>/dev/null || echo "N/A")
      msg+="• \`${rec}\` ➡️ \`${cur_ip}\`"$'\n'
    done
  fi

  notify_telegram "$msg"
}

handle_help() {
  local msg="ℹ️ *MSAADA WA CLOUDFLARE FAILOVER BOT (v2.0)*

Unaweza kutumia vitufe vya chini au kutuma amri moja kwa moja:

🔹 `/status` au `/refresh` — Hali halisi ya nodes na DNS sasa hivi
🔹 `/addip <ip> [nafasi]` — Kuongeza node mpya
🔹 `/removeip <ip>` — Kuondoa node
🔹 `/setpriority <ip1,ip2>` — Kupanga upya kipaumbele
🔹 `/listips` — Kuona orodha ya nodes
🔹 `/addrecord <domain>` — Kuongeza domain
🔹 `/removerecord <domain>` — Kuondoa domain
🔹 `/listrecords` — Kuona domains na IP zake
🔹 `/cleanup` — Kufuta DNS records zilizojirudia
🔹 `/cancel` — Kughairi hatua inayokusubiri"
  notify_telegram "$msg"
}
