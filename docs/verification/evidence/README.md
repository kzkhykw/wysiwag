# Verification evidence

Latest core verification: **2026-11-14**, Apple Silicon, macOS 26.0.1, Swift 6.2.4; 43 tests passed. Deployment target: macOS 14. The previous follow-up’s app UI attempt was **blocked by the locked desktop**; UI was not rerun for this core-only follow-up. UI screenshots and the successful app report below are historical, from **2026-11-13**, before the follow-up fixes. All committed screen/text evidence is synthetic. No production credentials were used.

The [opaque-journal report](opaque-journal-2026-11-14.json) records the current 43-test run, restart regression and explicit Notion request count. The [previous P2 report](p2-followup-2026-11-14.json) retains its 42-test run; the [earlier follow-up report](followup-2026-11-14.json) retains the previous 37-test run and UI limitation. Fresh core outputs live under `.build/verification`; routine verification no longer rewrites committed OCR evidence.

| Check | Result | Artifact |
| --- | --- | --- |
| `swift build` / `swift test` | Passed; 43 tests | [Test sources](../../../Tests/WYSIWAGCoreTests) |
| `scripts/core-e2e.sh` | ALL 6 rows / 0 Jev requests; AUTO 4 / 0; SMART 4 / 6 | [Machine report](core-e2e.json) |
| Network outage → recovery | CSV intact in all modes; persisted queues drained after server recovery | [Machine report](core-e2e.json) |
| Notion/Sheets payload and rate limits | 2,000-unit rich text, 100-child batches, byte budget, 49,000-unit cells, RAW and Retry-After passed | [Driver](../../../Sources/WYSIWAGCLI/VerificationDriver.swift), [enforcing server](../../../scripts/mock-services.py) |
| Real Vision OCR fallback | English + Japanese recognized from bundled image | [Dry-run output](ocr-dry-run.csv), [fixture](../../../Sources/WYSIWAGCore/Resources/ocr-fixture.png) |
| Synthetic sequence CSV | First five logical ALL records; text shortened for preview, multiline quoting preserved | [CSV preview](fixture-csv-head.csv) |
| Crash/truncation recovery and all-destination intent | Four interrupted commit boundaries, quoted multiline tail, stable IDs, concurrent capture/drain | [Recovery tests](../../../Tests/WYSIWAGCoreTests/RecoveryTests.swift) |
| Live baseline, capture retirement and job isolation | Real checkpoint failure → resume/replacement; malformed jobs quarantined; unresolved journal does not starve others | [Recovery tests](../../../Tests/WYSIWAGCoreTests/RecoveryTests.swift) |
| Malformed journal during later capture | Another day/folder continues; opaque and readable-target damage retained; same-target damage still stops that CSV | [Recovery tests](../../../Tests/WYSIWAGCoreTests/RecoveryTests.swift) |
| Invalid Notion continuation progress | Negative, out-of-range, terminal and inconsistent progress quarantined; original mixed-batch bytes preserved; valid siblings/continuations send; exactly one HTTP request asserted | [Recovery tests](../../../Tests/WYSIWAGCoreTests/RecoveryTests.swift), [writer tests](../../../Tests/WYSIWAGCoreTests/IntegrationTests.swift) |
| Opaque journal + stale checkpoint after restart | Complete multiline B survives A-checkpoint + next append; optional partial tail removed; subsequent restart preserves all rows; damaged journal/batch stay gated | [Restart regression](../../../Tests/WYSIWAGCoreTests/RecoveryTests.swift), [current report](opaque-journal-2026-11-14.json) |
| OAuth sessions and listener teardown | Both providers reject delayed refresh after reauthorization; concurrent refreshes coalesce; cancel/rebind succeeds | [Session tests](../../../Tests/WYSIWAGCoreTests/SessionRegressionTests.swift) |
| Jev persisted deadline | Settings threshold change, new instance and relaunch before/after expiry | [Session tests](../../../Tests/WYSIWAGCoreTests/SessionRegressionTests.swift) |
| Latest desktop UI | **2026-11-14 blocked: screen locked**; new queue indicators compiled/localized, visual check outstanding | [Follow-up report](followup-2026-11-14.json) |
| `scripts/build-app.sh` | Release app, strict ad-hoc signature verification and packaged bilingual OCR passed | [Build driver](../../../scripts/build-app.sh) |
| `scripts/app-e2e.sh` | **2026-11-13 historical pass**: real app first launch, three modes, interval persistence, fake key set/clear, relaunch and language persistence passed | [Machine report](app-e2e.json) |
| English/Japanese visual QA | **2026-11-13**: reviewed, no clipping in Capture settings | [English](../../screenshots/settings-en.png), [Japanese](../../screenshots/settings-ja.png) |
| Missing cloud configuration / privacy defaults | **2026-11-13**: local always on; unconfigured cloud toggles disabled; exclusion/idle controls present | [Destinations](destinations-en.png), [Privacy](privacy-en.png) |
| Japanese destination scrolling | **2026-11-13**: Google setup and retry controls remain visible and readable at the bottom | [Japanese destinations](destinations-ja-bottom.png) |
| ALL / AUTO live capture | **2026-11-13 blocked: Screen Recording denied** for both attempts; no live rows claimed | [Permission state](permission-state.png), [UI report](app-e2e.json) |
| Secrets / localization | Repository and built binaries scanned; all 113 catalog strings have English and Japanese | [Checks](../../../scripts/check-no-secrets.py), [catalog check](../../../scripts/check-localization.py) |

The CLI fallback command is `swift run wysiwag-cli capture --once --dry-run`. It proves actual on-device OCR of the bundled image, not live screen permission. Real cloud authentication/writes and provider-console registration are not represented by mock tests.

Reproduce with `scripts/verify.sh`, then `scripts/app-e2e.sh` on an unlocked desktop with Accessibility automation permission and Orca installed. App E2E uses only `com.wysiwag.evidence` preferences/Keychain and removes its fake key. Core E2E binds loopback and never loads saved credentials. The macOS CI workflow runs build, unit, core E2E, app packaging and scans; desktop UI tests are local only.

Durability checks exercise interrupted on-disk states and real write failures on local APFS, not a physical power cut. Filesystems without full-flush support fail explicitly. Cloud delivery remains at least once. See the [review](../review.md) and [QA log](../qa-log.md) for findings and fixes.
