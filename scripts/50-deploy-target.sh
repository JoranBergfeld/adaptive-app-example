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

for command_name in az rad kubectl oc jq curl; do
  require_command "$command_name"
done
for name in AZURE_RESOURCE_GROUP KEY_VAULT_NAME \
  FRONT_DOOR_PROFILE_NAME; do
  require_value "$name"
done
select_subscription
ensure_database_password

context="$(context_for "$target")"
workspace="$(workspace_for "$target")"
environment="$(environment_for "$target")"
parameters_file="$(mktemp "$SECRETS_DIR/deploy-parameters.XXXXXX.json")"
cleanup() {
  rm -f -- "$parameters_file"
  kubectl --context "$context" delete pod/shop-db-seed \
    secret/shop-db-seed-credentials \
    --namespace shop \
    --ignore-not-found \
    --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$target" == "aro" ]]; then
  az keyvault secret set \
    --vault-name "$KEY_VAULT_NAME" \
    --name shop-db-password \
    --file "$SECRETS_DIR/database-password" \
    --only-show-errors \
    --output none
else
  kubectl --context "$context" apply \
    --filename "$REPO_ROOT/infra/onprem-style/secret-rbac.yaml"
  kubectl --context "$context" create secret generic shop-db-credentials \
    --namespace shop \
    --from-literal=username=shopadmin \
    --from-file="password=$SECRETS_DIR/database-password" \
    --dry-run=client \
    --output yaml |
    kubectl --context "$context" apply --filename -
fi

write_deploy_parameters "$parameters_file" false
rad deploy "$REPO_ROOT/radius/app.bicep" \
  --workspace "$workspace" \
  --group default \
  --environment "$environment" \
  --parameters "@$parameters_file"

database_host="$(resource_property "$workspace" Radius.Data/postgreSqlDatabases shop-postgresql host)"
database_port=5432
redis_host="$(resource_property "$workspace" Radius.Data/redisCaches shop-cache host)"
redis_port="$(resource_property "$workspace" Radius.Data/redisCaches shop-cache port)"

seed_postgres() {
  kubectl --context "$context" create secret generic shop-db-seed-credentials \
    --namespace shop \
    --from-file="password=$SECRETS_DIR/database-password" \
    --dry-run=client \
    --output yaml |
    kubectl --context "$context" apply --filename -
  sed \
    -e "s/__DATABASE_HOST__/$database_host/" \
    -e "s/__DATABASE_PORT__/$database_port/" \
    "$REPO_ROOT/infra/azure/postgres-seed-pod.yaml" |
    kubectl --context "$context" apply --filename -
  kubectl --context "$context" wait \
    --namespace shop \
    --for=condition=Ready \
    pod/shop-db-seed \
    --timeout=5m
  # shellcheck disable=SC2016
  kubectl --context "$context" exec \
    --namespace shop \
    pod/shop-db-seed \
    -- sh -c 'attempt=0; until pg_isready --quiet; do
      attempt=$((attempt + 1))
      if [ "$attempt" -ge 120 ]; then exit 1; fi
      sleep 5
    done'
  kubectl --context "$context" exec \
    --namespace shop \
    --stdin \
    pod/shop-db-seed \
    -- psql --set ON_ERROR_STOP=1 \
    <"$REPO_ROOT/app/api/init.sql"
  kubectl --context "$context" delete pod/shop-db-seed \
    secret/shop-db-seed-credentials \
    --namespace shop \
    --ignore-not-found
}

if [[ "$target" == "aro" ]]; then
  seed_postgres
  redis_name="${redis_host%%.*}"
  redis_password="$(az redisenterprise database list-keys \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --cluster-name "$redis_name" \
    --database-name default \
    --query primaryKey \
    --output tsv \
    --only-show-errors)"
  if [[ -z "$redis_password" ]]; then
    printf 'Azure Managed Redis did not return a primary access key.\n' >&2
    exit 1
  fi
  printf '%s' "$redis_password" >"$SECRETS_DIR/redis-password"
  chmod 600 "$SECRETS_DIR/redis-password"
  az keyvault secret set \
    --vault-name "$KEY_VAULT_NAME" \
    --name shop-redis-password \
    --file "$SECRETS_DIR/redis-password" \
    --only-show-errors \
    --output none

  kubectl --context "$context" create serviceaccount shop-api \
    --namespace shop \
    --dry-run=client \
    --output yaml |
    kubectl --context "$context" apply --filename -
  APP_IDENTITY_CLIENT_ID="${APP_IDENTITY_CLIENT_ID:-$(az deployment group show \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --name adaptive-shop-infrastructure \
    --query properties.outputs.appIdentityClientId.value \
    --output tsv)}"
  if [[ -z "$APP_IDENTITY_CLIENT_ID" ]]; then
    printf 'Could not retrieve the app managed identity client ID.\n' >&2
    exit 1
  fi
  sed \
    -e "s/__KEY_VAULT_NAME__/$KEY_VAULT_NAME/" \
    -e "s/__IDENTITY_CLIENT_ID__/$APP_IDENTITY_CLIENT_ID/" \
    "$REPO_ROOT/dapr/components/aro/secretstore.yaml" |
    kubectl --context "$context" apply --namespace shop --filename -
  sed "s#__REDIS_HOST__#${redis_host}:${redis_port}#" \
    "$REPO_ROOT/dapr/components/aro/statestore.yaml" |
    kubectl --context "$context" apply --namespace shop --filename -
  kubectl --context "$context" annotate serviceaccount shop-api \
    --namespace shop \
    "azure.workload.identity/client-id=$APP_IDENTITY_CLIENT_ID" \
    --overwrite
else
  kubectl --context "$context" wait \
    --namespace shop \
    --for=condition=Ready \
    clusters.postgresql.cnpg.io/shop-postgresql \
    --timeout=10m
  kubectl --context "$context" wait \
    --namespace shop \
    --for=condition=Available \
    deployment/shop-cache \
    --timeout=5m
  database_host='shop-postgresql-rw.shop.svc.cluster.local'
  seed_postgres
  sed "s#__REDIS_HOST__#${redis_host}:${redis_port}#" \
    "$REPO_ROOT/dapr/components/onprem/statestore.yaml" |
    kubectl --context "$context" apply \
    --namespace shop \
    --filename -
fi

write_deploy_parameters "$parameters_file" true
rad deploy "$REPO_ROOT/radius/app.bicep" \
  --workspace "$workspace" \
  --group default \
  --environment "$environment" \
  --parameters "@$parameters_file"

if [[ "$target" == "onprem" ]]; then
  kubectl --context "$context" patch deployment shop-api \
    --namespace shop \
    --type merge \
    --patch '{"spec":{"template":{"spec":{"serviceAccountName":"shop-api"}}}}'
else
  kubectl --context "$context" patch deployment shop-api \
    --namespace shop \
    --type merge \
    --patch '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}},"spec":{"serviceAccountName":"shop-api"}}}}'
fi

kubectl --context "$context" rollout status \
  --namespace shop \
  deployment/shop-api \
  --timeout=10m
kubectl --context "$context" rollout status \
  --namespace shop \
  deployment/shop-web \
  --timeout=10m

console_url="$(az aro show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$([[ "$target" == "aro" ]] && printf '%s' "$ARO_CLUSTER_NAME" || printf '%s' "$ONPREM_CLUSTER_NAME")" \
  --query consoleUrl \
  --output tsv \
  --only-show-errors)"
