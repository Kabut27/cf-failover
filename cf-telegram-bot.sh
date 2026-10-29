#!/bin/bash
#
# cf-telegram-bot.sh (v2.0 Professional Edition)
# Huduma inayosikiliza amri za Telegram MUDA WOTE (/addip, vitufe, n.k.)
# na kujibu ndani ya sekunde 1-2, badala ya kusubiri run ya cron.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/cf-failover/config.env"
LIB_FILE="${SCRIPT_DIR}/cf-failover-lib.sh"
TELEGRAM_STATE_FILE="/etc/cf-failover/telegram-state.env"
OLD_STATE_FILE="/etc/cf-failover/state.env"

########################################
# 1. UKAGUZI WA AWALI (PRE-FLIGHT CHECKS)
########################################
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file haipo ($CONFIG_FILE). Kimbiza install.sh kwanza." >&2
  exit 1
fi
if [[ ! -f "$LIB_FILE" ]]; then
  echo "ERROR: cf-failover-lib.sh haipo (inatarajiwa kwenye ${SCRIPT_DIR})." >&2
  exit 1
fi
for cmd_req in jq curl flock; do
  if ! command -v "$cmd_req" >/dev/null 2>&1; then
    echo "ERROR: '$cmd_req' haipo kwenye mfumo huu. Sakinisha kwa: apt-get install -y $cmd_req" >&2
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1090
source "$LIB_FILE"

for var in CF_API_TOKEN CF_ZONE_ID CONFIG_RECORD_NAME; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: ${var} haipo au haina thamani kwenye ${CONFIG_FILE}. Rekebisha kisha jaribu tena." >&2
    exit 1
  fi
done

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID haziko kwenye ${CONFIG_FILE}." >&2
  echo "Huduma hii haina maana bila hizo - haitaanza." >&2
  exit 1
fi

NODE_PRIORITY="${NODE_PRIORITY:-}"
TARGET_RECORDS="${TARGET_RECORDS:-}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
CHECK_PORT="${CHECK_PORT:-443}"
CHECK_METHOD="${CHECK_METHOD:-tcp}"
HEALTH_PATH="${HEALTH_PATH:-/}"
CHECK_SCHEME="${CHECK_SCHEME:-https}"
DNS_TTL="${DNS_TTL:-60}"
CF_TG_HEARTBEAT_INTERVAL="${CF_TG_HEARTBEAT_INTERVAL:-30}"
CF_TG_LEADER_TTL="${CF_TG_LEADER_TTL:-90}"
PENDING_ACTION_TTL="${PENDING_ACTION_TTL:-120}"
SHARED_CONFIG_CACHE_TTL="${SHARED_CONFIG_CACHE_TTL:-5}"

TG_LEADER_RECORD_NAME="tgleader.${CONFIG_RECORD_NAME}"
ensure_node_id
LEADER_NODE_ID="${LEADER_NODE_ID:-}"

# Fallback kama release_leadership haipo kwenye lib ya zamani
if ! declare -F release_leadership >/dev/null 2>&1; then
  release_leadership() {
    [[ -z "${TG_LEADER_RECORD_NAME:-}" ]] && return 0
    if declare -F update_txt_record >/dev/null 2>&1; then
      update_txt_record "$TG_LEADER_RECORD_NAME" "${NODE_ID}:0" >/dev/null 2>&1 || true
    fi
  }
fi

########################################
# 2. LOCK FILE (SINGLE INSTANCE GUARD)
########################################
LOCK_FILE="/var/lock/cf-telegram-bot.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "ERROR: cf-telegram-bot.sh tayari inaendesha kwenye node hii (lock ipo). Ninatoka." >&2
  exit 1
fi

########################################
# 3. STATE MANAGEMENT (ATOMIC & SAFE)
########################################
TELEGRAM_OFFSET=0
PENDING_ACTION=""
PENDING_SINCE=0
LAST_CONFIG_FETCH_TS=0

