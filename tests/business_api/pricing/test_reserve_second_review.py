from types import SimpleNamespace

import pytest
from sqlalchemy.exc import OperationalError

from app.core.errors import AppError
from app.modules.ledger.reserve import fresh_usd_cny_rate


def test_database_failure_is_not_disguised_as_missing_quote():
    def fail(*args):
        raise OperationalError('SELECT', {}, Exception('offline database'))
    with pytest.raises(AppError) as exc:
        fresh_usd_cny_rate(SimpleNamespace(get=fail))
    assert exc.value.code == 'RESERVE_VALUATION_UNAVAILABLE'


def test_programming_error_is_not_swallowed_as_missing_quote():
    def fail(*args):
        raise RuntimeError('regression')
    with pytest.raises(RuntimeError, match='regression'):
        fresh_usd_cny_rate(SimpleNamespace(get=fail))
