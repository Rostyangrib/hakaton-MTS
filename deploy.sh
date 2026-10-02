#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Deployment failed at line $LINENO" >&2; kubectl get pods -A >&2 || true' ERR
cd "$(dirname "${BASH_SOURCE[0]}")"
source config/versions.env
component=${1:-all}
case "$component" in all|app|gateway|monitoring|logging) ;; *) echo 'Usage: ./deploy.sh [all|app|gateway|monitoring|logging]' >&2; exit 2 ;; esac
for command in kubectl helm curl jq; do
  command -v "$command" >/dev/null || { echo "Missing command: $command. Run bootstrap first." >&2; exit 1; }
done
[[ $(kubectl get nodes -l mts-devops/managed=true -o json | jq '.items | length') == 1 ]] || {
  echo 'Expected one project-managed node. Refusing to deploy into an unknown cluster.' >&2; exit 1;
}
# ConfigMap changes need process restart, but an unchanged deployment should not restart.
configure_workload() {
  local namespace=$1 kind=$2 workload=$3 config=$4 hash
  hash=$(kubectl -n "$namespace" get configmap "$config" -o json | jq -S '.data' | sha256sum | cut -d' ' -f1)
  kubectl -n "$namespace" patch "$kind/$workload" --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"mts-devops/config-hash\":\"$hash\"}}}}}"
  kubectl -n "$namespace" rollout status "$kind/$workload" --timeout=300s
}
if [[ $component == all || $component == app ]]; then
  kubectl apply -f manifests/app.yaml
  configure_workload demo deployment nginx nginx-config
fi
if [[ $component == all || $component == gateway ]]; then
  kubectl -n demo get service/nginx >/dev/null
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$ENVOY_GATEWAY_VERSION" --namespace envoy-gateway-system --create-namespace \
    --values config/envoy-values.yaml --wait --timeout 10m
  kubectl wait --for=condition=Established crd/envoyproxies.gateway.envoyproxy.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=120s
  kubectl apply -f manifests/gateway.yaml
  kubectl wait --for=condition=Accepted gatewayclass/mts-envoy --timeout=180s
  kubectl -n demo wait --for=condition=Programmed gateway/demo --timeout=300s
fi
if [[ $component == all || $component == monitoring ]]; then
  kubectl get namespace/envoy-gateway-system >/dev/null
  kubectl apply -f manifests/monitoring.yaml
  configure_workload monitoring deployment prometheus prometheus-config
fi
if [[ $component == all || $component == logging ]]; then
  kubectl apply -f manifests/logging.yaml
  configure_workload logging daemonset fluentd fluentd-config
fi
echo "Deployment component '$component' ready. Full verification: ./verify.sh."
