#!/bin/bash
#
# cf-failover.sh (v2.0 Professional Edition)
# Injini ya kukagua afya ya nodes na kuhamisha DNS kiotomatiki (Auto-Failover)
# Ina Anti-Flapping (kuhakiki mara 2 kabla ya kuhamisha) na Parallel Health Checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/cf-failover/config.env"
LIB_FILE="${SCRIPT_DIR}/cf-failover-lib.sh"
STATE_FILE="/etc/cf-failover/state.env"

if [[ ! -f "$CONFIG_FILE" || ! -f "$LIB_FILE" ]]; then
  echo "ERROR: Config au Library haipo." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
# shellcheck disable=SC1090
source "$LIB_FILE"

ensure_node_id

########################################
# 1. LOCK FILE (ZUIA CRON KUGONGANA)
########################################
LOCK_FILE="/var/lock/cf-failover-check.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
exec 201>"$LOCK_FILE"
if ! flock -n 201; then
  log "cf-failover.sh tayari inaendesha. Ninatoka."
  exit 0
fi

########################################
# 2. STATE MANAGEMENT (ATOMIC)
########################################
LAST_ACTIVE_IP=""
LAST_NODES_STATE=""

load_health_state() {
  local key val
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    val="${val%\"}"
    val="${val#\"}"
    case "$key" in
      LAST_ACTIVE_IP)  LAST_ACTIVE_IP="$val" ;;
      LAST_NODES_STATE) LAST_NODES_STATE="$val" ;;
    esac
  done < "$STATE_FILE"
}

save_health_state() {
  local tmp_file="${STATE_FILE}.tmp.$$"
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$tmp_file" <<EOF
LAST_ACTIVE_IP="${LAST_ACTIVE_IP:-}"
LAST_NODES_STATE="${LAST_NODES_STATE:-}"
EOF
  chmod 600 "$tmp_file" 2>/dev/null || true
  mv -f "$tmp_file" "$STATE_FILE"
}

########################################
# 3. DNS RECORD UPDATER (PRESERVES PROXY)
########################################
ensure_domain_points_to() {
  local domain="$1"
  local target_ip="$2"
  local resp rec_id cur_ip cur_proxied payload

  resp=$(cf_api GET "/dns_records?type=A&name=${domain}") || return 1
  jq -e '.success == true' <<< "$resp" >/dev/null 2>&1 || return 1

  rec_id=$(jq -r '.result[0].id // empty' <<< "$resp")
  cur_ip=$(jq -r '.result[0].content // empty' <<< "$resp")
  cur_proxied=$(jq -r "if .result[0].proxied == null then ${DEFAULT_PROXIED:-false} else .result[0].proxied end" <<< "$resp")

  # Kama tayari iko kwenye IP sahihi, usipige PUT API bila sababu
  if [[ -n "$rec_id" && "$cur_ip" == "$target_ip" ]]; then
    return 0
  fi

  payload=$(jq -nc \
    --arg name "$domain" \
    --arg content "$target_ip" \
    --argjson ttl "${DNS_TTL:-60}" \
    --argjson proxied "$cur_proxied" \
    '{type:"A", name:$name, content:$content, ttl:$ttl, proxied:$proxied}')

  if [[ -n "$rec_id" ]]; then
    resp=$(cf_api PUT "/dns_records/${rec_id}" "$payload") || return 1
  else
    resp=$(cf_api POST "/dns_records" "$payload") || return 1
  fi

  if jq -e '.success == true' <<< "$resp" >/dev/null 2>&1; then
    log "DNS IMESASISHWA: ${domain} -> ${target_ip} (proxied=${cur_proxied})"
    return 2 # 2 inamaanisha mabadiliko yamefanyika
  fi
  return 1
}

########################################
# 4. MAIN FAILOVER LOGIC & ANTI-FLAPPING
########################################
load_health_state
get_shared_config

if [[ -z "${NODE_PRIORITY:-}" || -z "${TARGET_RECORDS:-}" ]]; then
  log "NODE_PRIORITY au TARGET_RECORDS bado ni tupu. Ninasubiri ziongezwe kupitia Telegram."
  exit 0
fi

check_all_nodes_parallel

IFS=',' read -r -a IPS <<< "$NODE_PRIORITY"
IFS=',' read -r -a DOMAINS <<< "$TARGET_RECORDS"

# ANTI-FLAPPING: Kama IP iliyokuwa active mara ya mwisho imeonekana DOWN,
# ipige check ya pili baada ya sekunde 2 ili kujiridhisha siyo hiccup ya mtandao.
if [[ -n "$LAST_ACTIVE_IP" && "${NODE_HEALTH_MAP[$LAST_ACTIVE_IP]:-}" == "DOWN" ]]; then
  sleep 2
  if check_node_health "$LAST_ACTIVE_IP"; then
    NODE_HEALTH_MAP["$LAST_ACTIVE_IP"]="UP"
    log "Anti-Flapping: ${LAST_ACTIVE_IP} ilipona kwenye jaribio la pili."
  fi
fi

BEST_IP=""
CURRENT_NODES_STATE=""

for ip in "${IPS[@]}"; do
  [[ -z "$ip" ]] && continue
  st="${NODE_HEALTH_MAP[$ip]:-DOWN}"
  CURRENT_NODES_STATE+="${ip}:${st},"
  if [[ "$st" == "UP" && -z "$BEST_IP" ]]; then
    BEST_IP="$ip"
  fi
done

if [[ -z "$BEST_IP" ]]; then
  log "ONYO KUU: Nodes ZOTE ziko DOWN!"
  if [[ "$LAST_NODES_STATE" != "$CURRENT_NODES_STATE" ]]; then
    LAST_NODES_STATE="$CURRENT_NODES_STATE"
    save_health_state
    notify_telegram "🚨 *TAHADHARI KUU (${NODE_ID}):*
Nodes ZOTE kwenye orodha ya Priority zimeshindwa kujibu (OFFLINE)! DNS haijabadilishwa."
  fi
  exit 1
fi

CHANGED_DOMAINS=()
for domain in "${DOMAINS[@]}"; do
  [[ -z "$domain" ]] && continue
  rc=0
  ensure_domain_points_to "$domain" "$BEST_IP" || rc=$?
  if (( rc == 2 )); then
    CHANGED_DOMAINS+=("$domain")
  fi
done

# Tuma taarifa Telegram TU kama kuna mabadiliko ya DNS au hali ya Node imebadilika
if (( ${#CHANGED_DOMAINS[@]} > 0 )) || [[ -n "$LAST_ACTIVE_IP" && "$LAST_ACTIVE_IP" != "$BEST_IP" ]]; then
  notify_telegram "⚡ *FAILOVER IMETEKELEZWA (kutoka ${NODE_ID})*

🎯 *IP Mpya Inayotumika:* \`${BEST_IP}\`
🔄 *IP ya Awali:* \`${LAST_ACTIVE_IP:-Hakuna}\`
🌐 *Domains Zilizohamishwa:* \`${CHANGED_DOMAINS[*]:-${TARGET_RECORDS}}\`"
fi

LAST_ACTIVE_IP="$BEST_IP"
LAST_NODES_STATE="$CURRENT_NODES_STATE"
save_health_state
