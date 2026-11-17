# WYSIWAG capability map

This is the maintained verification source. The CLI reads the five-column table below. Each ID is accepted by `check` and `evidence`. The check column names an existing script recipe or an exact Swift test filter. Keep table cells on one line and do not put pipe characters inside a cell.

All paths below are relative to the repository root. Run `.agents/skills/wysiwag-verify/scripts/verify.py evidence <id> --out <new-directory>` to drive the listed check and retain its log and artifacts. Add `--swift-no-sandbox` before the subcommand in a restricted workspace. See [the skill](SKILL.md) for launch, doctor, evidence, and cleanup commands.

| ID | User-facing capability | How to drive it | How to observe it | Check recipe |
| --- | --- | --- | --- | --- |
| `menu-bar` | Menu bar status, pause/resume, and Settings | App E2E launches the packaged app, presses `toggle-capture`, and reads `capture-status` | App report and window screenshots. The menu bar menu itself still needs manual inspection | `app` |
| `live-capture` | ScreenCaptureKit active-window capture | Prepare a synthetic fixture window, then run `.build/debug/wysiwag-cli capture --once --dry-run --live` | Requires an unlocked desktop and Screen Recording consent. Confirm the CSV contains only the fixture, or record an explicit TCC denial. Thirty-second ALL/AUTO capture remains manual | `manual` |
| `ocr` | English/Japanese OCR and reading order | Core E2E reads both bundled synthetic images through Vision and runs CLI dry-run | `ocr-dry-run.csv`, bilingual text and changed-image assertions. Complex layout reading order still needs visual inspection | `core` |
| `capture-all` | ALL writes every sample | Core E2E sends six fixture frames in ALL mode | Six CSV rows and five-second dwell values in the independent CSV parser, zero Jev requests | `core` |
| `capture-auto` | AUTO default, app/title/text threshold, no classifier network | Core E2E changes fixture text, app, and title; `swift test` covers default/threshold separately | Four CSV rows, exact dwell values, and zero Jev requests in `core-e2e.json` | `core` |
| `capture-smart` | SMART calls Jev on every capture, including the first | Core E2E sends six frames to the loopback mock | Six Jev requests and four rows in `core-e2e.json`. UI enable/clear behavior is covered by `menu-bar` | `core` |
| `smart-failure` | SMART failure status, changed fallback, and backoff | Run the existing failure/cooldown unit test | Assertions cover failure-as-changed and cooldown. The status menu and full HTTP-error sweep are separate UI/manual checks | `unit:jevFailureFallbackAndCooldown` |
| `csv` | CSV header, RFC 4180, newline, local offset, day, and dwell | Run CSV unit checks, then use `capture-all` for the real CLI path | Unit assertions cover quoting, timestamp offset, daily append and owner-only permissions; core evidence covers independent parsing | `unit:csv` |
| `append-recovery` | Interrupted append and all-destination commit recovery | Run recovery tests that construct interrupted disk states | Swift assertions cover four commit boundaries, multiline tails, concurrent drain/append, opaque journals, and stale offsets. Physical power loss is unverified | `unit:CoreTests` |
| `capture-retirement` | Recovered live baseline and capture retirement | Run session retirement/recovery regressions | Pause/resume/replacement task ordering and serialized dwell/baseline assertions | `unit:CoreTests` |
| `quarantine` | Malformed jobs and unresolved journals | Run malformed queue/journal regressions | Original bytes retained, independent jobs continue, matching-target failures remain blocked. UI count is covered by `menu-bar` | `unit:CoreTests` |
| `notion-continuation` | Notion continuation validity and mixed batches | Run invalid and valid continuation regressions | Invalid offsets rejected before HTTP, exact remaining text, one-request assertion, and valid sibling drain | `unit:CoreTests` |
| `oauth-sessions` | OAuth session isolation and refresh coalescing | Run delayed-refresh and reauthorization regressions | Stale sessions cannot overwrite authorization, concurrent refreshes share one HTTP request | `unit:CoreTests` |
| `notion-listener` | Notion listener retirement | Cancel then immediately reauthorize in the existing loopback regression | Fixed port reuse succeeds after the old listener closes | `unit:notionCancelThenReconnectAwaitsListenerShutdown` |
| `smart-cooldown` | Jev cooldown across settings and relaunch | Run the injected-clock regression | Persisted deadline survives threshold changes, rebuild, and relaunch | `unit:jevCooldownSurvivesThresholdChangesRebuildAndRelaunch` |
| `evidence-integrity` | Evidence immutability and MIT license | Run `scripts/verify.sh` through the CLI; inspect `LICENSE` for licensing | Verify compares the tracked OCR snapshot hash before/after. License text is a manual read, not an automated licensing audit | `verify` |
| `notion-auth` | Notion OAuth, state, Keychain, and granted database picker | Run mock exchange/refresh/search and callback tests | Unit assertions prove local behavior. Live consent requires a public integration and external network; it is not verified by this check | `unit:CoreTests` |
| `notion-schema` | Notion data-source parent/schema and select/rich_text | Core E2E sends fixture records to the enforcing loopback server | Expected page count and accepted payload schema. Database chooser requires UI inspection | `core` |
| `notion-limits` | Notion 2000-unit, 100-child, byte-cap, and continuation limits | Core E2E sends long bilingual text | `longText: passed`, append continuation requests, and an empty durable queue | `core` |
| `google-auth` | Google PKCE, loopback, state, and refresh | Run PKCE/callback/refresh and real loopback unit checks | Local callback and session assertions. Live consent requires a desktop client and external network | `unit:CoreTests` |
| `sheets` | Sheets RAW, escaped range, and 49000-unit truncation | Core E2E writes a sheet name with quotes and Japanese and a long text cell | Enforcing server accepts RAW/range/length, while local CSV retains full text | `core` |
| `destinations` | Multiple destinations, durable retries, and CSV before network | Core E2E disables/restarts the loopback mock, recreates the queue, and returns 429 | CSV and pending jobs exist before HTTP, outage retains jobs, cooldown prevents requests, replay drains both destinations | `core` |
| `privacy` | Exclusions, secure input, lock, and idle | Run the privacy decision/validation test | Assertions cover exclusion and skip decisions. Real secure input, lock, idle, and own-window detection need desktop verification | `unit:privacyExclusionsAndValidation` |
| `credentials` | Keychain-only credentials, replace, and delete | Run isolated-service Keychain and sanitized-error regressions; use `menu-bar` for UI replacement | Test item is deleted and diagnostic strings omit credential values. Never inspect Keychain values | `unit:CoreTests` |
| `preferences` | Interval, thresholds, language, and saved preferences | App E2E sets `interval` to 7, presses `save-settings`, relaunches, then picks Japanese | Saved mode/interval/language assertions and English/Japanese screenshots | `app` |
| `localization` | Complete English/Japanese UI and documentation | Run the catalog completeness checker; use `preferences` for visible language switching | Every referenced UI key has both translations. README prose quality requires manual review | `localization` |
| `packaging` | Runnable signed app, LSUIElement, and permissions declarations | Build the debug app with the existing packaging script | `codesign --verify` and packaged bilingual OCR succeed. Inspect `dist/WYSIWAG.app/Contents/Info.plist` for declarations; launch is covered by `menu-bar` | `package` |
| `security-review` | Fresh security and concurrency review | Review the changed code after QA and record findings | An independent read-only review report is required; a command cannot certify a review | `manual` |
| `ci` | Reproducible CI | Run the same `scripts/verify.sh` entry point used by GitHub Actions | Local log covers build, unit tests, core E2E, packaging, and scans. Hosted macOS CI requires a remote run | `verify` |

