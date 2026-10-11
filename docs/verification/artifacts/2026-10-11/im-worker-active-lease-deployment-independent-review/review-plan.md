# R9b-2 deployment independent review

Status: awaiting author freeze; no deployment verdict.

Review owner: /root/review_r1_r2. Author: /root/backend_review.
The owned review directory is separate from author source, root/current-state, and Android release preparation.

## Inputs to freeze

- Exact author commit and Git blob SHA-256 for every executable, fixture and manifest.
- Source candidate c3dd314212c73414c5ab371b4363e077bc9104c2: main, lease_renewal, worker and Consumer; installed and source Consumer must be identical.
- Worker base and rollback sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a.
- Existing new lease module state is ABSENT, distinguishable from read/exec failure.
- Live guard 46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b and probe 2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15.

## Ordered assessment

First SPEC/domain: bounded worker-only immutable overlay, five runtime destinations, actual default-image import path and main wiring; preserve business API, schema, secrets, financial idempotency, original handler thread and external at-least-once semantics. No source or test PYTHONPATH may disguise installed Consumer identity. Preparation does not imply publication authorization.

Then QUALITY/security: private staging and backups, exact old/new hashes and config identity, source/runtime parity, bounded subprocess/DB waits, unrelated-container protection, immutable rollback and confirmed absence of the new module. Candidate/rollback Compose must differ only in worker image. No guard/probe replacement or relaxation.

Independent local fault cases will use AST-selected executable bodies and inert I/O, never import a deployment module with top-level effects. Cover clean switch, settled postcondition failure, outer/inner timeout, unexpected wait/cleanup failure, ambiguous rollback, missing versus unreadable paths, wrong runtime hashes and rollback ABSENT. Any new real-image probe is root-authorized separate isolation evidence, not a production switch.

## Limits

No cloud/server writes or service switch by this reviewer. Android 2214 publication is still a prerequisite controlled by root. Source review cc1c372759d22c11e2e3f77e84d15ce3accba98e is complete but is not an image/deployment PASS. No author test count will be presented as an independent run.