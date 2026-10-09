import httpx
from app.integrations.tron.reader import TronReader
from app.integrations.tron.observer import Observer
from test_observer import rows
from test_reader import ACCOUNT


def test_transport_failure_is_persisted_as_network_without_provider_details(tmp_path):
    def fail(request):
        raise httpx.ConnectError('private-provider-token', request=request)
    client = httpx.Client(transport=httpx.MockTransport(fail))
    reader = TronReader('https://example.test', client=client)
    path = tmp_path / 'observer.sqlite3'
    observer = Observer(path, address=ACCOUNT, reader=reader, start_ms=1000, now_ms=lambda:2000)
    result = observer.run_once()
    assert result['error_code'] == 'SOURCE_NETWORK_ERROR'
    assert rows(path, 'runs')[-1]['error_code'] == 'SOURCE_NETWORK_ERROR'
    assert 'private-provider-token' not in str(result)
