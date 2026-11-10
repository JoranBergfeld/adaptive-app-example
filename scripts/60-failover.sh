#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
load_config

"$SCRIPT_DIR/50-deploy-target.sh" onprem
"$SCRIPT_DIR/90-switch-traffic.sh" onprem

printf 'Traffic now targets the on-premises-style ARO cluster.\n'
printf "PostgreSQL and Redis data were not migrated; the app starts with that cluster's state.\n"
