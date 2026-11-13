#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
evidence_dir=${WYSIWAG_EVIDENCE_DIR:-"$PWD/.build/verification"}
mkdir -p "$evidence_dir"
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/wysiwag-e2e.XXXXXX")
python3 scripts/mock-services.py --port-file "$run_dir/port" > "$run_dir/mock.log" 2>&1 &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT
for _ in {1..50}; do [ -s "$run_dir/port" ] && break; sleep 0.1; done
port=$(cat "$run_dir/port")
.build/debug/wysiwag-cli verify --mock-base "http://127.0.0.1:$port" --output "$run_dir/output"
python3 - "$run_dir/output" "$evidence_dir" <<'PY'
import csv, pathlib, sys
root=pathlib.Path(sys.argv[1])
for mode, expected in [('ALL', 6), ('AUTO', 4), ('SMART', 4)]:
    file=next((root/mode).glob('*.csv'))
    with file.open(newline='') as stream: rows=list(csv.DictReader(stream))
    assert len(rows)==expected, (mode,len(rows))
    assert list(rows[0])==['timestamp','active_app','window_title','visible_text','dwell_seconds']
    assert float(rows[0]['dwell_seconds'])==0
    assert [float(row['dwell_seconds']) for row in rows[1:]]==([5]*5 if mode=='ALL' else [10,5,5])
    assert '日本語' in rows[0]['visible_text']
    assert not list((root/mode/'outbox').glob('*.json'))
    if mode=='ALL':
        evidence=pathlib.Path(sys.argv[2])
        evidence.mkdir(parents=True,exist_ok=True)
        with (evidence/'fixture-csv-head.csv').open('w',newline='') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]))
            writer.writeheader()
            for row in rows[:5]:
                if len(row['visible_text'])>80:
                    row['visible_text']=row['visible_text'][:80]+' [preview truncated]'
                writer.writerow(row)
print('PASS: independent CSV parser, exact dwell times, bilingual text and empty durable queues')
PY
if [ -s "$run_dir/mock.log" ]; then cat "$run_dir/mock.log"; exit 1; fi
cp "$run_dir/output/core-e2e.json" "$evidence_dir/core-e2e.json"
.build/debug/wysiwag-cli capture --once --dry-run > "$evidence_dir/ocr-dry-run.csv"
printf 'Evidence: %s\n' "$evidence_dir"
