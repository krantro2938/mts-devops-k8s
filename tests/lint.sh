#!/usr/bin/env bash
# Static validation of the whole repository (run locally with `make lint`, and in CI):
#   ShellCheck  - all scripts
#   yamllint    - all YAML
#   helm lint   - local chart
#   kubeconform - every rendered manifest (our files + all Helm charts with our values),
#                 validated against Kubernetes v${K8S_VERSION} and the CRD schemas
#                 (Gateway API, Envoy Gateway, Prometheus Operator, cert-manager).
# shellcheck source=../scripts/common.sh
source "$(dirname "$0")/../scripts/common.sh"
need helm kubeconform kubectl python3
cd "$REPO_ROOT"

OUT="${LINT_OUT:-$(mktemp -d)}"
mkdir -p "$OUT/rendered" "$OUT/schemas"

if command -v shellcheck >/dev/null; then
  log "shellcheck"
  shellcheck -x scripts/*.sh tests/*.sh
else
  warn "shellcheck not installed, skipping"
fi

if command -v yamllint >/dev/null; then
  log "yamllint"
  yamllint -s -c .yamllint.yaml .
else
  warn "yamllint not installed, skipping"
fi

log "helm lint (deploy/app/hello)"
helm lint --strict deploy/app/hello

log "Rendering manifests"
r() { local name=$1; shift; "$@" >"$OUT/rendered/${name}.yaml"; }
r 00-namespaces cat deploy/namespaces.yaml
r 01-storage kubectl kustomize deploy/storage
r 02-gateway kubectl kustomize deploy/gateway
r 03-monitoring kubectl kustomize deploy/monitoring
r 04-logging kubectl kustomize deploy/logging
r 05-cert-issuers cat deploy/cert-manager/issuers.yaml
r 10-app helm template hello deploy/app/hello -n demo
r 20-calico helm template calico tigera-operator --repo https://docs.tigera.io/calico/charts \
  --version "$CALICO_VERSION" -n tigera-operator -f deploy/cni/calico-values.yaml
r 21-metrics-server helm template metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server \
  --version "$METRICS_SERVER_CHART_VERSION" -n kube-system -f deploy/metrics-server/values.yaml
r 22-kps helm template kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
  --version "$KUBE_PROMETHEUS_STACK_VERSION" -n monitoring -f deploy/monitoring/kube-prometheus-stack-values.yaml
r 23-cert-manager helm template cert-manager cert-manager --repo https://charts.jetstack.io \
  --version "$CERT_MANAGER_VERSION" -n cert-manager -f deploy/cert-manager/values.yaml
r 24-eg helm template eg oci://docker.io/envoyproxy/gateway-helm --version "$ENVOY_GATEWAY_VERSION" \
  -n envoy-gateway-system --skip-crds -f deploy/envoy-gateway/values.yaml
r 25-victorialogs helm template victorialogs victoria-logs-single --repo https://victoriametrics.github.io/helm-charts \
  --version "$VICTORIA_LOGS_CHART_VERSION" -n logging -f deploy/logging/victorialogs-values.yaml
r 26-fluentd helm template fluentd fluentd --repo https://fluent.github.io/helm-charts \
  --version "$FLUENTD_CHART_VERSION" -n logging -f deploy/logging/fluentd-values.yaml

log "Extracting CRD schemas"
{
  helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version "$ENVOY_GATEWAY_VERSION" \
    --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard --set crds.envoyGateway.enabled=true
  cat "$OUT/rendered/22-kps.yaml" "$OUT/rendered/23-cert-manager.yaml" "$OUT/rendered/20-calico.yaml"
  helm show crds kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts \
    --version "$KUBE_PROMETHEUS_STACK_VERSION" 2>/dev/null || true
} | python3 tests/crd2schema.py "$OUT/schemas"

# Calico's Installation CRD is created by the tigera-operator at runtime (not shipped in the chart).
log "kubeconform (Kubernetes ${K8S_VERSION})"
kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" \
  -schema-location default \
  -schema-location "$OUT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -skip CustomResourceDefinition,Installation \
  "$OUT/rendered/"*.yaml

log "Our own custom resources must have a schema (no silent skips)"
kubeconform -strict -summary -kubernetes-version "${K8S_VERSION}" \
  -schema-location default \
  -schema-location "$OUT/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$OUT/rendered/0"*.yaml "$OUT/rendered/10-app.yaml"

ok "lint passed"
