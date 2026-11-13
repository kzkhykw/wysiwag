# QA log

Only synthetic fixture content is used in committed evidence. Amendment 1 supersedes the original SMART behavior: default AUTO is mechanical, SMART calls Jev without a pre-filter.

| Pass | Finding | Fix / regression protection | Result |
| --- | --- | --- | --- |
| Core 1 | Vision omitted Japanese despite listing en/ja | Automatic language detection; unit and CLI assertions require both languages | Passed |
| Build 1 | Swift 6 rejected a non-Sendable SCWindow closure capture | Extract CGRect before sorting displays | Passed |
| Build 1 | OAuth listener initializer captured self before initialization | Bind a local descriptor before initializing the object | Passed |
| OAuth 1 | Accepted sockets inherited nonblocking mode and could reject valid early callbacks | Clear O_NONBLOCK; real loopback round-trip regression with a deadline | Passed |
| Packaging 1–2 | SwiftPM resource lookup failed inside the app; copying bundles at the root then broke strict signing | Resolve Contents/Resources explicitly, put CLI resources beside CLI; packaged bilingual OCR smoke test in every build | Passed |
| First launch 1 | LSUIElement app did not open a usable Settings window | Retained NSWindow/SwiftUI host opened by AppDelegate; real-app launch assertion | Passed |
| Concurrency 1 | Applying settings could overlap old/new queue drains and reset dwell | Cancel and await tasks before replacement; preserve previous written snapshot; dwell regression test | Passed |
| App driver 1 | AXValue changed the interval visually without committing the edit | Focus, type and Tab; assert preferences and relaunch | Passed |
| App QA 1 | Destination evidence displayed the developer home path | Isolated evidence profile uses `/tmp/WYSIWAG-Evidence`; regenerate window-only screenshots | Passed |
| App QA 1 | Long Japanese help text needed wrapping; buttons needed AX labels | Vertical text wrapping and localized accessibility labels; visual review and UI rerun | Passed |
| App QA 1 | Incomplete enabled cloud configuration could create unusable jobs | Guard settings saves; disable unconfigured destination toggles; UI assertions | Passed |
| Retry QA 1 | Destination Retry-After existed only in memory | Persist cooldowns and test a new queue instance before expiry | Passed |

## Complete verification pass after fixes

On 2026-11-13, `scripts/verify.sh` passed: Swift build, 24 Swift Testing tests, full loopback core E2E, signed release packaging, packaged OCR and secret scan. `scripts/app-e2e.sh` passed on that release app. A second real-app sweep covered first launch, missing key, disabled/unconfigured cloud destinations, interval/mode persistence, key replacement/deletion, permission denial, English/Japanese layouts and relaunch. Long-text limits and outage recovery were checked through enforcing HTTP mocks. No new findings in this pass.

Screen Recording is denied for this bundle. Both ALL and AUTO start attempts reported the permission requirement; a 30-second live capture was therefore not performed. The bundled-image Vision OCR fallback and synthetic sequence CSV are recorded separately, not presented as live capture. Real Notion/Google consent, Notion portal acceptance of the loopback URI, and production cloud writes require user credentials and remain unverified.

The subsequent independent read-only review and any fixes are recorded in [review.md](review.md).

After the independent review fixes, the full core suite and real app E2E passed again with 24 tests and no new QA findings. The reviewer rechecked all four fixes and found no remaining actionable findings.
