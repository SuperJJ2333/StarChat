"""PostgreSQL gates for manual cases that allocate an otherwise unmatched receipt."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import uuid4
import os

import pytest
from sqlalchemy import create_engine, func, select, text

import test_deposit_receipts as fixtures


@pytest.fixture
def core(monkeypatch):
    from app.modules.wallet import manual_deposit_cases  # noqa: F401

    url = os.environ.get('REPORTING_PG_URL')
    if not url:
        pytest.skip('REPORTING_PG_URL required for isolated PostgreSQL integration')
    schema = 'manual_case_' + uuid4().hex
    admin = create_engine(url)
    with admin.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA {schema}'))
    engine = create_engine(url, connect_args={'options': f'-csearch_path={schema}'}, pool_size=5)
    monkeypatch.setattr(fixtures, 'create_engine', lambda *args, **kwargs: engine)
    try:
        yield from fixtures.core.__wrapped__()
    finally:
        engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        admin.dispose()


def test_concurrent_approved_cases_credit_one_receipt_once(core):
    """Receipt/command uniques serialize distinct approved cases for one event."""
    from app.core.errors import AppError
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import AccountStatus, User, UserRole
    from app.modules.wallet.manual_deposit_cases import ManualDepositCaseService
    from app.modules.wallet.models import WalletControl, WalletLedgerTransaction
    from app.modules.wallet.repair_models import RepairCommand, RepairPreview

    RepairPreview.__table__.create(core[1].kw['bind'], checkfirst=True)
    RepairCommand.__table__.create(core[1].kw['bind'], checkfirst=True)
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = False
        session.add(User(id='owner', username='owner', username_normalized='owner',
            email='owner@example.test', email_normalized='owner@example.test', password_hash='fixture',
            status=AccountStatus.ACTIVE, created_at=core[5], updated_at=core[5]))
        session.add(UserRole(id='owner-role', user_id='owner', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='fixture', assigned_at=core[5]))

    receipt = fixtures.ingest(core)[0]
    service = ManualDepositCaseService(core[1], receipts=core[0], owner_admin_id='owner',
        clock_trusted=lambda: True)
    cases = [service.create(actor_id='owner', receipt_id=receipt['id'], user_id='alice',
        reason_detail='链上收款已固化，正常订单窗口外，核对历史绑定归属', ownership_attestation=True,
        idempotency_key=f'case-{index}', authorize=lambda session: lambda: None) for index in (1, 2)]
    for index, case in enumerate(cases, start=1):
        service.decide(actor_id='owner', case_id=case['case_id'], decision='APPROVED',
            reason_detail='负责人确认收据与历史绑定归属一致', confirmed=True,
            idempotency_key=f'decision-{index}', authorize=lambda session: lambda: None)
    previews = [service.preview(actor_id='owner', case_id=case['case_id'],
        authorize=lambda session: lambda: None) for case in cases]

    barrier = Barrier(2)
    original = core[2].transaction_evidence

    def evidence(txid):
        value = original(txid)
        barrier.wait(timeout=10)
        return value

    core[2].transaction_evidence = evidence

    def execute(index):
        preview = previews[index]
        try:
            return service.execute(actor_id='owner', case_id=cases[index]['case_id'],
                preview_id=preview['preview_id'], digest=preview['digest'], expected_version=1,
                operation_id=f'manual-case-operation-{index}', idempotency_key=f'execute-{index}',
                authorize=lambda session: lambda: None)
        except AppError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(execute, [0, 1]))

    assert sum(isinstance(result, dict) for result in results) == 1
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 1
        assert session.scalar(select(func.count()).select_from(RepairCommand)) == 1

