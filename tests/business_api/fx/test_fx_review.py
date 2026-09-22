import pytest

from test_fx_rate_service import db, FakeClock, FakeUpstream, make_service
from app.core.errors import AppError


def test_cold_failure_is_cached_for_one_hour(db):
    clock = FakeClock()
    upstream = FakeUpstream(exc=TimeoutError('offline'))
    for _ in range(3):
        with pytest.raises(AppError):
            make_service(db, upstream, clock).get_rate_snapshot(actor_id='u')
    assert len(upstream.calls) == 1
    clock.advance(hours=1)
    with pytest.raises(AppError):
        make_service(db, upstream, clock).get_rate_snapshot(actor_id='u')
    assert len(upstream.calls) == 2


def test_claim_rechecks_quote_completed_after_initial_read(db):
    clock, upstream = FakeClock(), FakeUpstream()
    slow = make_service(db, upstream, clock)
    original = slow._claim
    def claim(now):
        make_service(db, upstream, clock).get_rate_snapshot(actor_id='winner')
        return original(now)
    slow._claim = claim
    slow.get_rate_snapshot(actor_id='loser')
    assert len(upstream.calls) == 1


def test_rate_rounding_to_zero_is_rejected(db):
    upstream = FakeUpstream(payload={'code': 200, 'rate': '0.00000001'})
    with pytest.raises(AppError):
        make_service(db, upstream, FakeClock()).get_rate_snapshot(actor_id='u')


def test_mask_handles_secret_as_first_query_parameter():
    from app.modules.fx.service import masked_url
    assert 'secret' not in masked_url('https://example.test/?key=secret&id=unit')


def test_http_transport_log_does_not_expose_provider_credentials(monkeypatch, caplog):
    import httpx
    from app.modules.fx.service import _default_http_get
    original = httpx.Client
    transport = httpx.MockTransport(lambda request: httpx.Response(200, json={'code': 200, 'rate': '7.12'}))
    monkeypatch.setattr(httpx, 'Client', lambda **kwargs: original(transport=transport, **kwargs))
    with caplog.at_level('INFO', logger='httpx'):
        _default_http_get('https://cn.apihz.cn/api/jinrong/huilv.php?from=USD&id=unit-id&key=unit-key', 6)
    assert 'unit-id' not in caplog.text and 'unit-key' not in caplog.text


@pytest.mark.parametrize('payload', [
    {'code': 200, 'rate': '0', 'result': '71.2'},
    {'code': 200, 'rate': 'NaN', 'result': '71.2'},
    {'code': 200, 'result': '1e999999999'},
    {'code': 200, 'result': '71.2', 'money': '1'},
])
def test_malformed_payload_enters_shared_failure_backoff(db, payload):
    upstream, clock = FakeUpstream(payload=payload), FakeClock()
    service = make_service(db, upstream, clock)
    for _ in range(2):
        with pytest.raises(AppError) as error:
            service.get_rate_snapshot(actor_id='u')
        assert error.value.code == 'FX_UNAVAILABLE'
    assert len(upstream.calls) == 1
