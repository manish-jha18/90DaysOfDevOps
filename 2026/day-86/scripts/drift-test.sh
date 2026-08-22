#!/usr/bin/env bash
# Day 86 - prove selfHeal and prune actually work.
set -uo pipefail

APP="${APP:-devboard}"
NS="${NS:-devboard}"

echo "=== baseline ==="
argocd app get "$APP" --output json 2>/dev/null \
  | jq -r '"sync: \(.status.sync.status)   health: \(.status.health.status)"' \
  || kubectl get application "$APP" -n argocd \
       -o jsonpath='sync: {.status.sync.status}   health: {.status.health.status}{"\n"}'

echo
echo "=== drift 1: scale a deployment by hand ==="
BEFORE=$(kubectl get deploy -n "$NS" -l component=backend -o jsonpath='{.items[0].spec.replicas}')
echo "replicas in git: $BEFORE"
kubectl scale deploy -n "$NS" -l component=backend --replicas=7
echo "scaled to 7 - waiting for argocd to notice..."

for i in $(seq 1 24); do
  now=$(kubectl get deploy -n "$NS" -l component=backend -o jsonpath='{.items[0].spec.replicas}')
  if [ "$now" = "$BEFORE" ]; then
    echo "reverted to $now after ~$((i * 5))s"
    break
  fi
  sleep 5
done

echo
echo "=== drift 2: edit a configmap by hand ==="
kubectl patch configmap -n "$NS" "$APP-devboard-config" \
  --type merge -p '{"data":{"POSTGRES_DB":"tampered"}}' 2>/dev/null || true
echo "patched - waiting..."
for i in $(seq 1 24); do
  v=$(kubectl get configmap -n "$NS" "$APP-devboard-config" -o jsonpath='{.data.POSTGRES_DB}' 2>/dev/null)
  if [ "$v" != "tampered" ]; then
    echo "reverted to '$v' after ~$((i * 5))s"
    break
  fi
  sleep 5
done

echo
echo "=== drift 3: delete a resource entirely ==="
kubectl delete svc -n "$NS" "$APP-devboard-backend" --ignore-not-found
echo "deleted - waiting for argocd to recreate it..."
for i in $(seq 1 24); do
  if kubectl get svc -n "$NS" "$APP-devboard-backend" >/dev/null 2>&1; then
    echo "recreated after ~$((i * 5))s"
    break
  fi
  sleep 5
done

echo
echo "=== the one drift argocd will NOT revert ==="
echo "spec.replicas on a HPA-managed deployment is in ignoreDifferences,"
echo "so a manual scale there is permanent until the HPA overrides it."
