#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=./lib/capacity.sh
source "$SCRIPT_DIR/lib/capacity.sh"
load_config

for name in AZURE_RESOURCE_GROUP AZURE_LOCATION KEY_VAULT_NAME FRONT_DOOR_PROFILE_NAME \
  ARO_SERVICE_PRINCIPAL_CLIENT_ID ARO_SERVICE_PRINCIPAL_CLIENT_SECRET \
  ARO_SERVICE_PRINCIPAL_OBJECT_ID ONPREM_SERVICE_PRINCIPAL_CLIENT_ID \
  ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET ONPREM_SERVICE_PRINCIPAL_OBJECT_ID; do
  require_value "$name"
done
if [[ "${ARO_SERVICE_PRINCIPAL_CLIENT_ID,,}" == "${ONPREM_SERVICE_PRINCIPAL_CLIENT_ID,,}" ||
  "${ARO_SERVICE_PRINCIPAL_OBJECT_ID,,}" == "${ONPREM_SERVICE_PRINCIPAL_OBJECT_ID,,}" ]]; then
  printf 'ARO requires a unique service principal per cluster. Configure separate ONPREM_SERVICE_PRINCIPAL_* credentials using script 05 onprem.\n' >&2
  exit 1
fi
require_command az
require_command jq
require_command sort
require_command tail
require_command head

select_subscription
check_capacity
for provider in \
  Microsoft.Authorization \
  Microsoft.Cache \
  Microsoft.Cdn \
  Microsoft.Compute \
  Microsoft.DBforPostgreSQL \
  Microsoft.KeyVault \
  Microsoft.ManagedIdentity \
  Microsoft.Network \
  Microsoft.OperationalInsights \
  Microsoft.RedHatOpenShift \
  Microsoft.Storage; do
  az provider register \
    --namespace "$provider" \
    --wait \
    --only-show-errors
done
provider_object_id="$(az ad sp show \
  --id f1dd0a37-89c6-4e07-bcd1-ffd3d43d8875 \
  --query id --output tsv --only-show-errors)"
if [[ -z "$provider_object_id" ]]; then
  printf 'Could not resolve the Azure Red Hat OpenShift resource provider service principal object ID.\n' >&2
  exit 1
fi
az group create \
  --name "$AZURE_RESOURCE_GROUP" \
  --location "$AZURE_LOCATION" \
  --only-show-errors \
  --output none

OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-}"
if [[ -z "$OPENSHIFT_VERSION" ]]; then
  OPENSHIFT_VERSION="$(az aro get-versions --location "$AZURE_LOCATION" --output tsv | sort -V | tail -n 1)"
fi
if [[ -z "$OPENSHIFT_VERSION" ]]; then
  printf 'No ARO version was returned for %s.\n' "$AZURE_LOCATION" >&2
  exit 1
fi
if [[ "$ARO_MASTER_VM_SIZE" == *_v6 || "$ARO_WORKER_VM_SIZE" == *_v6 ]]; then
  oldest="$(printf '%s\n' '4.19.0' "$OPENSHIFT_VERSION" | sort -V | head -n 1)"
  if [[ "$oldest" != '4.19.0' ]]; then
    printf 'Dsv6 node sizes require OpenShift 4.19 or later. Update OPENSHIFT_VERSION or leave it blank.\n' >&2
    exit 1
  fi
fi

