#!/usr/bin/env bash
# Generate mixed demo traffic through the Gateway so the dashboards have data:
# v1 / v2 / canary / 404 / 500 requests.  Usage: ./scripts/generate-traffic.sh [seconds=60] [rps=5]
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
need kubectl curl
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

DURATION="${1:-60}"
RPS="${2:-5}"
IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
HTTP="http://${IP}:${GATEWAY_HTTP_NODEPORT}"

log "Sending ~${RPS} req/s to ${HTTP} for ${DURATION}s (Ctrl-C to stop)"
end=$((SECONDS + DURATION))
n=0
while ((SECONDS < end)); do
  for _ in $(seq 1 "$RPS"); do
    case $((RANDOM % 10)) in
      0 | 1 | 2 | 3) path=/ host="" ;;
      4 | 5) path=/v2 host="" ;;
      6 | 7) path=/ host="canary.${DEMO_DOMAIN}" ;;
      8) path="/not-found-$RANDOM" host="" ;;
      9) path=/error host="" ;;
    esac
    curl -s -o /dev/null --max-time 5 ${host:+-H "Host: $host"} "${HTTP}${path}" &
    n=$((n + 1))
  done
  wait
  sleep 1
done
ok "sent ${n} requests"
