# Independent worker entry composition review

2026-10-11, root. Candidate `7407f374a58c666dcb8a291ab49dd7e491fb1096`, integrated as `bd3ab547`.

Specification/domain: PASS. The probe imports the installed Consumer and actual Worker, checks both file origins and the aliases exported by main, and constructs exactly those two classes together with no session factory or handlers. The existing constructor rejects the previously failed new-Worker/old-Consumer combination. An older valid pair remains accepted by its own constructor; the probe does not impose new methods on old rollback images. Both exact check lists add the same ninth worker proof; the previous eight worker and nine API checks are retained.

Quality/security: PASS. No worker execution, claim, external provider, financial handler, service configuration, schema, or authentication policy is changed. The success test traps run_once/run_forever/claim_batch and checks the absent session factory. Origin/alias tampering and missing proof checks fail closed. Root inspected the immutable-image matrix and actual argv: network none, read-only, constrained temporary resources and only candidate-script mounts. Default-entry probes do not set PYTHONPATH. The failed candidate's exact constructor TypeError is separately identified, not inferred from an arbitrary nonzero exit.

Evidence reused on unchanged inputs: implementer test-first 7 failures, then 40 focused PASS; full infra 915 PASS / 20 explicit isolated-PostgreSQL skips. Three valid image-role checks pass (live worker, rollback worker, API); the known incompatible worker is rejected. Root independently inspected code, constructor behavior, tests, report and precise image receipts; no duplicate source-suite execution was needed. This review does not assert active lease renewal, exactly-once external effects, or full repository verify success.

Reviewed script bytes: probe `2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15`; guard `46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b`. Permanent installation requires separate old-byte comparison, private backup, paired replacement and post-install checks; not performed by this review.
