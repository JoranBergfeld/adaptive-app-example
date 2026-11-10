#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_command rad
require_command kubectl
require_command oc
require_command az
require_value AZURE_RESOURCE_GROUP
require_value KEY_VAULT_NAME
require_value FRONT_DOOR_PROFILE_NAME
select_subscription

origins="$(az afd origin list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --profile-name "$FRONT_DOOR_PROFILE_NAME" \
  --origin-group-name shop-origins \
  --query '[].name' \
  --output tsv \
  --only-show-errors)"
for origin in aro onprem; do
  if printf '%s\n' "$origins" | grep -Fxq "$origin"; then
    az afd origin update \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$FRONT_DOOR_PROFILE_NAME" \
      --origin-group-name shop-origins \
      --origin-name "$origin" \
      --enabled-state Disabled \
      --only-show-errors \
      --output none
  fi
done

for target in aro onprem; do
  workspace="$(workspace_for "$target")"
  context="$(context_for "$target")"
  rad app delete shop \
    --group default \
    --workspace "$workspace" \
    --yes
  oc --context "$context" delete route shop \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete component statestore \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete component secretstore \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete secret shop-db-credentials shop-redis-password \
    shop-db-seed-credentials \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete pod shop-db-seed \
    --namespace shop \
    --ignore-not-found \
    --wait=false
  kubectl --context "$context" delete serviceaccount shop-api \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete rolebinding shop-api-database-secret-reader \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete role shop-api-database-secret-reader \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete rolebinding chaos-operator chaos-operator-readonly \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete role chaos-operator chaos-operator-readonly \
    --namespace shop \
    --ignore-not-found
  kubectl --context "$context" delete serviceaccount chaos-operator \
    --namespace shop \
    --ignore-not-found
done

kubectl --context "$ARO_CONTEXT" delete networkpolicy demo-outage \
  --namespace shop \
  --ignore-not-found \
  --wait=false

for secret in shop-db-password shop-redis-password; do
  existing_secret="$(az keyvault secret list \
    --vault-name "$KEY_VAULT_NAME" \
    --query "[?name=='$secret'].name | [0]" \
    --output tsv \
    --only-show-errors)"
  if [[ -n "$existing_secret" ]]; then
    az keyvault secret delete \
      --vault-name "$KEY_VAULT_NAME" \
      --name "$secret" \
      --only-show-errors \
      --output none
  fi
done

printf 'Demo application resources were removed from both clusters.\n'
printf 'Azure infrastructure, Radius, Dapr, and CloudNativePG remain installed.\n'