load_telegram_state() {
  local key val
  if [[ -f "$TELEGRAM_STATE_FILE" ]]; then
    while IFS='=' read -r key val || [[ -n "$key" ]]; do
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
      val="${val%\"}"
      val="${val#\"}"
      case "$key" in
        TELEGRAM_OFFSET) [[ "$val" =~ ^[0-9]+$ ]] && TELEGRAM_OFFSET="$val" ;;
        PENDING_ACTION)  PENDING_ACTION="$val" ;;
        PENDING_SINCE)   [[ "$val" =~ ^[0-9]+$ ]] && PENDING_SINCE="$val" ;;
      esac
    done < "$TELEGRAM_STATE_FILE"
  elif [[ -f "$OLD_STATE_FILE" ]]; then
    local old_offset old_pending
    old_offset=$(grep -o 'TELEGRAM_OFFSET=[0-9]*' "$OLD_STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
    old_pending=$(grep -o 'PENDING_ACTION="[^"]*"' "$OLD_STATE_FILE" 2>/dev/null | cut -d'"' -f2 || true)
    [[ "$old_offset" =~ ^[0-9]+$ ]] && TELEGRAM_OFFSET="$old_offset"
    [[ -n "$old_pending" ]] && PENDING_ACTION="$old_pending" && PENDING_SINCE=$(date +%s)
    save_telegram_state
    log "Imehamisha TELEGRAM_OFFSET/PENDING_ACTION kutoka state.env ya zamani."
  fi
}

save_telegram_state() {
  local state_dir tmp_file
  state_dir="$(dirname "$TELEGRAM_STATE_FILE")"
  mkdir -p "$state_dir"
  tmp_file="${TELEGRAM_STATE_FILE}.tmp.$$"

  cat > "$tmp_file" <<EOF
TELEGRAM_OFFSET=${TELEGRAM_OFFSET:-0}
PENDING_ACTION="${PENDING_ACTION:-}"
PENDING_SINCE=${PENDING_SINCE:-0}
EOF
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$TELEGRAM_STATE_FILE"
}

clear_pending_action() {
  if [[ -n "${PENDING_ACTION:-}" ]]; then
    PENDING_ACTION=""
    PENDING_SINCE=0
    save_telegram_state
  fi
}

########################################
# 4. GRACEFUL SHUTDOWN & CLEANUP TRAP
########################################
cleanup_and_exit() {
  save_telegram_state 2>/dev/null || true
  if [[ "${LEADER_NODE_ID:-}" == "${NODE_ID:-}" ]]; then
    release_leadership 2>/dev/null || true
  fi
  log "cf-telegram-bot.sh imesimama kwa usalama (signal)."
  exit 0
}

trap cleanup_and_exit TERM INT

########################################
# 5. UTILS & SMART CONFIG CACHING
########################################
trim_text() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

refresh_shared_config_cached() {
  local force="${1:-0}"
  local now
  now=$(date +%s)
  if (( force == 1 || now - LAST_CONFIG_FETCH_TS >= SHARED_CONFIG_CACHE_TTL )); then
    get_shared_config
    LAST_CONFIG_FETCH_TS=$now
  fi
}

########################################
# 6. USIMAMIZI WA VITUFE NA AMRI (COMMANDS)
########################################
prompt_pending() {
  local action="$1" question="$2"
  PENDING_ACTION="$action"
  PENDING_SINCE=$(date +%s)
  save_telegram_state
  notify_telegram "${question}

💡 _Bonyeza '❌ Ghairi' au tuma /cancel kughairi._"
}

handle_pending_reply() {
  local action="$1" value="$2"
  local now
  now=$(date +%s)

  if (( PENDING_SINCE > 0 && now - PENDING_SINCE > PENDING_ACTION_TTL )); then
    clear_pending_action
    notify_telegram "⏱️ Muda wa kujibu hatua ya awali umeisha. Tafadhali chagua kitufe au amri upya."
    return 0
  fi

  refresh_shared_config_cached 1

  case "$action" in
    addip)
      local ip_arg pos_arg
      read -r ip_arg pos_arg _ <<< "$value"
      handle_addip "$ip_arg" "${pos_arg:-}"
      ;;
    removeip)     handle_removeip "$value" ;;
    setpriority)  handle_setpriority "$value" ;;
    addrecord)    handle_addrecord "$value" ;;
    removerecord) handle_removerecord "$value" ;;
    *)            : ;;
  esac

  clear_pending_action
  LAST_CONFIG_FETCH_TS=$(date +%s)
}

