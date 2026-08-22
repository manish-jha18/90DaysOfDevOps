#!/bin/bash
# Checks each of the three pipelines end to end, rather than just
# "are the containers running".
set -uo pipefail

pass=0; fail=0
check() {
  printf '%-45s' "$1"
  if eval "$2" >/dev/null 2>&1; then echo "OK"; pass=$((pass+1))
  else echo "FAIL"; fail=$((fail+1)); fi
}

echo "--- containers ---"
for c in prometheus grafana loki promtail tempo otel-collector alertmanager cadvisor; do
  check "$c running" "docker ps --format '{{.Names}}' | grep -qx $c"
done

echo
echo "--- endpoints ---"
check "prometheus ready"     "curl -sf http://localhost:9090/-/ready"
check "grafana healthy"      "curl -sf http://localhost:3000/api/health"
check "loki ready"           "curl -sf http://localhost:3100/ready"
check "tempo ready"          "curl -sf http://localhost:3200/ready"
check "alertmanager healthy" "curl -sf http://localhost:9093/-/healthy"
check "otel collector healthy"    "curl -sf http://localhost:13133"

echo
echo "--- metrics pipeline ---"
check "all prometheus targets up" \
  "test \$(curl -sf 'http://localhost:9090/api/v1/targets?state=active' | jq '[.data.activeTargets[] | select(.health!=\"up\")] | length') -eq 0"
check "node metrics present" \
  "test \$(curl -sf 'http://localhost:9090/api/v1/query?query=up{job=\"node-exporter\"}' | jq '.data.result | length') -gt 0"
check "container metrics present" \
  "test \$(curl -sf 'http://localhost:9090/api/v1/query?query=container_memory_working_set_bytes' | jq '.data.result | length') -gt 0"

echo
echo "--- logs pipeline ---"
check "loki has labels" \
  "test \$(curl -sf 'http://localhost:3100/loki/api/v1/labels' | jq '.data | length') -gt 0"
check "loki has container logs" \
  "test \$(curl -sf 'http://localhost:3100/loki/api/v1/label/container/values' | jq '.data | length') -gt 0"

echo
echo "--- rules ---"
check "alert rules loaded" \
  "test \$(curl -sf http://localhost:9090/api/v1/rules | jq '[.data.groups[].rules[]] | length') -gt 0"

echo
echo "passed: $pass   failed: $fail"
exit $((fail > 0))
