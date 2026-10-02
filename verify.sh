#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
tmp=$(mktemp -d)
pf_pid=''
cleanup() { [[ -z $pf_pid ]] || kill "$pf_pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'echo "Verification failed at line $LINENO" >&2; kubectl get pods -A >&2 || true' ERR
for command in kubectl curl jq; do command -v "$command" >/dev/null; done
kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl -n demo rollout status deployment/nginx --timeout=120s
kubectl -n monitoring rollout status deployment/prometheus --timeout=120s
kubectl -n logging rollout status daemonset/fluentd --timeout=120s
kubectl wait --for=condition=Accepted gatewayclass/mts-envoy --timeout=120s
kubectl -n demo wait --for=condition=Programmed gateway/demo --timeout=120s
kubectl -n demo get httproute/nginx -o json | jq -e '.status.parents | length > 0' >/dev/null
kubectl -n demo get httproute/nginx -o json | jq -e '.status.parents | all(.conditions | any(.type=="Accepted" and .status=="True") and any(.type=="ResolvedRefs" and .status=="True"))' >/dev/null
node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
base_url=${BASE_URL:-http://${node_ip}:30080}
http_code=$(curl -sS --max-time 10 -o "$tmp/body" -w '%{http_code}' "$base_url/")
[[ $http_code == 200 && $(cat "$tmp/body") == 'Hello World!' ]]
echo 'PASS: Gateway HTTP 200 and Hello World!'
prom_port=${PROMETHEUS_LOCAL_PORT:-19090}
kubectl -n monitoring port-forward service/prometheus "$prom_port:9090" >"$tmp/port-forward.log" 2>&1 &
pf_pid=$!
ready=false
for _ in {1..30}; do
  if ! kill -0 "$pf_pid" 2>/dev/null; then cat "$tmp/port-forward.log" >&2; exit 1; fi
  if curl -fsS "http://127.0.0.1:$prom_port/-/ready" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ $ready == true ]]
query() { curl -fsSG --max-time 10 "http://127.0.0.1:$prom_port/api/v1/query" --data-urlencode "query=$1"; }
healthy=false
for _ in {1..30}; do
  proxy=$(query 'up{job="envoy-proxy"}')
  controller=$(query 'up{job="envoy-gateway"}')
  if jq -e '.status=="success" and (.data.result | length > 0) and (.data.result | all(.value[1]=="1"))' <<<"$proxy" >/dev/null && \
     jq -e '.status=="success" and (.data.result | length > 0) and (.data.result | all(.value[1]=="1"))' <<<"$controller" >/dev/null; then healthy=true; break; fi
  sleep 2
done
[[ $healthy == true ]]
before=$(query 'sum(envoy_http_downstream_rq_total)' | jq -er '.data.result[0].value[1] | tonumber')
for _ in {1..10}; do curl -fsS "$base_url/" >/dev/null; done
marker="check-$(date +%s)-$RANDOM"
[[ $(curl -sS -o /dev/null -w '%{http_code}' "$base_url/$marker") == 404 ]]
increased=false
for _ in {1..20}; do
  after=$(query 'sum(envoy_http_downstream_rq_total)' | jq -er '.data.result[0].value[1] | tonumber')
  if jq -en --argjson before "$before" --argjson after "$after" '$after >= ($before + 11)' >/dev/null; then increased=true; break; fi
  sleep 2
done
[[ $increased == true ]]
echo "PASS: Prometheus targets UP; HTTP counter $before -> $after"
collected=false
for _ in {1..30}; do
  if kubectl -n logging exec daemonset/fluentd -- sh -c "grep '$marker' /collected/nginx*.log" >"$tmp/collected" 2>/dev/null; then
    if grep -q '"stream":"stdout"' "$tmp/collected" && grep -q '"stream":"stderr"' "$tmp/collected"; then collected=true; break; fi
  fi
  sleep 2
done
[[ $collected == true ]]
echo "PASS: Fluentd collected access and error records for $marker"
cat "$tmp/collected"
echo 'PASS: All mandatory component checks passed.'
