"""Discovery-only synchronization; no receipt ingestion or finality calls."""
from app.modules.wallet.funding_scan import FundingScanService
from app.modules.wallet.funding_coverage import FundingCoverageService


def discovery_sync(factory, *, source, official_config, baseline_time, baseline_height, clock):
    # These adapters are intentionally absent: funds_enabled=False returns
    # immediately after discovery. Coverage facts must still be registered.
    coverage = FundingCoverageService(factory, finality_adapter=None,
        official_config=official_config, clock=clock)
    scanner = FundingScanService(factory, source=source, receipts=None,
        activation_baseline_time=baseline_time, activation_baseline_height=baseline_height,
        clock=clock, coverage=coverage, defer_credit=True)
    return lambda: scanner.run_once(funds_enabled=False)
