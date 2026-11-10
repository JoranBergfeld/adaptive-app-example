#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/50-deploy-target.sh" onprem
printf 'On-premises-style ARO target is warm; its Front Door origin remains disabled.\n'
