#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

for command_name in rad helm kubectl jq; do
  require_command "$command_name"
done
if [[ "$ARO_CONTEXT" == "$ONPREM_CONTEXT" ]]; then
  printf 'ARO_CONTEXT and ONPREM_CONTEXT must be different kubeconfig contexts.\n' >&2
  exit 1
fi

helm repo add dapr https://dapr.github.io/helm-charts/
helm repo update dapr

install_platform() {
  local context="$1"
  kubectl --context "$context" cluster-info >/dev/null
  helm upgrade --install dapr dapr/dapr \
    --version "$DAPR_VERSION" \
    --namespace dapr-system \
    --create-namespace \
    --kube-context "$context" \
    --wait \
    --timeout 15m
  rad install kubernetes \
    --kubecontext "$context" \
    --skip-contour-install \
    --set "global.imageTag=$RADIUS_VERSION" \
    --timeout 15m
  kubectl --context "$context" create namespace shop \
    --dry-run=client \
    --output yaml |
    kubectl --context "$context" apply --filename -
}

install_platform "$ARO_CONTEXT"
install_platform "$ONPREM_CONTEXT"
kubectl --context "$ARO_CONTEXT" apply --filename "$REPO_ROOT/chaos/rbac-aro.yaml"
kubectl --context "$ONPREM_CONTEXT" apply --filename "$REPO_ROOT/chaos/rbac-onprem.yaml"

kubectl --context "$ONPREM_CONTEXT" apply \
  --server-side \
  --filename "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl --context "$ONPREM_CONTEXT" rollout status \
  --namespace cnpg-system \
  deployment/cnpg-controller-manager \
  --timeout=10m

for workspace_context in \
  "$ARO_CONTEXT:aro-workspace" \
  "$ONPREM_CONTEXT:onprem-workspace"; do
  context="${workspace_context%%:*}"
  workspace="${workspace_context##*:}"
  rad workspace create kubernetes "$workspace" \
    --context "$context" \
    --group default \
    --force
  if ! rad group show default --workspace "$workspace" >/dev/null 2>&1; then
    rad group create default --workspace "$workspace"
  fi
done

printf 'Dapr, Radius, and CloudNativePG are installed.\n'
printf 'Radius/Dapr compatibility with ARO remains an unverified demo prerequisite.\n'
