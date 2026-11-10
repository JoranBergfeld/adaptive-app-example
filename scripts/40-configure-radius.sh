#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

for name in AZURE_RESOURCE_GROUP ARO_SERVICE_PRINCIPAL_CLIENT_ID \
  ARO_SERVICE_PRINCIPAL_CLIENT_SECRET RECIPE_REF; do
  require_value "$name"
done
require_command rad
require_command git
require_command az

select_subscription
AZURE_TENANT_ID="${AZURE_TENANT_ID:-$(az account show --query tenantId --output tsv)}"

if ! git -C "$REPO_ROOT" ls-remote --exit-code origin \
  "refs/heads/$RECIPE_REF" >/dev/null 2>&1 &&
  ! git -C "$REPO_ROOT" ls-remote --exit-code origin \
    "refs/tags/$RECIPE_REF" >/dev/null 2>&1; then
  printf 'Recipe ref %s is not available on the public GitHub repository.\n' \
    "$RECIPE_REF" >&2
  exit 1
fi

rad credential register azure sp \
  --client-id "$ARO_SERVICE_PRINCIPAL_CLIENT_ID" \
  --client-secret "$ARO_SERVICE_PRINCIPAL_CLIENT_SECRET" \
  --tenant-id "$AZURE_TENANT_ID" \
  --workspace aro-workspace

rad deploy "$REPO_ROOT/radius/recipe-packs/aro.bicep" \
  --workspace aro-workspace \
  --group default
rad deploy "$REPO_ROOT/radius/environments/aro.bicep" \
  --workspace aro-workspace \
  --group default \
  --parameters "azureSubscriptionId=$AZURE_SUBSCRIPTION_ID" \
  --parameters "azureResourceGroupName=$AZURE_RESOURCE_GROUP"

rad deploy "$REPO_ROOT/radius/recipe-packs/onprem.bicep" \
  --workspace onprem-workspace \
  --group default \
  --parameters "recipeRef=$RECIPE_REF"
rad deploy "$REPO_ROOT/radius/environments/onprem.bicep" \
  --workspace onprem-workspace \
  --group default

printf 'Both Radius environments now use the same app definition and separate recipes.\n'
