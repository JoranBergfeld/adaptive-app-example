#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

for name in AZURE_RESOURCE_GROUP AZURE_LOCATION KEY_VAULT_NAME FRONT_DOOR_PROFILE_NAME \
  ARO_SERVICE_PRINCIPAL_CLIENT_ID ARO_SERVICE_PRINCIPAL_CLIENT_SECRET \
  ARO_SERVICE_PRINCIPAL_OBJECT_ID; do
  require_value "$name"
done
require_command az
require_command jq
require_command sort
require_command tail

select_subscription
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
  --arg aroServicePrincipalClientId "$ARO_SERVICE_PRINCIPAL_CLIENT_ID" \
  --arg aroServicePrincipalClientSecret "$ARO_SERVICE_PRINCIPAL_CLIENT_SECRET" \
  --arg aroServicePrincipalObjectId "$ARO_SERVICE_PRINCIPAL_OBJECT_ID" \
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
      aroServicePrincipalClientId: {value: $aroServicePrincipalClientId},
      aroServicePrincipalClientSecret: {value: $aroServicePrincipalClientSecret},
      aroServicePrincipalObjectId: {value: $aroServicePrincipalObjectId},
      redHatPullSecret: {value: $redHatPullSecret},
      aroClusterName: {value: $aroClusterName},
      onpremClusterName: {value: $onpremClusterName}
    }
  }' >"$parameters_file"
chmod 600 "$parameters_file"

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
