import httpx
import pytest

from app.core.errors import AppError
from app.integrations import matrix_admin
from app.integrations.matrix_admin import SynapseMatrixAdminGateway


class Chunks(httpx.SyncByteStream):
    def __init__(self, chunks, advance):
        self.chunks, self.advance = chunks, advance
        self.closed = False

    def __iter__(self):
        for chunk in self.chunks:
            self.advance()
            yield chunk

    def close(self):
        self.closed = True


@pytest.mark.parametrize('kind', ['state', 'alias'])
def test_slow_chunk_stream_stops_at_deadline(kind, monkeypatch):
    now = [0.0]
    monkeypatch.setattr(matrix_admin, 'monotonic', lambda: now[0])
    def advance():
        now[0] += 3
    body = b'{"state":[]}' if kind == 'state' else b'{"room_id":"!room:test"}'
    stream = Chunks([body[:4], body[4:]], advance)
    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='test', admin_access_token='test',
        client=httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(200, stream=stream))))
    with gateway.metadata_deadline(5), pytest.raises(AppError):
        gateway.get_room_state_strict('!room:test') if kind == 'state' else gateway.resolve_room_alias('#alias:test')
    assert stream.closed


def test_stream_body_cap_refuses_oversized_metadata():
    stream = Chunks([b'{"state":[],"padding":"', b'x' * (2 * 1024 * 1024), b'"}'], lambda: None)
    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='test', admin_access_token='test',
        client=httpx.Client(transport=httpx.MockTransport(lambda request: httpx.Response(200, stream=stream))))
    with pytest.raises(AppError):
        gateway.get_room_state_strict('!room:test')
    assert stream.closed
