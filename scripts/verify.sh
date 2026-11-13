#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
swift test
scripts/core-e2e.sh
scripts/build-app.sh
scripts/check-no-secrets.sh
