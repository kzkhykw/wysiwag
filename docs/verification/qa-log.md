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
| CI 1 | Xcode 16.4's ScreenCaptureKit headers lack Sendable annotations present in the local SDK | Import the legacy framework with @preconcurrency; framework objects stay confined to the capture actor; retain hosted older-SDK build coverage | Local rerun passed; hosted result in PR checks |

## Complete verification pass after fixes

On 2026-11-13, `scripts/verify.sh` passed: Swift build, 24 Swift Testing tests, full loopback core E2E, signed release packaging, packaged OCR and secret scan. `scripts/app-e2e.sh` passed on that release app. A second real-app sweep covered first launch, missing key, disabled/unconfigured cloud destinations, interval/mode persistence, key replacement/deletion, permission denial, English/Japanese layouts and relaunch. Long-text limits and outage recovery were checked through enforcing HTTP mocks. No new findings in this pass.

Screen Recording is denied for this bundle. Both ALL and AUTO start attempts reported the permission requirement; a 30-second live capture was therefore not performed. The bundled-image Vision OCR fallback and synthetic sequence CSV are recorded separately, not presented as live capture. Real Notion/Google consent, Notion portal acceptance of the loopback URI, and production cloud writes require user credentials and remain unverified.

The subsequent independent read-only review and any fixes are recorded in [review.md](review.md).

After the independent review fixes, the full core suite and real app E2E passed again with 24 tests and no new QA findings. The reviewer rechecked all four fixes and found no remaining actionable findings.

## Follow-up verification of ab3c771 — 2026-11-14

The independent Mac verification supplied by the user superseded the earlier clean-review conclusion. Its two P1, six P2 and one P3 findings, plus license/evidence corrections, were addressed in code rather than comments.

| Finding | Fix / executable regression protection | Result |
| --- | --- | --- |
| Interrupted quoted CSV append corrupts later rows | Durable journal + committed offset; multiline/escaped-quote tail recovery, four interrupted commit boundaries | Passed |
| CSV → outbox gap or partial destination enqueue loses intent | One journal contains CSV bytes and all destination jobs; stable IDs, atomic batch, delivery gated until commit; concurrent recovery test | Passed |
| Rename/full-flush ordering incomplete | File and parent-directory `fsync` + `F_FULLFSYNC` for journal, CSV, checkpoint, jobs and cooldowns | Local APFS operations passed; physical power loss not exercised |
| Older refresh overwrites newer authorization/cache | New authorization generation, credential revision checks and coalesced refresh flight; delayed refresh versus real loopback reauthorization tests for both providers | Passed |
| Pause/lock discards retiring capture | Retained task chain awaits predecessor before resume/apply; complete recorder transaction serialized; cancellation and baseline/dwell tests | Passed |
| Malformed job stops drain/status/retry | Quarantine original bytes, report count, continue other destinations; regression covers all three operations | Passed |
| Jev deadline reset by settings/relaunch | Retained classifier with mutable threshold and durable deadline; injected-clock rebuild/relaunch regression | Passed |
| Canceled Notion callback still owns fixed port | Await worker-owned socket close before rebinding; immediate cancel/reconnect regression | Passed |
| Catalog read blocks main-thread initialization | Detached resource loading/parsing, publish on MainActor | Read-only review passed |
| Empty license; verification rewrites committed OCR | Full MIT license; fresh outputs under `.build/verification`; verify hashes committed OCR before/after | Passed |
| Follow-up review: recovered commit leaves live baseline stale | Retain uncertain transaction and reconcile before next comparison/replacement; real checkpoint rename failure tests resume and settings replacement | Passed |
| Follow-up review: unresolved journal starves unrelated jobs | Retain/report journal and gate its batch while independent jobs drain; malformed and truncated-CSV regressions | Passed |
| Follow-up review: SMART error persists in ALL/AUTO | Gate display to SMART; clear when applying other modes without clearing cooldown | Read-only re-review passed |
| Desktop UI rerun cannot read Settings | Initial app launched but AX had no window; OS reported screen locked. Driver now records an explicit blocked result before touching test state | Blocked by locked desktop; no fresh screenshot/UI pass claimed |

