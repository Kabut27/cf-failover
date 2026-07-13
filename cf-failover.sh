#!/bin/bash
#
# cf-failover.sh
# Automatic health-check + Cloudflare DNS failover
# Inasaidia priority list ya nodes na domain records kadhaa kwa wakati mmoja
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

STATE_FILE="/var/tmp/cf-failover-state"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-5}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"
CHECK_PORT="${CHECK_PORT:-443}"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_node() {
  local ip="$1"
  if timeout "$CHECK_TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/${ip}/${CHECK_PORT}" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    FAIL_COUNT=0
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
FAIL_COUNT=$FAIL_COUNT
EOF
}

get_record_id() {
  local record_name="$1"
  curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | \
    grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
}

get_current_ip() {
  local record_name="$1"
  curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${record_name}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" | \
    grep -o '"content":"[^"]*' | head -1 | cut -d'"' -f4
}

update_dns() {
  local record_name="$1"
  local new_ip="$2"
  local record_id
  record_id=$(get_record_id "$record_name")

  if [[ -z "$record_id" ]]; then
    log "ERROR: Imeshindwa kupata DNS record ID kwa ${record_name}"
    return 1
  fi

  local response
  response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
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
# MAIN
########################################

load_state

# NODE_PRIORITY ni list ya IP kwa mpangilio, mfano: "3.3.3.3,2.2.2.2,1.1.1.1"
IFS=',' read -ra PRIORITY_ARR <<< "$NODE_PRIORITY"
TOP_IP="${PRIORITY_ARR[0]}"

# Tafuta IP ya kwanza inayofanya kazi kwa mpangilio wa priority
DESIRED_IP=""
for ip in "${PRIORITY_ARR[@]}"; do
  if check_node "$ip"; then
    DESIRED_IP="$ip"
    break
  fi
done

if [[ -z "$DESIRED_IP" ]]; then
  log "ONYO: Node ZOTE hazirespondi! Hakuna kinachobadilishwa."
  exit 0
fi

# Flap protection: kama TOP_IP ndio inayoshindwa, subiri FAIL_THRESHOLD
# consecutive fails kabla ya kushusha - lakini kama tayari tumeshusha,
# rudi TOP_IP mara moja ikiwa imerudi (hakuna ucheleweshaji wa kupanda juu)
if ! check_node "$TOP_IP"; then
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "TOP priority node ($TOP_IP) hairespondi. Fail count: $FAIL_COUNT/$FAIL_THRESHOLD"
else
  FAIL_COUNT=0
fi

# Angalia records zote na uzibadilishe kama zinahitajika
IFS=',' read -ra RECORDS_ARR <<< "$TARGET_RECORDS"
for record in "${RECORDS_ARR[@]}"; do
  current_ip=$(get_current_ip "$record")

  if [[ "$current_ip" == "$DESIRED_IP" ]]; then
    continue  # tayari sahihi, hakuna cha kufanya
  fi

  # Kama tunashuka kutoka TOP_IP, hakikisha tumefika threshold
  if [[ "$current_ip" == "$TOP_IP" ]] && [[ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]]; then
    continue  # bado hatujafika threshold, subiri
  fi

  log "${record}: ${current_ip:-haipo} -> ${DESIRED_IP}"
  update_dns "$record" "$DESIRED_IP"
done

save_state
