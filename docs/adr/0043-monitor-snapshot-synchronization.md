# Bounded monitor discovery synchronization

Status: accepted within the user-authorized synchronization repair; domain/specification and quality/security review completed with no blocking findings before production.

Keep every existing wallet transition and acceptance criterion. A scan checkpoint moving independently of the observer causes healthy no-new-event cuts to wait unnecessarily. Existing discovery-only scanning is the authority for advancing that checkpoint; never copy watermarks directly or loosen equality. Use existing public FundingScanService with funds disabled and coverage enabled. A valid stale snapshot is resampled once after 200ms before incident creation; new healthy evidence must pass the full original checks, and persistent unhealthy evidence still blocks. Total transient synchronization attempts are bounded at three. No receipt ingestion, credit, payout, implicit closure or implicit fund recovery is introduced. P0 alert delivery remains enabled.
