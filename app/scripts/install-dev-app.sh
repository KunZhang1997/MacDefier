#!/bin/bash
# Compatibility entry: one production-identity installation, no parallel Dev app.
set -euo pipefail
exec /bin/bash "$(cd "$(dirname "$0")" && pwd)/install-app.sh" "$@"
