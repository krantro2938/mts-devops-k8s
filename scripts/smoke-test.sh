#!/usr/bin/env bash
# End-to-end verification of the deployed solution. Exit code 0 = everything works.
#
#   ./scripts/smoke-test.sh
#
# Checks: cluster health, Gateway API resources, routing features (path / header /
# hostname / weights / TLS / redirect / rate limit / basic auth), Prometheus
# targets and metrics, and that a unique request is found in the logs collected
# by Fluentd (VictoriaLogs).

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
trap - ERR
set +e

need kubectl curl jq openssl
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

IP="${NODE_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
HTTP="http://${IP}:${GATEWAY_HTTP_NODEPORT}"
DOMAIN="${DEMO_DOMAIN}"
RUN_ID="smoke-$(date +%s)-$RANDOM"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
check() { # <description> <command...>
  local desc=$1
  shift
  if "$@" >"${TMP}/out" 2>&1; then
    ok "$desc"
    PASS=$((PASS + 1))
  else
    printf '%s ✘%s  %s\n' "${C_RED}" "${C_OFF}" "$desc"
    sed 's/^/      /' "${TMP}/out" | tail -n 15
    FAIL=$((FAIL + 1))
  fi
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }
prom_query() { # <promql> -> JSON result array
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/query?query=$(urlenc "$1")" | jq -c '.data.result'
}
logs_query() { # <logsql> -> JSON lines
  kubectl get --raw "/api/v1/namespaces/logging/services/victorialogs:9428/proxy/select/logsql/query?query=$(urlenc "$1")&limit=20"
}
expect_body() { # <expected-substring> <curl args...>
  local want=$1
  shift
  local body
  body=$(curl -sS --max-time 10 "$@") || return 1
  grep -qF -- "$want" <<<"$body" || { echo "expected '$want' in: $body"; return 1; }
}
expect_code() { # <code> <curl args...>
  local want=$1
  shift
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$@") || return 1
  [[ "$code" == "$want" ]] || { echo "expected HTTP $want, got $code"; return 1; }
}

# --------------------------------------------------------------------------
log "Cluster"
check "all nodes Ready" bash -c "! kubectl get nodes --no-headers | grep -v ' Ready '"
check "Kubernetes version is v${K8S_VERSION}" bash -c "kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}' | grep -q 'v${K8S_VERSION}'"
check "no failing pods in solution namespaces" bash -c "
  ! kubectl get pods -A --no-headers | grep -E '^(kube-system|calico-system|tigera-operator|cert-manager|envoy-gateway-system|gateway|demo|monitoring|logging|local-path-storage) ' |
    grep -vE 'Running|Completed'"

log "Gateway API resources"
check "GatewayClass 'envoy' Accepted" kubectl wait --for=condition=Accepted gatewayclass/envoy --timeout=5s
check "Gateway gateway/edge Programmed" kubectl -n gateway wait --for=condition=Programmed gateway/edge --timeout=5s
for r in demo/hello demo/hello-v2-host demo/hello-canary demo/hello-secure-redirect monitoring/grafana monitoring/prometheus logging/victorialogs; do
  check "HTTPRoute $r Accepted + ResolvedRefs" bash -c "
    kubectl -n ${r%/*} get httproute ${r#*/} -o json |
      jq -e '[.status.parents[].conditions[] | select(.type==\"Accepted\" or .type==\"ResolvedRefs\") | .status] | length > 0 and all(. == \"True\")'"
done

log "Application through the Gateway (${HTTP})"
check "GET / -> 'Hello World!' from v1" expect_body "Hello World!" "${HTTP}/"
check "GET / -> served by v1" expect_body "version: v1" "${HTTP}/"
check "response header X-Served-By: envoy-gateway (ResponseHeaderModifier)" \
  bash -c "curl -sSI --max-time 10 '${HTTP}/' | grep -qi '^x-served-by: envoy-gateway'"
check "path routing: GET /v2 -> v2" expect_body "version: v2" "${HTTP}/v2"
check "path routing: GET /v1 -> v1" expect_body "version: v1" "${HTTP}/v1"
check "header routing: X-Version: v2 -> v2" expect_body "version: v2" -H "X-Version: v2" "${HTTP}/"
check "hostname routing: v2.${DOMAIN} -> v2" expect_body "version: v2" -H "Host: v2.${DOMAIN}" "${HTTP}/"
check "unknown path -> 404" expect_code 404 "${HTTP}/does-not-exist"

canary() {
  local v1=0 v2=0
  for _ in $(seq 1 40); do
    case "$(curl -s --max-time 5 -H "Host: canary.${DOMAIN}" "${HTTP}/")" in
      *"version: v1"*) v1=$((v1 + 1)) ;;
      *"version: v2"*) v2=$((v2 + 1)) ;;
    esac
    sleep 0.25 # stay below the 10 rps rate limit of this route
  done
  echo "v1=${v1} v2=${v2}"
  ((v1 > v2 && v2 > 0))
}
check "traffic splitting: canary.${DOMAIN} 80/20 (both versions answer, v1 dominates)" canary

ratelimit() {
  seq 1 60 | xargs -P 30 -I{} curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
    -H "Host: canary.${DOMAIN}" "${HTTP}/" >"${TMP}/codes"
  sort "${TMP}/codes" | uniq -c
  grep -q '^429$' "${TMP}/codes"
}
check "rate limiting: burst to canary.${DOMAIN} gets HTTP 429" ratelimit
sleep 1

