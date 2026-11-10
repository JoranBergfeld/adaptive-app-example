#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS_DIR="$REPO_ROOT/.secrets"
RADIUS_VERSION="${RADIUS_VERSION:-0.60.2}"
DAPR_VERSION="${DAPR_VERSION:-1.19.0}"
CNPG_VERSION="${CNPG_VERSION:-1.30.1}"

load_config() {
  if [[ -f "$SECRETS_DIR/contexts.env" ]]; then
    # shellcheck disable=SC1091
    source "$SECRETS_DIR/contexts.env"
  fi
  if [[ -f "$REPO_ROOT/.env" ]]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
  fi

  AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
  AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
  AZURE_LOCATION="${AZURE_LOCATION:-}"
  ARO_CLUSTER_NAME="${ARO_CLUSTER_NAME:-adaptive-aro}"
  ONPREM_CLUSTER_NAME="${ONPREM_CLUSTER_NAME:-adaptive-onprem}"
  ARO_CONTEXT="${ARO_CONTEXT:-aro-demo}"
  ONPREM_CONTEXT="${ONPREM_CONTEXT:-onprem-demo}"
  KEY_VAULT_NAME="${KEY_VAULT_NAME:-}"
  FRONT_DOOR_PROFILE_NAME="${FRONT_DOOR_PROFILE_NAME:-}"
  FRONT_DOOR_ENDPOINT_NAME="${FRONT_DOOR_ENDPOINT_NAME:-shop}"
  ARO_MASTER_VM_SIZE="${ARO_MASTER_VM_SIZE:-Standard_D8s_v5}"
  ARO_WORKER_VM_SIZE="${ARO_WORKER_VM_SIZE:-Standard_D4s_v5}"
  AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
  ARO_SERVICE_PRINCIPAL_CLIENT_ID="${ARO_SERVICE_PRINCIPAL_CLIENT_ID:-}"
  ARO_SERVICE_PRINCIPAL_CLIENT_SECRET="${ARO_SERVICE_PRINCIPAL_CLIENT_SECRET:-}"
  ARO_SERVICE_PRINCIPAL_OBJECT_ID="${ARO_SERVICE_PRINCIPAL_OBJECT_ID:-}"
  ONPREM_SERVICE_PRINCIPAL_CLIENT_ID="${ONPREM_SERVICE_PRINCIPAL_CLIENT_ID:-}"
  ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET="${ONPREM_SERVICE_PRINCIPAL_CLIENT_SECRET:-}"
  ONPREM_SERVICE_PRINCIPAL_OBJECT_ID="${ONPREM_SERVICE_PRINCIPAL_OBJECT_ID:-}"
  SERVICE_PRINCIPAL_FROM_FILE=false
  ONPREM_SERVICE_PRINCIPAL_FROM_FILE=false
  local target prefix credentials_file client_key secret_key object_key flag
  for target in aro onprem; do
    prefix="${target^^}"
    client_key="${prefix}_SERVICE_PRINCIPAL_CLIENT_ID"
    secret_key="${prefix}_SERVICE_PRINCIPAL_CLIENT_SECRET"
    object_key="${prefix}_SERVICE_PRINCIPAL_OBJECT_ID"
    credentials_file="$SECRETS_DIR/service-principal.json"
    flag=SERVICE_PRINCIPAL_FROM_FILE
    if [[ "$target" == onprem ]]; then
      credentials_file="$SECRETS_DIR/onprem-service-principal.json"
      flag=ONPREM_SERVICE_PRINCIPAL_FROM_FILE
    fi
    if [[ -f "$credentials_file" && -z "${!client_key}" &&
      -z "${!secret_key}" && -z "${!object_key}" ]]; then
      require_command jq
      if ! jq -e 'all(.appId, .password, .tenant; type == "string" and length > 0)
        and (.objectId == null or (.objectId | type == "string" and length > 0))' \
        "$credentials_file" >/dev/null; then
        printf 'Invalid saved service principal credentials in %s; no new identity will be created.\n' "$credentials_file" >&2
        return 1
      fi
      local client_id client_secret object_id
      client_id="$(jq -r '.appId' "$credentials_file")" || return 1
      client_secret="$(jq -r '.password' "$credentials_file")" || return 1
      object_id="$(jq -r '.objectId // empty' "$credentials_file")" || return 1
      printf -v "$client_key" '%s' "$client_id"
      printf -v "$secret_key" '%s' "$client_secret"
      printf -v "$object_key" '%s' "$object_id"
      AZURE_TENANT_ID="${AZURE_TENANT_ID:-$(jq -r '.tenant' "$credentials_file")}"
      printf -v "$flag" '%s' true
    fi
  done
  RED_HAT_PULL_SECRET_FILE="${RED_HAT_PULL_SECRET_FILE:-}"
  RECIPE_REF="${RECIPE_REF:-main}"
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-JoranBergfeld/adaptive-app-example}"
  IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/${GITHUB_REPOSITORY,,}}"
  IMAGE_TAG="${IMAGE_TAG:-$(git -C "$REPO_ROOT" rev-parse HEAD)}"
  KUBECONFIG="${KUBECONFIG:-$SECRETS_DIR/aro-demo.kubeconfig:$SECRETS_DIR/onprem-demo.kubeconfig}"
  export KUBECONFIG SERVICE_PRINCIPAL_FROM_FILE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    return 1
  fi
}

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'Set %s in .env or the environment before continuing.\n' "$name" >&2
    return 1
  fi
}