handle_menu_button() {
  local text="$1"
  case "$text" in
    "➕ Ongeza Node")
      prompt_pending "addip" "➕ Tuma IP ya node unayotaka kuongeza (mfano: \`1.2.3.4\` au \`1.2.3.4 1\` kuiweka namba 1)" ;;
    "➖ Ondoa Node")
      prompt_pending "removeip" "➖ Tuma IP ya node unayotaka kuondoa" ;;
    "🎯 Weka Priority")
      prompt_pending "setpriority" "🎯 Tuma orodha mpya ya IP kwa mpangilio (mfano: \`3.3.3.3,2.2.2.2,1.1.1.1\`)" ;;
    "🌐 Ongeza Domain")
      prompt_pending "addrecord" "🌐 Tuma domain unayotaka kuongeza (mfano: \`cdn1.domain.com\`)" ;;
    "🗑️ Ondoa Domain")
      prompt_pending "removerecord" "🗑️ Tuma domain unayotaka kuondoa" ;;
    "❌ Ghairi"|"🚫 Ghairi")
      clear_pending_action
      notify_telegram "✅ Hatua iliyokuwa inasubiri imeghairiwa." ;;
    "📋 Orodha Nodes")
      clear_pending_action
      refresh_shared_config_cached
      handle_listips ;;
    "📄 Orodha Domains")
      clear_pending_action
      refresh_shared_config_cached
      handle_listrecords ;;
    "🔄 Refresh")
      clear_pending_action
      refresh_shared_config_cached 1
      send_status_report_live ;;
    "🧹 Safisha Marudio")
      clear_pending_action
      refresh_shared_config_cached 1
      handle_cleanup ;;
    "ℹ️ Msaada")
      clear_pending_action
      handle_help ;;
    *)
      return 1 ;;
  esac
  return 0
}

handle_telegram_command() {
  local text="$1"
  local cmd arg1 arg2 rest

  read -r cmd arg1 arg2 rest <<< "$text"
  cmd="${cmd%%@*}"
  cmd="${cmd,,}"

  case "$cmd" in
    /cancel|/stop)
      clear_pending_action
      notify_telegram "✅ Hatua iliyokuwa inasubiri imeghairiwa."
      ;;
    /refresh|/status)
      clear_pending_action
      refresh_shared_config_cached 1
      send_status_report_live
      ;;
    /addip)
      clear_pending_action
      refresh_shared_config_cached 1
      [[ -n "${arg1:-}" ]] && handle_addip "$arg1" "${arg2:-}" || prompt_pending "addip" "➕ Tuma IP ya node unayotaka kuongeza (mfano: \`1.2.3.4\`)"
      ;;
    /removeip)
      clear_pending_action
      refresh_shared_config_cached 1
      [[ -n "${arg1:-}" ]] && handle_removeip "$arg1" || prompt_pending "removeip" "➖ Tuma IP ya node unayotaka kuondoa"
      ;;
    /setpriority)
      clear_pending_action
      refresh_shared_config_cached 1
      [[ -n "${arg1:-}" ]] && handle_setpriority "$arg1" || prompt_pending "setpriority" "🎯 Tuma orodha mpya ya IP kwa mpangilio (mfano: \`3.3.3.3,2.2.2.2,1.1.1.1\`)"
      ;;
    /listips)
      clear_pending_action
      refresh_shared_config_cached
      handle_listips
      ;;
    /addrecord)
      clear_pending_action
      refresh_shared_config_cached 1
      [[ -n "${arg1:-}" ]] && handle_addrecord "$arg1" || prompt_pending "addrecord" "🌐 Tuma domain unayotaka kuongeza (mfano: \`cdn1.domain.com\`)"
      ;;
    /removerecord)
      clear_pending_action
      refresh_shared_config_cached 1
      [[ -n "${arg1:-}" ]] && handle_removerecord "$arg1" || prompt_pending "removerecord" "🗑️ Tuma domain unayotaka kuondoa"
      ;;
    /listrecords)
      clear_pending_action
      refresh_shared_config_cached
      handle_listrecords
      ;;
    /cleanup)
      clear_pending_action
      refresh_shared_config_cached 1
      handle_cleanup
      ;;
    /help|/start)
      clear_pending_action
      handle_help
      ;;
    *)
      :
      ;;
  esac
}

