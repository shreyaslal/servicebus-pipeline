#!/usr/bin/env bash
# Usage: scripts/measure.sh <resource-group> <prefix> [message-count]
# 1. waits until the app has scaled in to 1 replica and the queue is empty
# 2. publishes N messages through the deployed app
# 3. polls until the queue drains, and reports drain time, approximate throughput,
#    peak replicas and time to first scale-up
set -uo pipefail

RG="$1"; PREFIX="$2"; COUNT="${3:-5000}"
APP="${PREFIX}-worker"
SUB=$(az account show --query id -o tsv)
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.App/containerApps/$APP"
API="api-version=2024-03-01"

NS=$(az servicebus namespace list -g "$RG" --query "[0].name" -o tsv)
FQDN=$(az rest --method get --url "$BASE?$API" --query properties.configuration.ingress.fqdn -o tsv)

replicas() {
  local r
  r=$(az rest --method get --url "$BASE/revisions?$API" \
        --query "max(value[?properties.active].properties.replicas)" -o tsv 2>/dev/null)
  case "$r" in ''|None|null) echo "?";; *) echo "$r";; esac
}
active() {
  local a
  a=$(az servicebus queue show -g "$RG" --namespace-name "$NS" -n orders \
        --query countDetails.activeMessageCount -o tsv 2>/dev/null)
  echo "${a:-?}"
}

echo "Waiting for a clean baseline (1 replica, empty queue). This can take 5-10 minutes after a previous run."
for i in $(seq 1 90); do
  R=$(replicas); A=$(active)
  echo "baseline check $i: replicas=$R active=$A"
  if [ "$R" = "1" ] && [ "$A" = "0" ]; then break; fi
  sleep 10
done
BASE_R=$(replicas)
echo "Baseline replicas: $BASE_R"

echo "Publishing $COUNT messages..."
curl -fsS -X POST "https://$FQDN/publish?count=$COUNT"; echo

START=$(date +%s)
FIRST_SCALE=""
PEAK=1
while true; do
  NOW=$(date +%s); ELAPSED=$((NOW-START))
  R=$(replicas); A=$(active)
  if [[ "$R" =~ ^[0-9]+$ ]]; then
    [ "$R" -gt "$PEAK" ] && PEAK=$R
    if [ -z "$FIRST_SCALE" ] && [ "$R" -gt 1 ]; then FIRST_SCALE=$ELAPSED; fi
  fi
  echo "t=${ELAPSED}s replicas=$R active=$A"
  if [ "$A" = "0" ]; then break; fi
  if [ "$ELAPSED" -gt 1800 ]; then echo "Timed out after 30 min"; break; fi
  sleep 5
done

END=$(date +%s); TOTAL=$((END-START))
echo
echo "---- RESULT ----"
echo "baseline replicas:   $BASE_R"
echo "messages:            $COUNT"
echo "drain time:          ${TOTAL}s"
echo "throughput (approx): $(( COUNT / (TOTAL>0?TOTAL:1) )) msg/s"
echo "peak replicas:       $PEAK"
echo "first scale-up at:   ${FIRST_SCALE:-never} s after publish"
