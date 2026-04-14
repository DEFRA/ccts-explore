#!/usr/bin/env bash
set -euo pipefail

# Private AKS + Azure CNI overlay + UDR outbound (POC helper)
#
# Usage:
#   ./01-deploy-private-aks-cni-overlay.sh
#
# Fill these variables before running.

AZ_SUBSCRIPTION_ID="TODO: SUBSCRIPTION ID"
AKS_RESOURCE_GROUP="TODO: AKS RESOURCE GROUP"
AKS_CLUSTER_NAME="TODO: AKS CLUSTER NAME"
AKS_LOCATION="uksouth"
AKS_K8S_VERSION="1.32.6"
AKS_NODE_COUNT="1"
# Based on minimum requirements from Langfuse documentation.
AKS_NODE_VM_SIZE="Standard_D8s_v5"
AKS_NETWORK_POLICY="azure"

VNET_RESOURCE_GROUP="TODO: VNET RESOURCE GROUP"
VNET_NAME="TODO: VNET NAME"
SUBNET_NAME="TODO: SUBNET NAME"

AKS_ROUTE_TABLE_RESOURCE_GROUP="TODO: AKS ROUTE TABLE RESOURCE GROUP"
AKS_ROUTE_TABLE_NAME="TODO: AKS ROUTE TABLE NAME"
AKS_DEFAULT_ROUTE_NAME="default"
AKS_DEFAULT_ROUTE_PREFIX="0.0.0.0/0"

AKS_DEFAULT_ROUTE_NEXT_HOP_IP="TODO: Hub Firewall IP"

# For corporate DNS integrated post-provision.
AKS_PRIVATE_DNS_ZONE="none"   # system | none | /subscriptions/.../privateDnsZones/...
AKS_DISABLE_PUBLIC_FQDN="false"

az account set --subscription "${AZ_SUBSCRIPTION_ID}"

SUBNET_ID="$(
  az network vnet subnet show \
    -g "${VNET_RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    -n "${SUBNET_NAME}" \
    --query id -o tsv
)"

if az network route-table show -g "${AKS_ROUTE_TABLE_RESOURCE_GROUP}" -n "${AKS_ROUTE_TABLE_NAME}" -o none 2>/dev/null; then
  echo "Using existing route table ${AKS_ROUTE_TABLE_RESOURCE_GROUP}/${AKS_ROUTE_TABLE_NAME}"
else
  az network route-table create \
    -g "${AKS_ROUTE_TABLE_RESOURCE_GROUP}" \
    -n "${AKS_ROUTE_TABLE_NAME}" \
    -l "${AKS_LOCATION}" -o none
fi

if az network route-table route show \
  -g "${AKS_ROUTE_TABLE_RESOURCE_GROUP}" \
  --route-table-name "${AKS_ROUTE_TABLE_NAME}" \
  -n "${AKS_DEFAULT_ROUTE_NAME}" -o none 2>/dev/null; then
  echo "Route ${AKS_DEFAULT_ROUTE_NAME} already exists; leaving unchanged"
else
  az network route-table route create \
    -g "${AKS_ROUTE_TABLE_RESOURCE_GROUP}" \
    --route-table-name "${AKS_ROUTE_TABLE_NAME}" \
    -n "${AKS_DEFAULT_ROUTE_NAME}" \
    --address-prefix "${AKS_DEFAULT_ROUTE_PREFIX}" \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "${AKS_DEFAULT_ROUTE_NEXT_HOP_IP}" -o none
fi

ROUTE_TABLE_ID="$(
  az network route-table show \
    -g "${AKS_ROUTE_TABLE_RESOURCE_GROUP}" \
    -n "${AKS_ROUTE_TABLE_NAME}" \
    --query id -o tsv
)"

az network vnet subnet update \
  -g "${VNET_RESOURCE_GROUP}" \
  --vnet-name "${VNET_NAME}" \
  -n "${SUBNET_NAME}" \
  --route-table "${ROUTE_TABLE_ID}" -o none

az group create -n "${AKS_RESOURCE_GROUP}" -l "${AKS_LOCATION}" -o none

PRIVATE_DNS_ARGS=()
case "${AKS_PRIVATE_DNS_ZONE}" in
  none) PRIVATE_DNS_ARGS+=(--private-dns-zone none) ;;
  system) PRIVATE_DNS_ARGS+=(--private-dns-zone system) ;;
  /*) PRIVATE_DNS_ARGS+=(--private-dns-zone "${AKS_PRIVATE_DNS_ZONE}") ;;
  *) echo "Invalid AKS_PRIVATE_DNS_ZONE: ${AKS_PRIVATE_DNS_ZONE}"; exit 1 ;;
esac
if [[ "${AKS_DISABLE_PUBLIC_FQDN}" == "true" && "${AKS_PRIVATE_DNS_ZONE}" != "none" ]]; then
  PRIVATE_DNS_ARGS+=(--disable-public-fqdn)
fi

az aks create \
  -g "${AKS_RESOURCE_GROUP}" \
  -n "${AKS_CLUSTER_NAME}" \
  -l "${AKS_LOCATION}" \
  --kubernetes-version "${AKS_K8S_VERSION}" \
  --node-count "${AKS_NODE_COUNT}" \
  --node-vm-size "${AKS_NODE_VM_SIZE}" \
  --vnet-subnet-id "${SUBNET_ID}" \
  --enable-managed-identity \
  --enable-private-cluster \
  "${PRIVATE_DNS_ARGS[@]}" \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-policy "${AKS_NETWORK_POLICY}" \
  --outbound-type userDefinedRouting \
  --pod-cidr 192.168.0.0/16 \
  --service-cidr 10.0.0.0/16 \
  --dns-service-ip 10.0.0.10 \
  -o none

az aks wait -g "${AKS_RESOURCE_GROUP}" -n "${AKS_CLUSTER_NAME}" --created
echo "AKS private cluster created."
