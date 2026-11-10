#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
target="${1:-aro}"
case "$target" in
  aro|onprem) ;;
  *) printf 'Expected target aro or onprem.\n' >&2; exit 2 ;;
esac
load_config

require_command az
require_command jq
require_value AZURE_RESOURCE_GROUP
select_subscription

credentials_file="$SECRETS_DIR/service-principal.json"
from_file="$SERVICE_PRINCIPAL_FROM_FILE"
if [[ "$target" == onprem ]]; then
  credentials_file="$SECRETS_DIR/onprem-service-principal.json"
  from_file="$ONPREM_SERVICE_PRINCIPAL_FROM_FILE"
fi
prefix="${target^^}"
client_key="${prefix}_SERVICE_PRINCIPAL_CLIENT_ID"
secret_key="${prefix}_SERVICE_PRINCIPAL_CLIENT_SECRET"
object_key="${prefix}_SERVICE_PRINCIPAL_OBJECT_ID"
if [[ -n "${!client_key}" || -n "${!secret_key}" || -n "${!object_key}" ]]; then
  require_value "$client_key"
  require_value "$secret_key"
  if [[ -n "${!object_key}" ]]; then
    printf 'Using the configured service principal; no credentials were changed.\n'
    exit 0
  fi
  if [[ "$from_file" != true ]]; then
    require_value "$object_key"
  fi
else
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  temporary_file="$(mktemp "$SECRETS_DIR/service-principal.XXXXXX.json")"
  trap 'rm -f -- "$temporary_file"' EXIT
  suffix="${temporary_file%.json}"
  suffix="${suffix##*.}"
  az ad sp create-for-rbac \
    --name "${AZURE_RESOURCE_GROUP}-${target}-${suffix}" \
    --skip-assignment \
    --years 1 \
    --only-show-errors \
    --output json >"$temporary_file"
  jq -e 'all(.appId, .password, .tenant; type == "string" and length > 0)' \
    "$temporary_file" >/dev/null
  mv -- "$temporary_file" "$credentials_file"
  load_config
fi

# Save the password before directory lookup so retries do not rotate credentials.
object_id=''
resolved=false
for _ in $(seq 1 12); do
  if object_id="$(az ad sp show \
    --id "${!client_key}" \
    --query id \
    --output tsv \
    --only-show-errors)" && [[ -n "$object_id" ]]; then
    resolved=true
    break
  fi
  sleep 5
done
if [[ "$resolved" != true ]]; then
  printf 'Service principal credentials are saved, but its object ID could not be resolved. Rerun this script after checking Microsoft Entra permissions.\n' >&2
  exit 1
fi

temporary_file="$(mktemp "$SECRETS_DIR/service-principal.XXXXXX.json")"
trap 'rm -f -- "$temporary_file"' EXIT
jq --arg objectId "$object_id" '. + {objectId: $objectId}' \
  "$credentials_file" >"$temporary_file"
mv -- "$temporary_file" "$credentials_file"
printf 'Service principal credentials saved privately in %s.\n' "$credentials_file"
printf 'Later scripts load this file automatically. Resource-group roles are assigned by 10-apply-infrastructure.sh.\n'
