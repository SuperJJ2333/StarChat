from decimal import Decimal
import pytest
from app.modules.ledger.reserve import caibi_requirement_usdt
from app.core.errors import AppError


def test_no_quote_cannot_be_assumed_one_to_one_for_backing():
    with pytest.raises(AppError) as error:
        caibi_requirement_usdt(Decimal('100'), None)
    assert error.value.code == 'RESERVE_VALUATION_UNAVAILABLE'
    assert caibi_requirement_usdt(Decimal('0'), None) == 0


def test_fresh_rate_below_one_must_not_understate_obligation():
    assert caibi_requirement_usdt(Decimal('100'), Decimal('0.5')) == Decimal('200.000000')


@pytest.mark.parametrize('rate', ['0', '-1', 'NaN', 'Infinity'])
def test_invalid_rate_must_not_relax_reserve_gate(rate):
    with pytest.raises(ValueError):
        caibi_requirement_usdt(Decimal('100'), Decimal(rate))
