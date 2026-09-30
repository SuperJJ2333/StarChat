"""The installed Worker must apply support recovery gates during auto reconciliation."""
import importlib.util
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool


def load_probe():
    path=Path(__file__).resolve().parents[2]/'docs/verification/artifacts/2026-09-30/support-worker-compatibility/worker_probe.py'
    spec=importlib.util.spec_from_file_location('support_worker_probe',path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_disabled_funds_worker_obeys_attribution_unique_and_empty_receipt_gates():
    probe=load_probe()
    from app.core.database import Base,create_session_factory
    engine=create_engine('sqlite://',poolclass=StaticPool)
    try:
        probe.register_models()
        Base.metadata.create_all(engine)
        result=probe.run_cases(create_session_factory(engine))
        assert result['cases']=={
            'ambiguous_cross_user_receipt':'PASS',
            'unique_receipt':'PASS',
            'empty_candidate':'PASS',
            'funding_disabled':'PASS',
        }
    finally:
        engine.dispose()
