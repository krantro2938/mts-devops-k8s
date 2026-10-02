#!/usr/bin/env bash
# Deploy every in-cluster component of the solution (idempotent, safe to re-run).
#
#   ./scripts/deploy.sh            # everything
#   ./scripts/deploy.sh <step>...  # only selected steps, e.g. ./scripts/deploy.sh app
#
# Steps (in order): namespaces cni storage metrics-server monitoring cert-manager
#                   gateway-controller gateway logging app
#
# Every step uses declarative tools only (helm upgrade --install, kubectl apply
# --server-side), so a second run converges to the same state.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

need kubectl helm openssl
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
D="${REPO_ROOT}/deploy"

kubectl version --request-timeout=10s >/dev/null 2>&1 ||
  die "cannot reach the cluster (KUBECONFIG=${KUBECONFIG}). Run 'sudo ./scripts/bootstrap-node.sh' first."

HELM_ARGS=(--wait --timeout 10m --history-max 5)

apply() { kubectl apply --server-side --force-conflicts --field-manager=mts-deploy "$@"; }

wait_rollout() { # <namespace> <kind/name>...
  local ns=$1
  shift
  local r
  for r in "$@"; do kubectl -n "$ns" rollout status "$r" --timeout=600s; done
}

# --------------------------------------------------------------------------
step_namespaces() {
  log "Namespaces (Pod Security Admission labels)"
  apply -f "${D}/namespaces.yaml"
}

step_cni() {
  log "Calico CNI ${CALICO_VERSION} (CRDs + tigera-operator)"
  # Since v3.32 the CRDs ship in a separate chart; applied server-side so re-runs upgrade them.
  helm template calico-crds crd.projectcalico.org.v1 \
    --repo https://docs.tigera.io/calico/charts --version "${CALICO_VERSION}" | apply -f - >/dev/null
  kubectl wait --for=condition=Established crd --all --timeout=120s >/dev/null
  # Client-side (3-way merge) apply: the operator writes defaults into the
  # Installation spec (e.g. ipPools); with server-side apply a re-run would
  # conflict with the "operator" field manager.
  helm upgrade --install calico tigera-operator \
    --repo https://docs.tigera.io/calico/charts --version "${CALICO_VERSION}" \
    --namespace tigera-operator -f "${D}/cni/calico-values.yaml" --server-side=false "${HELM_ARGS[@]}"
  log "Waiting for the operator to roll out calico-node"
  retry 60 5 kubectl get ns calico-system >/dev/null 2>&1 || die "calico-system namespace not created"
  retry 60 5 kubectl -n calico-system get daemonset calico-node >/dev/null 2>&1 || die "calico-node not created"
  wait_rollout calico-system daemonset/calico-node
  kubectl wait --for=condition=Ready nodes --all --timeout=300s
  ok "nodes are Ready"
}

step_storage() {
  log "local-path-provisioner ${LOCAL_PATH_PROVISIONER_VERSION} (default StorageClass)"
  apply -k "${D}/storage"
  wait_rollout local-path-storage deployment/local-path-provisioner
}

step_metrics_server() {
  log "metrics-server (resource metrics for HPA / kubectl top)"
  # ServiceMonitor CRD may not exist yet on the very first run -> enable it on later runs.
  local sm=false
  kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 && sm=true
  helm upgrade --install metrics-server metrics-server \
    --repo https://kubernetes-sigs.github.io/metrics-server --version "${METRICS_SERVER_CHART_VERSION}" \
    --namespace kube-system -f "${D}/metrics-server/values.yaml" --set serviceMonitor.enabled=$sm "${HELM_ARGS[@]}"
}

# Random admin password for Grafana / Basic Auth of Prometheus, Alertmanager, VictoriaLogs.
# Generated once and stored only in the cluster (Secret monitoring/ops-credentials).
ensure_credentials() {
  local pass
  if ! kubectl -n monitoring get secret ops-credentials >/dev/null 2>&1; then
    log "Generating admin credentials (Secret monitoring/ops-credentials)"
    pass="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    kubectl -n monitoring create secret generic ops-credentials \
      --from-literal=username=admin --from-literal=password="${pass}"
  fi
  pass="$(kubectl -n monitoring get secret ops-credentials -o jsonpath='{.data.password}' | base64 -d)"
  # htpasswd ({SHA}) for the Envoy Gateway SecurityPolicy, in every namespace that uses it.
  local htpasswd ns
  htpasswd="admin:{SHA}$(printf '%s' "${pass}" | openssl dgst -binary -sha1 | openssl base64)"
  for ns in monitoring logging; do
    kubectl -n "$ns" create secret generic ops-basic-auth --from-literal=.htpasswd="${htpasswd}" \
      --dry-run=client -o yaml | apply -f - >/dev/null
  done
}

step_monitoring() {
  log "kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION} (Prometheus, Alertmanager, Grafana, exporters)"
  ensure_credentials
  helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
    --namespace monitoring -f "${D}/monitoring/kube-prometheus-stack-values.yaml" "${HELM_ARGS[@]}"
  # metrics-server was installed before the ServiceMonitor CRD existed
  step_metrics_server
}

