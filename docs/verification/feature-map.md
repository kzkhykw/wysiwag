# WYSIWAG verification map

This map follows BRIEF.md Amendment 1. Commands are acceptance checks, not claims of completion; results and artifacts are recorded in the evidence report and QA log.

| User-facing feature | Automated verification | Real app / evidence |
| --- | --- | --- |
| Menu bar status, pause/resume, Settings | App accessibility E2E | English/Japanese window screenshots |
| ScreenCaptureKit active window capture | `capture --once --dry-run --live` | 30 seconds ALL and AUTO with a fixture window, or explicit TCC denial |
| English + Japanese on-device OCR / reading order | `capture --once --dry-run`; CLI fixture sequence | Bundled synthetic images only |
| ALL writes every sample | `verify` asserts six CSV rows | UI mode selection |
| AUTO default; app/title/text threshold, no network | `verify` asserts four rows and zero Jev calls; unit threshold tests | UI selection and persistence |
| SMART Jev on every capture, including first | `verify` local HTTP server counts six requests | Disabled without key; set fake key, select, clear |
| SMART failure status + changed fallback + backoff | HTTP error unit tests; 429/529 CLI probes | Status menu and missing-key sweep |
| CSV header, RFC 4180, newline, local offset, day, dwell | Unit tests + real CLI CSV parsed independently | Folder picker, open folder |
| Notion OAuth, state, Keychain and granted database picker | Mock token/search unit tests; OAuth callback tests | Setup UI; live auth requires user's public integration |
| Notion data-source parent/schema and select/rich_text | Mock API writer tests + local HTTP E2E | Database chooser |
| Notion 2000 units / 100 children / byte cap / continuation | Long bilingual payload against enforcing mock server | Long-text QA |
| Google OAuth PKCE, loopback, state, refresh | Unit tests + loopback integration test | Setup UI; live auth requires user's desktop client |
| Sheets RAW, escaped range and 49,000-unit truncation | Local HTTP E2E + unit tests | Spreadsheet/sheet settings |
| Multiple destinations, durable retries, CSV before network | CLI outage/recovery across queue instances, 429 cooldown | Queue status and retry controls |
| Exclusions / secure input / lock / idle | Privacy decision unit tests | Privacy settings; own windows excluded |
| Keychain-only credentials / replace / delete | Isolated-service round trip + no-secrets scan + sanitized errors | Accessibility E2E, verify state without printing values |
| Interval, thresholds, language and saved preferences | Validation tests + catalog completeness check | Relaunch persistence E2E |
| Complete en/ja UI and documentation | String Catalog checks | Screenshots of both languages, Japanese QA |
| Runnable ad-hoc signed app, LSUIElement and permissions | `scripts/build-app.sh`; `codesign --verify` | Launch built app |
| Fresh read-only security/concurrency review | Independent review after QA; fix and repeat full suite | Review report |
| Reproducible CI | GitHub Actions macOS: build, unit, core E2E, secret scan | Draft PR checks |

Entry points: `swift test`, `scripts/core-e2e.sh`, `scripts/app-e2e.sh`, `scripts/check-no-secrets.sh`, `scripts/verify.sh`. Core E2E uses loopback mocks only, never saved credentials. App E2E uses a dedicated preferences domain and Keychain test service. Never publish personal screen contents.
