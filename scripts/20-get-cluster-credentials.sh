#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_value AZURE_RESOURCE_GROUP
require_command az
require_command kubectl
require_command jq
require_command awk
select_subscription

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
aro_kubeconfig="$SECRETS_DIR/aro.kubeconfig"
onprem_kubeconfig="$SECRETS_DIR/onprem.kubeconfig"
az aro get-admin-kubeconfig \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$ARO_CLUSTER_NAME" \
  --file "$aro_kubeconfig" \
  --overwrite-existing \
  --only-show-errors
az aro get-admin-kubeconfig \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --name "$ONPREM_CLUSTER_NAME" \
  --file "$onprem_kubeconfig" \
  --overwrite-existing \
  --only-show-errors
chmod 600 "$aro_kubeconfig" "$onprem_kubeconfig"

aro_context="$(awk '$1 == "current-context:" {print $2; exit}' "$aro_kubeconfig")"
onprem_context="$(awk '$1 == "current-context:" {print $2; exit}' "$onprem_kubeconfig")"
if [[ -z "$aro_context" || -z "$onprem_context" || "$aro_context" == "$onprem_context" ]]; then
  printf 'Could not identify two distinct contexts in the generated kubeconfigs.\n' >&2
  exit 1
fi

kubectl --kubeconfig "$aro_kubeconfig" --context "$aro_context" \
  config view --minify --raw --output json |
  jq '.["current-context"]="aro-demo"
    | .contexts[0].name="aro-demo"
    | .contexts[0].context.cluster="aro-demo-cluster"
    | .contexts[0].context.user="aro-demo-user"
    | .clusters[0].name="aro-demo-cluster"
    | .users[0].name="aro-demo-user"' \
    >"$SECRETS_DIR/aro-demo.kubeconfig"
kubectl --kubeconfig "$onprem_kubeconfig" --context "$onprem_context" \
  config view --minify --raw --output json |
  jq '.["current-context"]="onprem-demo"
    | .contexts[0].name="onprem-demo"
    | .contexts[0].context.cluster="onprem-demo-cluster"
    | .contexts[0].context.user="onprem-demo-user"
    | .clusters[0].name="onprem-demo-cluster"
    | .users[0].name="onprem-demo-user"' \
    >"$SECRETS_DIR/onprem-demo.kubeconfig"
chmod 600 "$SECRETS_DIR/aro-demo.kubeconfig" "$SECRETS_DIR/onprem-demo.kubeconfig"

printf 'ARO_CONTEXT=aro-demo\nONPREM_CONTEXT=onprem-demo\nKUBECONFIG=' \
  >"$SECRETS_DIR/contexts.env"
printf '%q:%q\n' \
  "$SECRETS_DIR/aro-demo.kubeconfig" "$SECRETS_DIR/onprem-demo.kubeconfig" \
  >>"$SECRETS_DIR/contexts.env"
chmod 600 "$SECRETS_DIR/contexts.env"
printf 'Cluster credentials saved privately under .secrets/.\n'
printf 'Contexts: aro-demo and onprem-demo\n'
