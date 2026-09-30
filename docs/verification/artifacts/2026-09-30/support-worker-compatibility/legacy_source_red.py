"""Local-only reproduction using an exact extracted pre-recovery service file."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
import worker_probe


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('legacy_source')
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('legacy_payout_probe',Path(args.legacy_source))
    legacy=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=legacy
    spec.loader.exec_module(legacy)
    worker_probe.register_models()
    from app.core.database import Base,create_session_factory
    engine=create_engine('sqlite://',poolclass=StaticPool)
    try:
        Base.metadata.create_all(engine)
        try:
            worker_probe.run_cases(create_session_factory(engine),payout_class=legacy.ManualPayoutService)
        except AssertionError as error:
            print(json.dumps({'status':'EXPECTED_RED','reason':str(error)}))
            return 1
        raise AssertionError('legacy Worker unexpectedly passed recovery gates')
    finally:
        engine.dispose()


if __name__=='__main__':
    sys.exit(main())