## Check recipes

- `core` runs `scripts/core-e2e.sh`. This builds the actual Swift CLI, uses Vision OCR and real local CSV files, and starts HTTP mocks on an ephemeral loopback port. It never loads saved credentials.
- `unit:<filter>` runs `swift test --filter <filter>`. `CoreTests` is the existing serialized suite, including recovery, session, and structural checks. These are regression proofs, not UI proofs.
- `app` runs `CONFIGURATION=debug scripts/build-app.sh` then `scripts/app-e2e.sh`. This is a visible desktop test using `--evidence`, the `com.wysiwag.evidence` preferences/Keychain service, and the dedicated WYSIWAG-Evidence outbox. It needs write access there and Accessibility/Automation permissions.
- `package` runs `CONFIGURATION=debug scripts/build-app.sh` and its existing signature/resource checks.
- `localization` runs `python3 scripts/check-localization.py`.
- `verify` runs `scripts/verify.sh`. `all` uses this same baseline once. Neither runs visible UI or live cloud consent.
- `manual` returns exit 3 with the unmet requirement. It never reports a manual capability as passed.

## Navigation and observation

The app opens Settings paused. `scripts/app-e2e.py` drives `AXIdentifier` handles through System Events. The capture tab uses `mode-ALL`, `mode-AUTO`, `mode-SMART`, `interval`, `toggle-capture`, `capture-status`, and `save-settings`. Navigate with `section-Destinations`, `section-Privacy`, `section-General`, and `section-Capture`. Credentials use `replace-jevKey`, `credential-input`, `save-credential`, and `delete-jevKey`. General uses `language` with menu item `Japanese`. These are the existing sequence's handles; the CLI wraps that sequence rather than implementing another UI driver.

Read `run.json` with the CLI's `inspect` command. Inspect `check.log` for the command and assertions. For core runs, inspect `core-e2e.json`, `fixture-csv-head.csv`, and `ocr-dry-run.csv`. For app runs, inspect `app-e2e.json`, `app-e2e-attempt.json`, and PNGs under `screenshots/`. Screenshots show only WYSIWAG's window. Never capture unrelated windows or read personal CSV/outbox data.

## Isolation and remaining proof

Run one command at a time per checkout. Swift's build directory and `dist/WYSIWAG.app` are shared. App E2E also has a fixed test preferences domain, Keychain service, and outbox, so do not run it concurrently across worktrees. The driver refuses an already running WYSIWAG app. The local HTTP mocks use ephemeral ports, but Notion's real callback uses port 43871. Do not run authorization against an occupied callback port.

The app E2E capture toggles require a prepared synthetic desktop. If Screen Recording is allowed, they can record the active window into `/tmp/WYSIWAG-Evidence`. A successful synthetic core check proves neither live screen consent nor live provider consent. Preserve denial/failure reports and name these gaps in the task summary. Do not weaken a journey when a permission or fixture is missing.
