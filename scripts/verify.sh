#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
evidence_before=$(git hash-object docs/verification/evidence/ocr-dry-run.csv)
swift build
swift test
scripts/core-e2e.sh
scripts/build-app.sh
scripts/check-no-secrets.sh
test "$evidence_before" = "$(git hash-object docs/verification/evidence/ocr-dry-run.csv)"
printf 'PASS: committed OCR evidence is unchanged\n'
