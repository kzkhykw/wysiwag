---
name: wysiwag-verify
description: Verify WYSIWAG's macOS menu bar app and CLI using its existing Swift, loopback, and accessibility checks. Use after product changes or to launch, drive, inspect, and capture verification evidence.
---

# Verify WYSIWAG

Use this skill when changing capture modes, OCR, CSV, retries, OAuth, settings, packaging, or their checks. The primary product is a macOS menu bar app. Its Swift CLI can prove synthetic OCR, CSV, and loopback HTTP behavior without a desktop session. Read the relevant rows in [feature-map.md](feature-map.md) before selecting a check. That file is the single capability source and the CLI reads it directly.

## Capabilities

- Bring up the CLI or packaged app through the existing build scripts.
- Navigate and drive capture/OCR/cloud fixtures or the existing accessibility sequence.
- Inspect tool availability, fixture presence, and saved run state without modifying the app.
- Capture command logs, result manifests, synthetic CSV/JSON, and app-window screenshots.
- Clean up owned app/mock processes and scratch data while preserving evidence.

## Launch

Run commands from the repository root. Use macOS 14+ with Xcode and Swift 6, Python 3.9+, and Git. No Node packages or external service credentials are required. Dependencies and synthetic images are already in the repo.

```sh
verify=.agents/skills/wysiwag-verify/scripts/verify.py
"$verify" doctor
"$verify" list
"$verify" check packaging
"$verify" evidence capture-all --out /tmp/wysiwag-proof-all
```

`packaging` runs the existing app builder with `CONFIGURATION=debug`. Its signature and packaged OCR checks must pass before using the app. The core checks build `.build/debug/wysiwag-cli`, start a loopback mock on an ephemeral port, and wait for its port file. They need no database, saved account, or seed setup. A successful core check proves that the CLI can process the bundled fixtures and create/drain synthetic records from empty temporary directories.

When the outer workspace sandbox rejects SwiftPM's nested `sandbox-exec`, use this explicit option. It disables only SwiftPM's nested sandbox and places SwiftPM caches/configuration under `.build`.

```sh
"$verify" --swift-no-sandbox check capture-all
"$verify" --swift-no-sandbox evidence capture-auto --out /tmp/wysiwag-proof-auto
"$verify" --swift-no-sandbox all --out /tmp/wysiwag-proof-baseline
```

Use a new or empty output directory. The CLI refuses to overwrite existing evidence. `check` also saves evidence, by default in a unique directory under `.build/verification/runs/`. The printed path is the run's proof directory. `all` invokes `scripts/verify.sh` once, including CLI tests, Swift build/tests, core E2E, app packaging, and the secret scan. It does not claim visible UI, live capture, live provider consent, or independent review.

## Doctor

```sh
"$verify" doctor
"$verify" doctor --ui
"$verify" inspect /tmp/wysiwag-proof-all
```

`doctor` reads executable availability, platform, and bundled fixture presence. `doctor --ui` also checks desktop lock state and refuses an already running WYSIWAG app. These checks do not build, launch, read credentials, or alter app preferences. They do not certify Automation consent; `menu-bar` must reach and read the real Settings controls to prove readiness. `inspect` prints only the saved `run.json` manifest, including invoked commands, exit codes, and artifact names.

If the toolchain is suspect, use `swift --version` and `xcode-select -p`. If the app path is suspect, use `codesign --verify --deep --strict dist/WYSIWAG.app`. Never repair a failure by killing unrelated processes or clearing production preferences.

## Drive

Select a capability ID from `list`. The feature map names its user path, observations, check recipe, and remaining manual proof.

```sh
"$verify" check privacy
"$verify" evidence ocr --out /tmp/wysiwag-proof-ocr
"$verify" evidence destinations --out /tmp/wysiwag-proof-destinations
```

