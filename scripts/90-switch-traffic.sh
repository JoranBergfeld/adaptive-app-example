#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

target="${1:-}"
if [[ "$target" != "aro" && "$target" != "onprem" ]]; then
  printf 'Usage: %s <aro|onprem>\n' "$0" >&2
  exit 2
fi
for name in AZURE_RESOURCE_GROUP FRONT_DOOR_PROFILE_NAME; do
  require_value "$name"
done
require_command az
require_command curl
select_subscription

origins="$(az afd origin list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --profile-name "$FRONT_DOOR_PROFILE_NAME" \
  --origin-group-name shop-origins \
  --query '[].name' \
  --output tsv \
  --only-show-errors)"
for origin in aro onprem; do
  if ! printf '%s\n' "$origins" | grep -Fxq "$origin"; then
    printf 'Front Door origin %s has not been deployed yet.\n' "$origin" >&2
    exit 1
  fi
done

other_target=aro
if [[ "$target" == "aro" ]]; then
  other_target=onprem
fi

for origin in "$other_target" "$target"; do
  enabled_state=Disabled
  [[ "$origin" != "$target" ]] || enabled_state=Enabled
  az afd origin update \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --profile-name "$FRONT_DOOR_PROFILE_NAME" \
    --origin-group-name shop-origins \
    --origin-name "$origin" \
    --enabled-state "$enabled_state" \
    --only-show-errors \
    --output none
done

az deployment group create \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name adaptive-shop-front-door-route \
  --template-file "$REPO_ROOT/infra/azure/front-door-route.bicep" \
  --parameters "frontDoorProfileName=$FRONT_DOOR_PROFILE_NAME" \
  --only-show-errors \
  --output none

front_door_host="$(az afd endpoint show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --profile-name "$FRONT_DOOR_PROFILE_NAME" \
  --endpoint-name shop \
  --query hostName \
  --output tsv \
  --only-show-errors)"
ready=0
for _ in $(seq 1 60); do
  if curl --fail --silent --connect-timeout 5 --max-time 10 \
    "https://$front_door_host/readyz" >/dev/null; then
    ready=1
    break
  fi
  sleep 5
done
if [[ "$ready" != 1 ]]; then
  printf 'Front Door did not become ready at https://%s/readyz.\n' \
    "$front_door_host" >&2
  exit 1
fi

printf 'Front Door is configured to send traffic only to the %s origin.\n' "$target"
printf 'Verified: https://%s/readyz\n' "$front_door_host"