select_subscription() {
  require_command az
  AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}"
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
}

ensure_database_password() {
  mkdir -p "$SECRETS_DIR"
  chmod 700 "$SECRETS_DIR"
  if [[ -z "${DATABASE_PASSWORD:-}" ]]; then
    if [[ -s "$SECRETS_DIR/database-password" ]]; then
      DATABASE_PASSWORD="$(<"$SECRETS_DIR/database-password")"
    else
      require_command openssl
      DATABASE_PASSWORD="$(openssl rand -hex 32)"
    fi
  fi
  printf '%s' "$DATABASE_PASSWORD" >"$SECRETS_DIR/database-password"
  chmod 600 "$SECRETS_DIR/database-password"
  export DATABASE_PASSWORD
}

context_for() {
  case "$1" in
    aro) printf '%s\n' "$ARO_CONTEXT" ;;
    onprem) printf '%s\n' "$ONPREM_CONTEXT" ;;
    *)
      printf 'Unknown target %s; expected aro or onprem.\n' "$1" >&2
      return 2
      ;;
  esac
}

workspace_for() {
  case "$1" in
    aro) printf 'aro-workspace\n' ;;
    onprem) printf 'onprem-workspace\n' ;;
    *)
      printf 'Unknown target %s; expected aro or onprem.\n' "$1" >&2
      return 2
      ;;
  esac
}

environment_for() {
  case "$1" in
    aro) printf 'aro\n' ;;
    onprem) printf 'onprem\n' ;;
    *)
      printf 'Unknown target %s; expected aro or onprem.\n' "$1" >&2
      return 2
      ;;
  esac
}

resource_property() {
  local workspace="$1"
  local resource_type="$2"
  local resource_name="$3"
  local property="$4"
  rad resource show "$resource_type" "$resource_name" \
    --workspace "$workspace" \
    --group default \
    --application shop \
    --output json |
    jq -er ".properties.${property} | select(. != null and . != \"\")"
}

write_deploy_parameters() {
  local destination="$1"
  local workload="$2"
  jq -n \
    --arg imageRegistry "$IMAGE_REGISTRY" \
    --arg imageTag "$IMAGE_TAG" \
    --arg databasePassword "$DATABASE_PASSWORD" \
    --argjson deployWorkload "$workload" \
    '{
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
      "contentVersion": "1.0.0.0",
      "parameters": {
        imageRegistry: {value: $imageRegistry},
        imageTag: {value: $imageTag},
        databasePassword: {value: $databasePassword},
        deployWorkload: {value: $deployWorkload}
      }
    }' >"$destination"
  chmod 600 "$destination"
}

front_door_origin() {
  local target="$1"
  local host="$2"
  local names
  names="$(az afd origin list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --profile-name "$FRONT_DOOR_PROFILE_NAME" \
    --origin-group-name shop-origins \
    --query '[].name' \
    --output tsv)"

  if printf '%s\n' "$names" | grep -Fxq "$target"; then
    az afd origin update \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$FRONT_DOOR_PROFILE_NAME" \
      --origin-group-name shop-origins \
      --origin-name "$target" \
      --host-name "$host" \
      --origin-host-header "$host" \
      --enabled-state Disabled \
      --only-show-errors \
      --output none
  else
    az afd origin create \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --profile-name "$FRONT_DOOR_PROFILE_NAME" \
      --origin-group-name shop-origins \
      --origin-name "$target" \
      --host-name "$host" \
      --origin-host-header "$host" \
      --http-port 80 \
      --https-port 443 \
      --priority 1 \
      --weight 1000 \
      --enabled-state Disabled \
      --certificate-name-check-enabled true \
      --only-show-errors \
      --output none
  fi
}