kubectl -n cert-manager get secret mts-demo-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"${TMP}/ca.crt"
check "HTTPS (TLS terminated on Gateway, cert verified with demo CA)" expect_body "Hello World!" \
  --cacert "${TMP}/ca.crt" --resolve "hello.${DOMAIN}:${GATEWAY_HTTPS_NODEPORT}:${IP}" \
  "https://hello.${DOMAIN}:${GATEWAY_HTTPS_NODEPORT}/"
check "HTTP -> HTTPS redirect for secure.${DOMAIN} (301)" bash -c "
  curl -sSI --max-time 10 -H 'Host: secure.${DOMAIN}' '${HTTP}/' | grep -qi '^location: https://secure.${DOMAIN}:${GATEWAY_HTTPS_NODEPORT}/'"

PASSWORD="$(kubectl -n monitoring get secret ops-credentials -o jsonpath='{.data.password}' | base64 -d)"
check "Prometheus UI via Gateway without credentials -> 401" expect_code 401 -H "Host: prometheus.${DOMAIN}" "${HTTP}/-/ready"
check "Prometheus UI via Gateway with Basic Auth -> 200" expect_code 200 -u "admin:${PASSWORD}" -H "Host: prometheus.${DOMAIN}" "${HTTP}/-/ready"
check "Grafana via Gateway -> healthy" expect_body '"database"' -H "Host: grafana.${DOMAIN}" "${HTTP}/api/health"
check "VictoriaLogs via Gateway with Basic Auth -> 200" expect_code 200 -u "admin:${PASSWORD}" -H "Host: logs.${DOMAIN}" "${HTTP}/health"

# --------------------------------------------------------------------------
log "Traffic for metrics and logs (run id ${RUN_ID})"
curl -s -o /dev/null -H "X-Request-ID: ${RUN_ID}" "${HTTP}/?probe=${RUN_ID}"
curl -s -o /dev/null -H "X-Request-ID: ${RUN_ID}-err" "${HTTP}/missing-${RUN_ID}"
for _ in $(seq 1 20); do curl -s -o /dev/null "${HTTP}/"; curl -s -o /dev/null "${HTTP}/v2"; done
echo "   sent 43 requests"

log "Monitoring (Prometheus)"
prom_nonzero() { # <promql>
  local res
  for _ in $(seq 1 18); do
    res=$(prom_query "$1")
    if jq -e 'length > 0 and (map(.value[1] | tonumber) | add) > 0' <<<"$res" >/dev/null 2>&1; then
      echo "$res" | jq -c 'map({metric: .metric | del(.__name__), value: .value[1]}) | .[0:3]'
      return 0
    fi
    sleep 10
  done
  echo "no data for: $1 -> $res"
  return 1
}
check "target nginx exporter (demo app) UP" prom_nonzero 'up{namespace="demo", container="exporter"}'
check "target Envoy proxies (Gateway) UP" prom_nonzero 'up{namespace="envoy-gateway-system", job=~".*envoy-proxy.*"}'
check "target Fluentd UP" prom_nonzero 'up{namespace="logging", job=~".*fluentd.*"}'
check "target node-exporter / kube-state-metrics / kubelet UP" prom_nonzero 'up{job=~"node-exporter|kube-state-metrics|kubelet"}'
check "metric nginx_http_requests_total > 0" prom_nonzero 'sum(nginx_http_requests_total{namespace="demo"})'
check "metric envoy_cluster_upstream_rq_total (HTTPRoute demo) > 0" prom_nonzero 'sum(envoy_cluster_upstream_rq_total{envoy_cluster_name=~"httproute/demo/.*"})'
check "metric request latency histogram present" prom_nonzero 'sum(envoy_cluster_upstream_rq_time_count{envoy_cluster_name=~"httproute/demo/.*"})'
check "metric fluentd_output_status_emit_records (to VictoriaLogs) > 0" prom_nonzero 'sum(fluentd_output_status_emit_records{plugin_id="out_victorialogs"})'
targets_down() {
  local down
  down=$(prom_query 'up == 0' | jq -r '.[].metric.job' | sort -u)
  [[ -z "$down" ]] || { echo "targets down: $down"; return 1; }
}
check "no Prometheus target is DOWN" targets_down

log "Logging (Fluentd -> VictoriaLogs)"
log_found() { # <logsql> <jq filter on each line>
  local out
  for _ in $(seq 1 18); do
    out=$(logs_query "$1")
    if [[ -n "$out" ]] && jq -se "map(select($2)) | length > 0" <<<"$out" >/dev/null 2>&1; then
      jq -sc "map(select($2))[0] | {time: ._time, pod: .[\"kubernetes.pod_name\"], log_type, status, uri, path, request_id, msg: ._msg} | with_entries(select(.value != null))" <<<"$out"
      return 0
    fi
    sleep 10
  done
  echo "not found: $1"
  return 1
}
check "nginx ACCESS log of request ${RUN_ID} collected (parsed: status=200)" \
  log_found "_time:15m kubernetes.namespace_name:demo \"${RUN_ID}\"" '.log_type == "access" and (.status | tostring) == "200"'
check "nginx ERROR log for missing file collected" \
  log_found "_time:15m kubernetes.namespace_name:demo \"missing-${RUN_ID}\"" '.log_type == "error"'
check "Gateway (Envoy) access log of the same request collected" \
  log_found "_time:15m kubernetes.namespace_name:envoy-gateway-system \"${RUN_ID}\"" '.request_id != null'

echo
if ((FAIL == 0)); then
  ok "ALL ${PASS} CHECKS PASSED"
else
  die "${FAIL} of $((PASS + FAIL)) checks FAILED"
fi
