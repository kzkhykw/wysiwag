# Independent read-only review

The first review below is historical. The user’s later verification of `ab3c771` found additional issues; the 2026-11-14 follow-up supersedes its clean conclusion and obsolete CSV/outbox-gap limitation.

2026-11-13. A fresh GPT-6 Astra session reviewed the whole implementation relative to the initial repository, including untracked files, tests, scripts, localization, documentation and synthetic evidence. Scope: secret leaks, local data loss/network resilience, main-thread blocking, races, OAuth correctness and the amended brief. The reviewer made no changes, ran no mutating tests, and accessed no production credentials or personal screen content.

| Severity | Finding | Fix and regression |
| --- | --- | --- |
| P1 | An in-flight OAuth response could restore a deleted credential or Google access-token cache, enabling later uploads | Actor-owned sign-out, generation and cancellation checks before persistence; delayed Google refresh and Notion exchange tests |
| P2 | A slow 429 response consumed part of Retry-After before receipt | Anchor retry deadlines to response time; injected-clock test verifies a delayed response and relaunch |
| P2 | Notion's fixed loopback port could fail immediate reconnection after a callback | Reproduced the failing immediate-rebind test, then set SO_REUSEADDR before bind without SO_REUSEPORT |
| P2 | Clearing Notion's visible database selection retained its old database ID | Clear both IDs and disable Notion; require an explicit selected source; selection-reset regression |

The primary implementation session fixed each finding. The reviewer then re-read the affected code and `RaceRegressionTests.swift` and reported **no remaining actionable findings**. The reviewer found no secret disclosure or substantial main-thread blocking; local CSV-before-cloud persistence remains intact.

Re-verification after fixes: `scripts/verify.sh` passed with 24 tests, full core E2E, strict signed-app verification, packaged OCR and scans. Real app E2E was rerun on that release build. The OAuth races, delayed Retry-After, fixed-port reconnect and target clearing are now executable regression checks.

Limits retained explicitly: cloud delivery is at least once; a crash between CSV flush and outbox persistence can leave a local-only row; Screen Recording was denied; real provider consent/writes and Notion portal registration were not exercised. These are documented in the README and draft PR rather than represented as successful live verification.

CI follow-up: Xcode 16.4's SDK lacks the newer ScreenCaptureKit Sendable annotations. The reviewer separately checked the `@preconcurrency` import compatibility change and found no new isolation issue: capture framework objects stay local to each actor invocation, configuration is not mutated after dispatch, and only `ScreenSnapshot` leaves the actor. Hosted CI supplies older-SDK compilation coverage.

## Follow-up — 2026-11-14

The user's independent Mac review of `ab3c771` identified interrupted-CSV corruption, stale refresh versus reauthorization, missing outbox intent, durability ordering, capture retirement, malformed-job starvation, lost Jev cooldown, fixed-port teardown and synchronous catalog loading. The [QA log](qa-log.md#follow-up-verification-of-ab3c771--2026-11-14) maps each to implementation and regression coverage.

A fresh GPT-6 Astra reviewer then inspected the fixes read-only, without running tests, editing files, accessing credentials or viewing screens. It found three further issues: live baseline not reconciled after roll-forward, unrecoverable journals starving unrelated batches, and retained SMART errors displaying in AUTO/ALL. All three were fixed; new tests induce a real checkpoint-write failure and isolate unresolved journals from valid jobs. The reviewer re-read the resulting code/tests and reported **no remaining actionable findings**.

Primary-session verification: 37 tests and the full verification script passed. New UI indicators remain unverified visually because this desktop is locked; existing screenshots are dated 2026-11-13. Tests construct interrupted on-disk states and validate recovery, but do not establish physical power-loss behavior. Real provider consent/writes, Notion portal redirect acceptance and live capture remain unverified. Remote delivery remains at least once. The prior CSV/outbox intent gap is now closed by the recoverable transaction, rather than retained as a documentation-only limitation.

## P2 follow-up review of b60b461 — 2026-11-14

The user’s additional verification superseded the previous clean conclusion for two remaining paths: malformed unrelated journals stopped future captures, and decoded Notion jobs could carry invalid continuation progress. Five regression tests were added; the two reproductions failed on the old implementation before fixes.

A new separate read-only session inspected the journal routing, queue validation, original-byte preservation, valid sibling delivery and writer bounds checks. It reported **no actionable findings**. The reviewer did not edit files, run tests, access credentials/UI or perform GitHub actions. The primary session ran `scripts/verify.sh` successfully with 42 tests; the committed OCR artifact remained unchanged. UI/provider/physical-power-loss limitations from earlier evidence remain explicit. See [latest evidence](evidence/p2-followup-2026-11-14.json).

## Opaque-journal follow-up of 3e5f7ea — 2026-11-14

The user’s subsequent verification found that unknown ownership could still authorize destructive truncation at a stale checkpoint. A new restart fixture reproduced complete row B disappearing before the fix. Unknown and unrelated routing now have separate enum cases; unknown ownership requires a complete-record boundary scan, preserving complete pending rows while retaining/gating the damaged journal and its batch. The Notion continuation test also asserts exactly one HTTP request.

A new separate read-only reviewer inspected the current diff, including recovery under the CSV lock, restart fixtures with/without a partial tail, independent-target behavior and request counting. It reported **no actionable findings**. It ran no tests and changed no files. The primary session’s `scripts/verify.sh` passed with 43 tests and unchanged committed OCR evidence. Prior live/UI/provider/physical-power-loss limitations remain. See [current evidence](evidence/opaque-journal-2026-11-14.json).
