# Verification evidence

Local run: 2026-11-13, Apple Silicon, macOS 26.0.1, Swift 6.2.4. Deployment target: macOS 14. All committed screen/text evidence is synthetic. No production credentials were used.

| Check | Result | Artifact |
| --- | --- | --- |
| `swift build` / `swift test` | Passed; 24 tests | [Test sources](../../../Tests/WYSIWAGCoreTests) |
| `scripts/core-e2e.sh` | ALL 6 rows / 0 Jev requests; AUTO 4 / 0; SMART 4 / 6 | [Machine report](core-e2e.json) |
| Network outage → recovery | CSV intact in all modes; persisted queues drained after server recovery | [Machine report](core-e2e.json) |
| Notion/Sheets payload and rate limits | 2,000-unit rich text, 100-child batches, byte budget, 49,000-unit cells, RAW and Retry-After passed | [Driver](../../../Sources/WYSIWAGCLI/VerificationDriver.swift), [enforcing server](../../../scripts/mock-services.py) |
| Real Vision OCR fallback | English + Japanese recognized from bundled image | [Dry-run output](ocr-dry-run.csv), [fixture](../../../Sources/WYSIWAGCore/Resources/ocr-fixture.png) |
| Synthetic sequence CSV | First five logical ALL records; text shortened for preview, multiline quoting preserved | [CSV preview](fixture-csv-head.csv) |
| `scripts/build-app.sh` | Release app, strict ad-hoc signature verification and packaged bilingual OCR passed | [Build driver](../../../scripts/build-app.sh) |
| `scripts/app-e2e.sh` | Real app first launch, three modes, interval persistence, fake key set/clear, relaunch and language persistence passed | [Machine report](app-e2e.json) |
| English/Japanese visual QA | Reviewed, no clipping in Capture settings | [English](../../screenshots/settings-en.png), [Japanese](../../screenshots/settings-ja.png) |
| Missing cloud configuration / privacy defaults | Local always on; unconfigured cloud toggles disabled; exclusion/idle controls present | [Destinations](destinations-en.png), [Privacy](privacy-en.png) |
| Japanese destination scrolling | Google setup and retry controls remain visible and readable at the bottom | [Japanese destinations](destinations-ja-bottom.png) |
| ALL / AUTO live capture | **Blocked: Screen Recording denied** for both attempts; no live rows claimed | [Permission state](permission-state.png), [UI report](app-e2e.json) |
| Secrets / localization | Repository and built binaries scanned; all 109 catalog strings have English and Japanese | [Checks](../../../scripts/check-no-secrets.py), [catalog check](../../../scripts/check-localization.py) |

The CLI fallback command is `swift run wysiwag-cli capture --once --dry-run`. It proves actual on-device OCR of the bundled image, not live screen permission. Real cloud authentication/writes and provider-console registration are not represented by mock tests.

Reproduce with `scripts/verify.sh`, then `scripts/app-e2e.sh` on a logged-in desktop with Accessibility automation permission and Orca installed. App E2E uses only `com.wysiwag.evidence` preferences/Keychain and removes its fake key. Core E2E binds loopback and never loads saved credentials. The macOS CI workflow runs build, unit, core E2E, app packaging and scans; desktop UI tests are local only.