For visible UI, use an unlocked macOS session with `orca`, Accessibility/Automation consent for System Events, and write access to the dedicated test state. Close other WYSIWAG instances yourself before starting. Prepare a synthetic fixture window and remove unrelated screen contents before running the capture toggles.

```sh
"$verify" doctor --ui
"$verify" evidence menu-bar --out /tmp/wysiwag-proof-ui
```

This builds and starts the real app in `--evidence` mode. The existing `scripts/app-e2e.py` sequence drives stable `AXIdentifier` handles, including `mode-ALL`, `interval`, `save-settings`, `toggle-capture`, and `section-Destinations`. It checks persisted settings after relaunch, replaces/deletes a fake credential, and switches to Japanese. See the map for all navigation handles.

The UI uses the fixed `com.wysiwag.evidence` preferences and Keychain service, `~/Library/Application Support/WYSIWAG-Evidence/Outbox`, and `/tmp/WYSIWAG-Evidence` for captured CSV. It is not isolated across simultaneous UI runs. Run one command per checkout and one app E2E per user session. The driver refuses a running WYSIWAG process. It never opens live OAuth consent. Do not inspect credential values, production outbox/CSV files, or environment files.

## Evidence

Every `check`, `evidence`, and `all` run keeps `check.log` and `run.json`, including failures. Exit 0 means the selected automated check passed. Exit 2 means invalid arguments/map/output, exit 3 means an unmet manual/UI prerequisite, exit 127 means a command could not start, and child failures preserve their exit code. An interruption returns 130 after terminating the owned command group.

For core checks, retain `core-e2e.json`, `fixture-csv-head.csv`, and `ocr-dry-run.csv`. The JSON records real fixture row counts, classifier calls, outage recovery, and long-text/rate-limit results. `check.log` records the action and assertions. The CSV parser independently checks headers, dwell times, bilingual text, and drained queues. These mocks replace only external HTTP providers; Vision OCR, local files, and the product's recorder/queue are real.

For UI checks, retain `app-e2e.json`, `app-e2e-attempt.json`, and the `screenshots/` directory. Screenshots contain only WYSIWAG's window. The report records actual Screen Recording permission results. A denial is evidence of a blocked live path, not successful live capture. Capture toggles can write the active window's OCR when permission is granted; this is why the desktop must contain only prepared fixtures.

Use the action log and resulting state together. A screenshot alone does not prove persistence or cloud delivery. Unit checks prove their stated regressions, not UI flows. A live OAuth/network claim needs an authorized live run; loopback success does not establish it. Keep new evidence outside `docs/verification/evidence`, which contains historical tracked snapshots.

## Cleanup

The check scripts clean up their own processes on completion and failure. Core E2E kills/waits for its recorded mock PID and removes its temporary run directory after copying evidence. App E2E terminates/waits for only its launched process, removes its uniquely named malformed queue fixture, and deletes its fake Keychain item. Ctrl-C through the CLI terminates the owned process group and retains the failed run manifest/log.

The UI's test preferences and any live fixture CSV remain for inspection. Do not delete the shared test domain or outbox while another run may use them. This skill does not clear production state or remove evidence. There is no long-lived server to stop after `check` returns. Confirm proof survives cleanup with:

```sh
"$verify" inspect /tmp/wysiwag-proof-all
ls /tmp/wysiwag-proof-all
```

Build outputs remain under `.build` and `dist`. Do not remove `.build` if it contains evidence you still need.

## Helpers and maintenance

The executable helper is [scripts/verify.py](scripts/verify.py). It uses only Python's standard library. It dispatches existing scripts and Swift tests; it does not implement product verification assertions a second time.

```sh
"$verify" --help
python3 -m unittest discover -s .agents/skills/wysiwag-verify/scripts -p 'test_*.py' -v
scripts/verify.sh
```

Update the feature map when a user path or check changes. `/maintain-verification-skill` can audit the map against the app. Preserve the one-line pointer at `docs/verification/feature-map.md` for existing links.
