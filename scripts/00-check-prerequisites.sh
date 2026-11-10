#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

for command_name in az rad kubectl oc helm dapr jq curl git docker openssl; do
  require_command "$command_name"
done

az account show --only-show-errors --output none
docker compose version
rad version
dapr version
printf 'Prerequisite tools are installed and Azure CLI is signed in.\n'
