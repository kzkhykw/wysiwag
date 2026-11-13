# QA log

Only synthetic fixture content is used in committed evidence. A pass is complete only after the full verification suite is rerun.

| Pass | Finding | Fix / regression protection | Status |
| --- | --- | --- | --- |
| Core driver 1 | Vision omitted the Japanese line despite en/ja being listed | Enable automatic language detection; CLI E2E requires both English and Japanese output | Fixed; full core E2E and unit rerun passed |
| Build 1 | Swift 6 rejected capturing non-Sendable SCWindow in sorting closure | Extract its CGRect before sorting displays | Fixed; build passed |
| Build 1 | OAuth listener initializer captured self before initialization | Bind a local descriptor before initializing the object | Fixed; build passed |

Amendment 1 replaces the original heuristic SMART path with default AUTO and Jev-only SMART. Earlier tests are updated to assert the new contract, including the absence of a SMART pre-filter.
