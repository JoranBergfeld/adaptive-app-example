#!/usr/bin/env bash
set -euo pipefail

python3 -c 'import json, os; print("window.SHOP_CONFIG = " + json.dumps({"apiBaseUrl": os.getenv("SHOP_API_BASE_URL", "")}) + ";")' \
  > /opt/app-root/src/config.js
exec python3 /opt/app-root/src/server.py