Final `scripts/verify.sh`: 37 tests, loopback core E2E, signed release packaging, packaged bilingual OCR, 113 translated strings, secret scan and committed-OCR immutability check. See the [dated follow-up report](evidence/followup-2026-11-14.json). The separate reviewer rechecked the three follow-up fixes and reported no remaining actionable findings. UI changes (quarantine/recovery indicators) are compiled and localized but have not been visually verified on this locked desktop. The 2026-11-13 real UI report/screenshots remain historical evidence.

Still unverified: physical power-cut behavior, live ScreenCaptureKit capture (previous run denied permission), real Notion/Google consent and writes, and Notion portal acceptance of the configured loopback URI. Cloud delivery remains at least once, so lost acknowledgements may duplicate remote writes. Unsupported full-flush filesystems fail with a local-write error.

## Follow-up verification of b60b461 — 2026-11-14

The user’s further independent verification confirmed the earlier P1 fixes and found two remaining P2 cases. The new regression tests were run against the old implementation first: unrelated capture threw `localWrite`, and invalid continuation jobs reached the delivery probe instead of quarantine. Both tests now pass after implementation fixes.

| Finding | Fix / regression protection | Result |
| --- | --- | --- |
| Malformed shared journal blocks later captures to another CSV | Decode only the routing field first; fully decode only matching transactions. Unrouteable journals and their matching batches remain retained/gated. Retry does not rewrite gated batches. Test both another day and another folder, with opaque and readable-target malformed journals; verify original bytes and independent delivery | Passed |
| Known matching malformed journal must still stop its own append | Retain the error for the current target rather than ignoring all decode failures; CSV and journal bytes remain unchanged | Passed |
| Valid JSON with negative/out-of-range Notion progress can trap or silently drop remaining text | Validate bounds and page/progress consistency at queue load and writer entry; guard payload slicing; validate retry counters and Sheets progress too | Passed |
| Invalid job shares a batch with valid work | Durably preserve original bytes before replacing the batch with valid siblings; test legacy and mixed-batch formats through status/retry/drain | Passed |
| Valid continuation must still send all remaining text | HTTP mock asserts the correct page, PATCH operation and exact remaining paragraphs | Passed |

Five new regressions bring the suite to 42 tests. `scripts/verify.sh` passed in full: build/test, loopback core E2E, signed app packaging, packaged OCR, scans and unchanged committed OCR. A fresh separate read-only reviewer found no actionable findings. Current results are recorded in [p2-followup-2026-11-14.json](evidence/p2-followup-2026-11-14.json). Existing UI, provider and physical-power-loss limitations remain unchanged; this change adds no fresh live/UI claim. No GitHub comments or repository visibility changes are part of this work.

## Opaque-journal follow-up of 3e5f7ea — 2026-11-14

The user confirmed N1/N2 and found a remaining P2: treating unknown journal ownership like an unrelated target allowed a stale checkpoint to erase a fully written pending row after restart. The new restart regression failed against the previous implementation, including both a complete multiline row alone and that row followed by an incomplete quoted tail.

| Finding | Fix / regression protection | Result |
| --- | --- | --- |
| Opaque journal + stale checkpoint discards complete row B | Explicit `Routing.unknown` versus `.unrelated`; unknown ownership requires an RFC 4180 complete-record scan. Truncation cannot go below that boundary. Restart fixture asserts A+B+C, then A+B+C+D after another restart, checkpoint advancement and byte-preserved/gated damaged journal and batch | Passed |
| Preserve independent capture and fail safely for known matching corruption | Existing another-day/folder and matching-target corruption regressions retained | Passed |
| Continuation payload assertions could pass without HTTP | Shared thread-safe request counter; `validNotionContinuationSendsAllRemainingText` now requires exactly one request after delivery | Passed |

The suite now has 43 tests. `scripts/verify.sh` passed in full and committed OCR evidence is unchanged. The separate read-only reviewer found no actionable findings in this diff. See [opaque-journal evidence](evidence/opaque-journal-2026-11-14.json) for the full verification result. No new UI, live-provider or physical-power-loss claim is made; the earlier limitations remain. Repository visibility is unchanged and no GitHub comments are posted.
