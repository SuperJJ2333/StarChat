import importlib.util
from pathlib import Path

def test_v2_baseline_is_separate_and_preserves_published_mail_outside_overlay():
    path=Path(__file__).parents[1]/'support-finance-order-release-v2'/'release_prep.py'
    spec=importlib.util.spec_from_file_location('release_prep_v2',path);v2=importlib.util.module_from_spec(spec);spec.loader.exec_module(v2)
    assert v2.RELEASE_ID=='support-finance-order-recovery-20260930-v2'
    assert v2.BASE_WORKER=='sha256:00c0e10972c97f18d5aae435032da642ad2a7752265dd66cfe4712ec3268c5b7'
    assert v2.BASE_API=='sha256:902eaefcb237924caf9b60145f728f9e2b4ec67fc2b659bd98ad7ea82edd101f'
    assert v2.BASE_SCHEMA=='0093_unbroadcast_payout_void'
    assert len(v2.worker_destinations())==14
    assert not any('staff_activation.py' in source for source,dest in v2.worker_destinations())
    original=Path(__file__).with_name('release_prep.py').read_text()
    assert "RELEASE_ID='support-finance-order-recovery-20260930-v1'" in original
    assert '90d7fb7472c82b78b9a9a56ef114620dd0aa0bd4a989e3011e3aa4ed24537282' in original
