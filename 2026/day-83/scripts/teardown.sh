#!/usr/bin/env bash
# Day 83 - complete teardown, in the order that actually works.
#
# The ORDER is the whole point. Kubernetes creates AWS resources that
# terraform does not know about - load balancers from Gateways, EBS volumes
# from PVCs. Leave them and `terraform destroy` fails with a
# DependencyViolation, having already deleted half the VPC.
set -uo pipefail

NS="${NS:-devboard}"
REGION="${REGION:-us-west-2}"

echo "=== 1/5 delete Gateways and LoadBalancer Services ==="
kubectl delete gateway --all -n "$NS" --ignore-not-found
kubectl delete svc --all-namespaces --field-selector spec.type=LoadBalancer --ignore-not-found

echo "=== 2/5 wait for the load balancers to actually disappear ==="
# deleting the object returns immediately; AWS takes a minute or two
for i in $(seq 1 30); do
  n=$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)
  if [ "$n" = "0" ]; then
    echo "  all gone"
    break
  fi
  echo "  $n load balancer(s) still present, waiting..."
  sleep 10
done

echo "=== 3/5 uninstall the helm release and delete PVCs ==="
helm uninstall devboard -n "$NS" 2>/dev/null || true
# PVCs from volumeClaimTemplates are NOT owned by helm (day 56), so they
# survive the uninstall and hold EBS volumes open
kubectl delete pvc --all -n "$NS" --ignore-not-found

echo "=== 4/5 delete the namespace ==="
kubectl delete namespace "$NS" --ignore-not-found --timeout=120s

echo "=== 5/5 terraform destroy ==="
cd ../../day-81/terraform && terraform destroy -auto-approve

echo
echo "=== verifying nothing is left billing ==="
printf '%-24s' "eks clusters:"
aws eks list-clusters --region "$REGION" --query 'clusters' --output text
printf '%-24s' "devboard vpcs:"
aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Project,Values=devboard" --query 'Vpcs[].VpcId' --output text
printf '%-24s' "nat gateways:"
aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=state,Values=available" --query 'NatGateways[].NatGatewayId' --output text
printf '%-24s' "elastic ips:"
aws ec2 describe-addresses --region "$REGION" --query 'Addresses[].PublicIp' --output text
printf '%-24s' "unattached volumes:"
aws ec2 describe-volumes --region "$REGION" --filters "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text
printf '%-24s' "load balancers:"
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text

echo
echo "Anything listed above is still costing money."