step_cert_manager() {
  log "cert-manager ${CERT_MANAGER_VERSION} + private CA"
  helm upgrade --install cert-manager cert-manager \
    --repo https://charts.jetstack.io --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager -f "${D}/cert-manager/values.yaml" "${HELM_ARGS[@]}"
  # the webhook may need a few seconds before it accepts resources
  retry 30 5 apply -f "${D}/cert-manager/issuers.yaml" >/dev/null || die "cannot create cert-manager issuers"
  kubectl -n cert-manager wait --for=condition=Ready certificate/mts-demo-ca --timeout=120s
}

step_gateway_controller() {
  log "Gateway API CRDs + Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
  # CRDs are applied separately (server-side) so they are also upgraded on re-runs;
  # helm itself never upgrades CRDs. This is the method recommended by Envoy Gateway.
  helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version "${ENVOY_GATEWAY_VERSION}" \
    --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard \
    --set crds.envoyGateway.enabled=true | apply -f - >/dev/null
  kubectl wait --for=condition=Established crd --all --timeout=120s >/dev/null
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "${ENVOY_GATEWAY_VERSION}" \
    --namespace envoy-gateway-system --skip-crds -f "${D}/envoy-gateway/values.yaml" "${HELM_ARGS[@]}"
}

step_gateway() {
  log "GatewayClass, Gateway (HTTP :${GATEWAY_HTTP_NODEPORT}, HTTPS :${GATEWAY_HTTPS_NODEPORT}), TLS certificate"
  retry 12 5 apply -k "${D}/gateway" >/dev/null || die "cannot apply deploy/gateway"
  kubectl -n gateway wait --for=condition=Ready certificate/demo-local-wildcard --timeout=120s
  kubectl wait --for=condition=Accepted gatewayclass/envoy --timeout=120s
  kubectl -n gateway wait --for=condition=Programmed gateway/edge --timeout=300s
  # Data-plane pods of this Gateway
  wait_rollout envoy-gateway-system \
    "$(kubectl -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=edge -o name)"
  apply -k "${D}/monitoring" >/dev/null
}

step_logging() {
  log "VictoriaLogs (log storage) + Fluentd DaemonSet (log collector)"
  helm upgrade --install victorialogs victoria-logs-single \
    --repo https://victoriametrics.github.io/helm-charts --version "${VICTORIA_LOGS_CHART_VERSION}" \
    --namespace logging -f "${D}/logging/victorialogs-values.yaml" "${HELM_ARGS[@]}"
  helm upgrade --install fluentd fluentd \
    --repo https://fluent.github.io/helm-charts --version "${FLUENTD_CHART_VERSION}" \
    --namespace logging -f "${D}/logging/fluentd-values.yaml" "${HELM_ARGS[@]}"
  apply -k "${D}/logging" >/dev/null
}

step_app() {
  log "Demo application 'hello' (nginx v1 + v2, HTTPRoutes, policies, HPA, NetworkPolicy)"
  helm upgrade --install hello "${D}/app/hello" --namespace demo "${HELM_ARGS[@]}"
  wait_rollout demo deployment/hello-v1 deployment/hello-v2
  local r
  for r in hello hello-v2-host hello-canary hello-secure-redirect; do
    retry 24 5 bash -c "kubectl -n demo get httproute $r -o jsonpath='{.status.parents[*].conditions[?(@.type==\"Accepted\")].status}' | grep -q True" ||
      die "HTTPRoute demo/$r was not accepted by the Gateway"
  done
  ok "all HTTPRoutes accepted"
}

summary() {
  local ip
  ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  cat <<EOF

${C_GREEN}Deployment finished.${C_OFF}
  App via Gateway API:  curl http://${ip}:${GATEWAY_HTTP_NODEPORT}/
  HTTPS:                curl -k --resolve hello.${DEMO_DOMAIN}:${GATEWAY_HTTPS_NODEPORT}:${ip} https://hello.${DEMO_DOMAIN}:${GATEWAY_HTTPS_NODEPORT}/
  Smoke tests:          ./scripts/smoke-test.sh
  UIs (add to /etc/hosts: "${ip} grafana.${DEMO_DOMAIN} prometheus.${DEMO_DOMAIN} alertmanager.${DEMO_DOMAIN} logs.${DEMO_DOMAIN}"):
    http://grafana.${DEMO_DOMAIN}:${GATEWAY_HTTP_NODEPORT}  http://prometheus.${DEMO_DOMAIN}:${GATEWAY_HTTP_NODEPORT}  http://logs.${DEMO_DOMAIN}:${GATEWAY_HTTP_NODEPORT}
  Credentials:          make creds
EOF
}

ALL_STEPS=(namespaces cni storage metrics-server monitoring cert-manager gateway-controller gateway logging app)
STEPS=("$@")
((${#STEPS[@]})) || STEPS=("${ALL_STEPS[@]}")

for s in "${STEPS[@]}"; do
  fn="step_${s//-/_}"
  declare -F "$fn" >/dev/null || die "unknown step '$s' (valid: ${ALL_STEPS[*]})"
  "$fn"
done
((${#@})) || summary