apps_domain="${console_url#https://console-openshift-console.}"
apps_domain="${apps_domain%%/*}"
if [[ "$apps_domain" == "$console_url" || -z "$apps_domain" ]]; then
  printf 'Could not derive the ARO application domain from consoleUrl.\n' >&2
  exit 1
fi
shop_host="shop.$apps_domain"
if ! oc --context "$context" get route shop --namespace shop >/dev/null 2>&1; then
  oc --context "$context" expose service/shop-web-web \
    --namespace shop \
    --name shop \
    --hostname "$shop_host"
fi
oc --context "$context" wait \
  --namespace shop \
  --for=condition=Admitted \
  route/shop \
  --timeout=5m
curl --fail --silent --show-error "https://$shop_host/readyz" >/dev/null

front_door_origin "$target" "$shop_host"
front_door_host="$(az afd endpoint show \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --profile-name "$FRONT_DOOR_PROFILE_NAME" \
  --endpoint-name shop \
  --query hostName \
  --output tsv \
  --only-show-errors)"

printf 'Deployment ready on %s: https://%s\n' "$target" "$shop_host"
printf 'Front Door endpoint (switch traffic explicitly): https://%s\n' "$front_door_host"
printf 'PostgreSQL host: %s\nRedis host: %s\n' "$database_host" "$redis_host"