provider_network_role_names=()
for cluster in "$ARO_CLUSTER_NAME" "$ONPREM_CLUSTER_NAME"; do
  scope="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$cluster-vnet"
  roles="$(az role assignment list --subscription "$AZURE_SUBSCRIPTION_ID" \
    --scope "$scope" --output json --only-show-errors)"
  role_name="$(jq -er --arg scope "$scope" --arg principal "$provider_object_id" '
    [.[] | select(
      (.scope | ascii_downcase) == ($scope | ascii_downcase) and
      (.principalId | ascii_downcase) == ($principal | ascii_downcase) and
      (.roleDefinitionId | split("/") | last | ascii_downcase) ==
        "4d97b98b-1d4f-4787-a291-c67834d212e7"
    )] |
    if length > 1 then error("Multiple provider Network Contributor assignments; resolve before deployment")
    elif length == 1 then
      if (.[0].name // "") == "" then error("Existing provider role assignment has no name")
      else .[0].name end
    else "" end' <<<"$roles")"
  provider_network_role_names+=("$role_name")
  if [[ -n "$role_name" ]]; then
    printf 'Reusing provider Network Contributor assignment %s on %s-vnet.\n' "$role_name" "$cluster"
  fi
done

pull_secret=''
if [[ -n "$RED_HAT_PULL_SECRET_FILE" ]]; then
  if [[ ! -r "$RED_HAT_PULL_SECRET_FILE" ]]; then
    printf 'Cannot read RED_HAT_PULL_SECRET_FILE: %s\n' "$RED_HAT_PULL_SECRET_FILE" >&2
    exit 1
  fi
  pull_secret="$(<"$RED_HAT_PULL_SECRET_FILE")"
fi

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
parameters_file="$(mktemp "$SECRETS_DIR/infra-parameters.XXXXXX.json")"
trap 'rm -f -- "$parameters_file"' EXIT
jq -n \
  --arg location "$AZURE_LOCATION" \
  --arg openShiftVersion "$OPENSHIFT_VERSION" \
  --arg keyVaultName "$KEY_VAULT_NAME" \
  --arg frontDoorProfileName "$FRONT_DOOR_PROFILE_NAME" \
  --arg frontDoorEndpointName "$FRONT_DOOR_ENDPOINT_NAME" \
  --arg aroMasterVmSize "$ARO_MASTER_VM_SIZE" \
  --arg aroWorkerVmSize "$ARO_WORKER_VM_SIZE" \
  --arg aroServicePrincipalClientId "$ARO_SERVICE_PRINCIPAL_CLIENT_ID" \
  --arg aroServicePrincipalClientSecret "$ARO_SERVICE_PRINCIPAL_CLIENT_SECRET" \
  --arg aroServicePrincipalObjectId "$ARO_SERVICE_PRINCIPAL_OBJECT_ID" \
  --arg onpremServicePrincipalClientId "$ONPREM_SERVICE_PRINCIPAL_CLIENT_ID" \
  --arg onpremServicePrincipalClientSecret "$ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET" \
  --arg onpremServicePrincipalObjectId "$ONPREM_SERVICE_PRINCIPAL_OBJECT_ID" \
  --arg aroResourceProviderObjectId "$provider_object_id" \
  --arg aroProviderNetworkRoleName "${provider_network_role_names[0]}" \
  --arg onpremProviderNetworkRoleName "${provider_network_role_names[1]}" \
  --arg redHatPullSecret "$pull_secret" \
  --arg aroClusterName "$ARO_CLUSTER_NAME" \
  --arg onpremClusterName "$ONPREM_CLUSTER_NAME" \
  '{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
      location: {value: $location},
      openShiftVersion: {value: $openShiftVersion},
      keyVaultName: {value: $keyVaultName},
      frontDoorProfileName: {value: $frontDoorProfileName},
      frontDoorEndpointName: {value: $frontDoorEndpointName},
      aroMasterVmSize: {value: $aroMasterVmSize},
      aroWorkerVmSize: {value: $aroWorkerVmSize},
      aroServicePrincipalClientId: {value: $aroServicePrincipalClientId},
      aroServicePrincipalClientSecret: {value: $aroServicePrincipalClientSecret},
      aroServicePrincipalObjectId: {value: $aroServicePrincipalObjectId},
      onpremServicePrincipalClientId: {value: $onpremServicePrincipalClientId},
      onpremServicePrincipalClientSecret: {value: $onpremServicePrincipalClientSecret},
      onpremServicePrincipalObjectId: {value: $onpremServicePrincipalObjectId},
      aroResourceProviderObjectId: {value: $aroResourceProviderObjectId},
      aroProviderNetworkRoleName: {value: $aroProviderNetworkRoleName},
      onpremProviderNetworkRoleName: {value: $onpremProviderNetworkRoleName},
      redHatPullSecret: {value: $redHatPullSecret},
      aroClusterName: {value: $aroClusterName},
      onpremClusterName: {value: $onpremClusterName}
    }
  }' >"$parameters_file"
chmod 600 "$parameters_file"

az deployment group validate \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name adaptive-shop-infrastructure \
  --template-file "$REPO_ROOT/infra/azure/main.bicep" \
  --parameters "@$parameters_file" \
  --validation-level Provider \
  --only-show-errors \
  --output none

az deployment group create \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name adaptive-shop-infrastructure \
  --template-file "$REPO_ROOT/infra/azure/main.bicep" \
  --parameters "@$parameters_file" \
  --only-show-errors \
  --output none

printf 'Infrastructure deployment submitted for ARO %s in %s.\n' \
  "$OPENSHIFT_VERSION" "$AZURE_LOCATION"
