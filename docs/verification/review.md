# Independent read-only review

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
