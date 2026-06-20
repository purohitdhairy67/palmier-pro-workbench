#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Local fork launcher. Avoids requiring Palmier's Developer ID certificate.
# Placeholder backend values keep Info.plist complete; generation/login can stay unused.
export SIGNING_IDENTITY="-"
export CLERK_PUBLISHABLE_KEY="${CLERK_PUBLISHABLE_KEY:-pk_test_workbench}"
export CONVEX_DEPLOYMENT_URL="${CONVEX_DEPLOYMENT_URL:-https://workbench.invalid}"
export CONVEX_HTTP_URL="${CONVEX_HTTP_URL:-https://workbench.invalid}"

"$ROOT/scripts/bundle.sh" debug --fast
open "$ROOT/.build/PalmierPro.app"