########################################
# 7. TELEGRAM LONG-POLLING ENGINE
########################################
poll_once() {
  local offset=$(( ${TELEGRAM_OFFSET:-0} + 1 ))
  local response curl_exit=0

  response=$(curl -sS --connect-timeout 5 --max-time 30 --config - <<EOF
url = "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${offset}&limit=20&timeout=25&allowed_updates=%5B%22message%22,%22callback_query%22%5D"
EOF
  ) || curl_exit=$?

  if (( curl_exit != 0 )) || [[ -z "$response" ]]; then
    return 1
  fi

  local api_status
  api_status=$(jq -r 'if .ok == true then "OK" elif .error_code == 409 then "CONFLICT_409" else "ERR_\(.error_code // "UNKNOWN")" end' <<< "$response" 2>/dev/null || echo "PARSE_ERR")

  if [[ "$api_status" == "CONFLICT_409" ]]; then
    log "ONYO: Telegram imerudisha 409 Conflict (node nyingine inapiga getUpdates). Ninaachia uongozi ili kukagua upya."
    return 2
  elif [[ "$api_status" != "OK" ]]; then
    return 1
  fi

  local parsed_updates
  parsed_updates=$(jq -r '
    .result[]? |
    [
      (.update_id // ""),
      (.message.chat.id // .callback_query.message.chat.id // ""),
      ((.message.text // .callback_query.data // "") | gsub("[\\r\\n\\t]+"; " "))
    ] | @tsv
  ' <<< "$response" 2>/dev/null || true)

  [[ -z "$parsed_updates" ]] && return 0

  local uid chat_id raw_text text
  while IFS=$'\t' read -r uid chat_id raw_text; do
    [[ -z "$uid" ]] && continue

    TELEGRAM_OFFSET="$uid"
    save_telegram_state

    [[ -z "$chat_id" || "$chat_id" != "$TELEGRAM_CHAT_ID" ]] && continue

    text="$(trim_text "$raw_text")"
    [[ -z "$text" ]] && continue

    if handle_menu_button "$text"; then
      :
    elif [[ "$text" == /* ]]; then
      handle_telegram_command "$text"
    elif [[ -n "${PENDING_ACTION:-}" ]]; then
      handle_pending_reply "$PENDING_ACTION" "$text"
    else
      handle_telegram_command "$text"
    fi
  done <<< "$parsed_updates"

  return 0
}

########################################
# 8. MAIN LOOP & STRICT LEADER LEASE
########################################
log "cf-telegram-bot.sh (v2.0) imeanza. Node ID: ${NODE_ID}"
load_telegram_state
refresh_shared_config_cached 1

consecutive_errors=0

while true; do
  if am_i_leader; then
    log "Ninaendesha huduma ya Telegram kama KIONGOZI (${NODE_ID})."
    now=$(date +%s)
    last_heartbeat_ts=$now
    lease_expires_at=$(( now + CF_TG_LEADER_TTL ))
    consecutive_errors=0

    while true; do
      poll_rc=0
      poll_once || poll_rc=$?

      if (( poll_rc == 2 )); then
        sleep 2
        break
      elif (( poll_rc != 0 )); then
        consecutive_errors=$(( consecutive_errors + 1 ))
        backoff=$(( consecutive_errors * 2 ))
        (( backoff > 10 )) && backoff=10
        sleep "$backoff"
      else
        consecutive_errors=0
      fi

      now=$(date +%s)

      if (( now - last_heartbeat_ts >= CF_TG_HEARTBEAT_INTERVAL )); then
        if claim_leadership; then
          last_heartbeat_ts=$now
          lease_expires_at=$(( now + CF_TG_LEADER_TTL ))
        else
          log "ONYO: Kusasisha heartbeat kumeshindikana."
          if (( now >= lease_expires_at )); then
            log "ONYO KUU: Muda wa lease ya uongozi umeisha bila kufanikiwa kusasisha. Ninasimama kama kiongozi."
            break
          fi
        fi
      fi

      if [[ "${LEADER_NODE_ID:-}" != "$NODE_ID" ]]; then
        log "Node nyingine (${LEADER_NODE_ID:-unknown}) imekuwa kiongozi - ninasubiri."
        break
      fi
    done
  else
    sleep 5
  fi
done
