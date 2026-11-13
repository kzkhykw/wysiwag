#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v orca >/dev/null
/usr/bin/python3 scripts/app-e2e.py
