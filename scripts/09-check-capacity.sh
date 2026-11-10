#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=./lib/capacity.sh
source "$SCRIPT_DIR/lib/capacity.sh"
load_config
require_value AZURE_RESOURCE_GROUP
require_value AZURE_LOCATION
require_command jq
select_subscription
check_capacity
