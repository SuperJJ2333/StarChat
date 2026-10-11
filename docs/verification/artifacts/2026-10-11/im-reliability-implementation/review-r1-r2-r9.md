# R9 log rotation: independent specification then quality/security review

Reviewer: review_r1_r2. Date: 2026-10-11 UTC+08. Scope is only approved R9/SR2 rotation for synapse, synapse-sync-worker and gateway. All other R9 subprojects remain outside this review.

## 1. Specification/domain

**PASS.** Read approved R9 plan and actual diff. Root Compose adds json-file logging with string options20m and10 to synapse and sync worker; production Compose adds the identical policy to gateway. The existing3-case test verifies each service explicitly. Reviewed RED:3 failures caused by missing driver; reviewed GREEN:3 passed.

Independent parsed-YAML comparison removes precisely those3 new logging blocks then proves each entire configuration equals baseline5c83a08a. Result `R9 EXACT_LOGGING_ONLY PASS`, exit0. There is no image, route, command, environment, volume, port, network or healthcheck change hidden in these Compose edits.

## 2. Quality/security

**PASS for this bounded configuration change.** Fresh independent test command `python -m pytest -q -p no:cacheprovider tests/infra/test_core_log_rotation.py`:3 passed in0.19s. Diff whitespace check exit0. Loader supports the production file's existing !override tag; no interpolation of runtime secrets is needed to inspect logging policy.

Read `r9-isolated-rotation.txt`: actual container inspection reports json-file/options20m/10;5800 synthetic lines created a20,003,668-byte rotated file and3,717,692-byte current file. This proves rotation under the configured policy, not a full10-file retention/deletion cycle. Evidence uses synthetic output; it does not contain original production logs.

The change retains normal logging, does not hide errors and does not truncate an existing production logfile. It bounds future logs after container recreation. Parent release procedure must archive old logs first in the server's protected0700 release directory, preserve each actual image/config baseline and inspect logging on each recreated container. Current repository configuration alone is not evidence that existing containers adopted the policy. No nginx routing or full production Compose replacement is authorized by this review.

Frozen SHA256 inputs at review:

- docker-compose.yml:212fe7cd92bff5d7fcf94c5c0eb5385ec32c77c0e437cafd92c3511e205ad392
- docker-compose.production.yml:b0a8855c1cbecce065a6c1f8a0f6d63eff68e2fefddc97f534bf5304ca0d249d
- tests/infra/test_core_log_rotation.py:f233b74ba19881b791e77192d57460730abe27a5205b8fb2d371d0c1a9e9f512

No blocking findings. No deployment performed by reviewer. R1 image/runtime review remains separate; co-applying these logging options does not expand R1's recovery trust scope.
