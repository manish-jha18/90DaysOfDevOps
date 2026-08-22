#!/usr/bin/env bash
# Day 83 - end to end validation.
# Checks that things WORK, not that objects exist.
set -uo pipefail

NS="${NS:-devboard}"
pass=0
fail=0

check() {
  printf '%-52s' "$1"
  if eval "$2" >/dev/null 2>&1; then
    echo "OK"
    pass=$((pass + 1))
  else
    echo "FAIL"
    fail=$((fail + 1))
  fi
}

echo "--- cluster ---"
check "kubectl reaches the cluster" "kubectl get nodes"
check "all nodes Ready"             "test \$(kubectl get nodes --no-headers | grep -vc ' Ready ') -eq 0"
check "metrics-server responding"   "kubectl top nodes"

echo
echo "--- controllers ---"
check "Gateway API CRDs installed"  "kubectl get crd gateways.gateway.networking.k8s.io"
check "envoy-gateway available"     "kubectl wait --for=condition=Available deploy/envoy-gateway -n envoy-gateway-system --timeout=10s"
check "cert-manager available"      "kubectl wait --for=condition=Available deploy/cert-manager -n cert-manager --timeout=10s"
check "external-secrets available"  "kubectl wait --for=condition=Available deploy/external-secrets -n external-secrets --timeout=10s"

echo
echo "--- storage ---"
check "a default StorageClass exists" "kubectl get sc -o yaml | grep -q 'is-default-class: \"true\"'"
check "no PVC stuck Pending"          "test \$(kubectl get pvc -n $NS --no-headers 2>/dev/null | grep -c Pending) -eq 0"

echo
echo "--- secrets ---"
check "ClusterSecretStore Ready"      "kubectl get clustersecretstore aws-secrets-manager -o jsonpath='{.status.conditions[0].status}' | grep -q True"
check "ExternalSecret SecretSynced"   "kubectl get externalsecret devboard-secrets -n $NS -o jsonpath='{.status.conditions[0].reason}' | grep -q SecretSynced"
check "the Secret was materialised"   "kubectl get secret devboard-secrets -n $NS"

echo
echo "--- workloads ---"
check "postgres Ready"     "kubectl wait --for=condition=Ready pod -l component=postgres -n $NS --timeout=10s"
check "backend Available"  "kubectl wait --for=condition=Available deploy -l component=backend -n $NS --timeout=10s"
check "frontend Available" "kubectl wait --for=condition=Available deploy -l component=frontend -n $NS --timeout=10s"

echo
echo "--- networking ---"
check "Gateway Programmed"   "kubectl get gateway devboard-gateway -n $NS -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' | grep -q True"
check "Gateway has an address" "test -n \"\$(kubectl get gateway devboard-gateway -n $NS -o jsonpath='{.status.addresses[0].value}')\""
check "HTTPRoute Accepted"   "kubectl get httproute devboard-route -n $NS -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].status}' | grep -q True"

echo
echo "--- scaling ---"
check "HPA has metrics, not <unknown>" "kubectl get hpa -n $NS -o jsonpath='{.items[0].status.currentMetrics}' | grep -q averageUtilization"

echo
echo "--- end to end ---"
ADDR=$(kubectl get gateway devboard-gateway -n "$NS" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
if [ -n "$ADDR" ]; then
  check "frontend answers through the gateway" "curl -sf --max-time 10 -o /dev/null http://$ADDR/"
  check "backend health through the gateway"   "curl -sf --max-time 10 -o /dev/null http://$ADDR/api/health"
else
  echo "gateway has no address yet - skipping the HTTP checks"
fi

echo
echo "passed: $pass   failed: $fail"
exit $((fail > 0))
