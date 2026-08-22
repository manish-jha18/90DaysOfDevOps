#!/usr/bin/env bash
# Day 83 - bring the whole EKS stack up, in dependency order.
set -euo pipefail

CLUSTER="${CLUSTER:-devboard}"
REGION="${REGION:-us-west-2}"
NS="${NS:-devboard}"

step() { printf '\n=== %s ===\n' "$1"; }

step "1/7 connect kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl config current-context

step "2/7 wait for nodes"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide

step "3/7 Gateway API CRDs"
# Gateway API is NOT part of kubernetes. The CRDs must exist before any
# controller that implements them, or envoy-gateway crash-loops.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

step "4/7 Envoy Gateway"
helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.1.2 -n envoy-gateway-system --create-namespace --wait
kubectl wait --for=condition=Available deploy/envoy-gateway \
  -n envoy-gateway-system --timeout=300s

step "5/7 cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
# enableGatewayAPI is off by default - without it the http01 solver cannot
# create the HTTPRoute it needs and every certificate stays Pending
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.16.1 -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --set config.apiVersion=controller.config.cert-manager.io/v1alpha1 \
  --set config.kind=ControllerConfiguration \
  --set config.enableGatewayAPI=true \
  --wait

step "6/7 External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version 0.10.4 -n external-secrets --create-namespace \
  --set installCRDs=true --wait

step "7/7 DevBoard"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ../../day-82/manifests/external-secrets/
kubectl apply -f ../../day-82/manifests/storage/storageclass.yaml
helm upgrade --install devboard ../../day-80/helm/devboard \
  -n "$NS" -f ../../day-80/helm/devboard/values-prod.yaml \
  --atomic --timeout 10m
kubectl apply -f ../../day-82/manifests/gateway/
kubectl apply -f ../../day-82/manifests/cert-manager/

printf '\nDone. Run ./validate.sh to check it.\n'
