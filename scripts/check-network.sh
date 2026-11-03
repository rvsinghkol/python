#!/usr/bin/env bash
# =====================================================================
# Checks that the existing subnets are ready for ECS + load balancer.
# Run once (admin credentials or the Jenkins user's keys):
#   bash scripts/check-network.sh
# =====================================================================
set -uo pipefail
REGION="${AWS_DEFAULT_REGION:-ap-south-2}"

PUBLIC_SUBNETS="subnet-07d6275970e1880a5 subnet-0819c6fdba75bb607"
PRIVATE_SUBNETS="subnet-03d64d86a8828a763 subnet-0da8fd6cf0022a865"

FAIL=0

# Route table for a subnet (explicit association, else the VPC main table)
route_table_for() {
  local subnet=$1 vpc=$2 rt
  rt=$(aws ec2 describe-route-tables --region "$REGION" \
        --filters Name=association.subnet-id,Values="$subnet" \
        --query 'RouteTables[0].RouteTableId' --output text)
  if [ "$rt" = "None" ] || [ -z "$rt" ]; then
    rt=$(aws ec2 describe-route-tables --region "$REGION" \
          --filters Name=vpc-id,Values="$vpc" Name=association.main,Values=true \
          --query 'RouteTables[0].RouteTableId' --output text)
  fi
  echo "$rt"
}

default_route_target() {
  aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$1" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0].[GatewayId,NatGatewayId,TransitGatewayId]" \
    --output text
}

check_group() {
  local kind=$1; shift
  local azs=()
  echo "== $kind subnets =="
  for s in "$@"; do
    read -r VPC AZ CIDR <<<"$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$s" \
        --query 'Subnets[0].[VpcId,AvailabilityZone,CidrBlock]' --output text)"
    RT=$(route_table_for "$s" "$VPC")
    TARGET=$(default_route_target "$RT")
    azs+=("$AZ")
    printf "  %-26s %-14s %-12s vpc=%s rt=%s 0.0.0.0/0 -> %s\n" "$s" "$CIDR" "$AZ" "$VPC" "$RT" "$TARGET"

    if [ "$kind" = "PUBLIC" ]; then
      echo "$TARGET" | grep -q "igw-" \
        || { echo "    !! public subnet has no route to an Internet Gateway (igw-...)"; FAIL=1; }
    else
      if echo "$TARGET" | grep -q "nat-"; then
        echo "    OK: NAT gateway route already exists -> create_nat_gateway = false, create_vpc_endpoints = false"
      elif echo "$TARGET" | grep -q "igw-"; then
        echo "    !! this 'private' subnet routes to an Internet Gateway - it is really public"; FAIL=1
      else
        echo "    -> no NAT route. In prod.tfvars set:"
        echo "         private_route_table_ids = [\"$RT\"]   (list each rtb- ID once)"
        echo "         create_nat_gateway = true   OR   create_vpc_endpoints = true"
        if echo "$TARGET" | grep -q -- "-"; then   # some other target (tgw-, vgw-, pcx-...)
          echo "    !! route table already has a 0.0.0.0/0 route ($TARGET) - talk to your network admin first"; FAIL=1
        fi
      fi
    fi
  done
  local unique
  unique=$(printf "%s\n" "${azs[@]}" | sort -u | wc -l)
  if [ "$unique" -lt 2 ]; then
    echo "  !! $kind subnets are all in ONE Availability Zone - need 2 different AZs"; FAIL=1
  else
    echo "  OK: $kind subnets span $unique AZs"
  fi
  echo
}

check_group PUBLIC  $PUBLIC_SUBNETS
check_group PRIVATE $PRIVATE_SUBNETS

if [ "$FAIL" -eq 0 ]; then
  echo "Network looks ready."
else
  echo "Fix the items marked !! before the first deploy."
  exit 1
fi
