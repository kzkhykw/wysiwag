#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
evidence_before=$(git hash-object docs/verification/evidence/ocr-dry-run.csv)
python3 -m unittest discover -s .agents/skills/wysiwag-verify/scripts -p 'test_*.py'
swift build "$@"
swift test "$@"
scripts/core-e2e.sh "$@"
scripts/build-app.sh "$@"
scripts/check-no-secrets.sh
test "$evidence_before" = "$(git hash-object docs/verification/evidence/ocr-dry-run.csv)"
printf 'PASS: committed OCR evidence is unchanged\n'
