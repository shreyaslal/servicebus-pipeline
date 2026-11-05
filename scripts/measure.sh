#!/usr/bin/env bash
# Usage: scripts/measure.sh <resource-group> <prefix> [message-count]
# Publishes N messages through the deployed app, then reports drain time,
# approximate throughput, peak replicas and time to first scale-up.
set -euo pipefail

RG="$1"; PREFIX="$2"; COUNT="${3:-5000}"
APP="${PREFIX}-worker"
NS=$(az servicebus namespace list -g "$RG" --query "[0].name" -o tsv)
FQDN=$(az containerapp show -g "$RG" -n "$APP" --query properties.configuration.ingress.fqdn -o tsv)

replicas() { az containerapp replica list -g "$RG" -n "$APP" --query "length(@)" -o tsv; }
active()   { az servicebus queue show -g "$RG" --namespace-name "$NS" -n orders --query countDetails.activeMessageCount -o tsv; }

echo "Baseline replicas: $(replicas)"
echo "Publishing $COUNT messages..."
curl -fsS -X POST "https://$FQDN/publish?count=$COUNT" ; echo

START=$(date +%s)
FIRST_SCALE=""
PEAK=$(replicas)
while true; do
  NOW=$(date +%s); ELAPSED=$((NOW-START))
  R=$(replicas); A=$(active)
  [ "$R" -gt "$PEAK" ] && PEAK=$R
  if [ -z "$FIRST_SCALE" ] && [ "$R" -gt 1 ]; then FIRST_SCALE=$ELAPSED; fi
  echo "t=${ELAPSED}s replicas=$R active=$A"
  if [ "$A" = "0" ]; then break; fi
  sleep 5
done

END=$(date +%s); TOTAL=$((END-START))
echo
echo "---- RESULT ----"
echo "messages:            $COUNT"
echo "drain time:          ${TOTAL}s"
echo "throughput (approx): $(( COUNT / (TOTAL>0?TOTAL:1) )) msg/s"
echo "peak replicas:       $PEAK"
echo "first scale-up at:   ${FIRST_SCALE:-never} s after publish"
