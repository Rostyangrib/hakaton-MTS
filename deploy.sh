#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Deployment failed at line $LINENO" >&2; kubectl get pods -A >&2 || true' ERR
cd "$(dirname "${BASH_SOURCE[0]}")"
source config/versions.env
for command in kubectl helm curl jq; do
  command -v "$command" >/dev/null || { echo "Missing command: $command. Run bootstrap first." >&2; exit 1; }
done
[[ $(kubectl get nodes -l mts-devops/managed=true -o json | jq '.items | length') == 1 ]] || {
  echo 'Expected one project-managed node. Refusing to deploy into an unknown cluster.' >&2; exit 1;
}
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$ENVOY_GATEWAY_VERSION" --namespace envoy-gateway-system --create-namespace \
  --values config/envoy-values.yaml --wait --timeout 10m
kubectl wait --for=condition=Established crd/envoyproxies.gateway.envoyproxy.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=120s
kubectl apply -f manifests/app.yaml
kubectl -n demo rollout status deployment/nginx --timeout=300s
kubectl apply -f manifests/gateway.yaml
kubectl wait --for=condition=Accepted gatewayclass/mts-envoy --timeout=180s
kubectl -n demo wait --for=condition=Programmed gateway/demo --timeout=300s
kubectl apply -f manifests/monitoring.yaml
kubectl apply -f manifests/logging.yaml
# ConfigMap changes need process restart, but an unchanged deployment should not restart.
for item in 'demo nginx nginx-config' 'monitoring prometheus prometheus-config' 'logging fluentd fluentd-config'; do
  read -r namespace workload config <<<"$item"
  hash=$(kubectl -n "$namespace" get configmap "$config" -o json | jq -S '.data' | sha256sum | cut -d' ' -f1)
  kind=deployment
  [[ $workload == fluentd ]] && kind=daemonset
  kubectl -n "$namespace" patch "$kind/$workload" --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"mts-devops/config-hash\":\"$hash\"}}}}}"
  kubectl -n "$namespace" rollout status "$kind/$workload" --timeout=300s
done
echo 'Deployment ready. Run ./verify.sh.'
