#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_value AZURE_RESOURCE_GROUP
require_command az
select_subscription

printf 'This permanently deletes every Azure resource in %s.\n' "$AZURE_RESOURCE_GROUP"
read -r -p "Type the resource group name to continue: " confirmation
if [[ "$confirmation" != "$AZURE_RESOURCE_GROUP" ]]; then
  printf 'Confirmation did not match; no Azure resources were deleted.\n' >&2
  exit 1
fi

az group delete \
  --name "$AZURE_RESOURCE_GROUP" \
  --yes \
  --no-wait \
  --only-show-errors
printf 'Deletion requested for resource group %s.\n' "$AZURE_RESOURCE_GROUP"
