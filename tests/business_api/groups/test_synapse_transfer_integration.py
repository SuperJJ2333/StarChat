"""Real isolated Synapse tests. Optional environment absence is a skip; startup failure is not."""
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import time
import uuid
from copy import deepcopy
from datetime import datetime, timezone

import pytest

IMAGE = os.environ.get('SYNAPSE_TEST_IMAGE', 'starchat/synapse:v1.132.0-dedup.1')
ARTIFACT_ROOT = Path(__file__).resolve().parents[3] / 'docs/verification/artifacts/2026-09-22/review-flows-audit/synapse-runtime'


def _docker(args, check=True):
    result = subprocess.run(['docker', *args], capture_output=True, text=True, timeout=120)
    if check and result.returncode != 0:
        raise RuntimeError(f'Docker operation {args[0]} failed: {result.stderr.strip()[:400]}')
    return result


def _unavailable(message):
    if os.environ.get('SYNAPSE_TEST_REQUIRED') == '1':
        pytest.fail(message)
    pytest.skip(message)


def _free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def _register_user(synapse, localpart, password, admin):
    flags = ['-u', localpart, '-p', password, '-c', '/data/homeserver.yaml', 'http://localhost:8008']
    if admin:
        flags.insert(0, '-a')
    result = subprocess.run(['docker', 'exec', '-i', synapse['container'], 'register_new_matrix_user', *flags],
        capture_output=True, text=True, input=('no\n' if not admin else ''), timeout=30)
    if result.returncode != 0:
        raise RuntimeError('Isolated user registration failed')
    return {'user_id': f"@{localpart}:{synapse['server_name']}", 'password': password}


@pytest.fixture()
def synapse():
    if shutil.which('docker') is None:
        _unavailable('Docker CLI unavailable')
    if _docker(['version'], check=False).returncode != 0:
        _unavailable('Docker daemon unavailable')
    if _docker(['image', 'inspect', IMAGE], check=False).returncode != 0:
        _unavailable('Pinned local Synapse test image unavailable')
    port = _free_port()
    name = 'synapse-review-' + uuid.uuid4().hex[:8]
    server_name = name + '.local'
    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    data_dir = (ARTIFACT_ROOT / name).resolve()
    assert data_dir.is_relative_to(ARTIFACT_ROOT.resolve()) and data_dir != ARTIFACT_ROOT.resolve()
    data_dir.mkdir()
    try:
        _docker(['run', '--rm', '-v', f'{data_dir}:/data', '-e', f'SYNAPSE_SERVER_NAME={server_name}',
            '-e', 'SYNAPSE_REPORT_STATS=no', IMAGE, 'generate'])
        config = data_dir / 'homeserver.yaml'
        import re
        text, count = re.subn(r'^(registration_shared_secret\s*:).*$',
            'registration_shared_secret: "' + secrets.token_hex(24) + '"',
            config.read_text(encoding='utf-8'), flags=re.MULTILINE)
        assert count == 1, 'Generated registration config differs from the pinned image contract'
        config.write_bytes(text.encode('utf-8'))
        _docker(['run', '-d', '--name', name, '-v', f'{data_dir}:/data', '-p', f'127.0.0.1:{port}:8008', IMAGE])
        base_url = f'http://127.0.0.1:{port}'
        import httpx
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                if httpx.get(base_url + '/_matrix/client/versions', timeout=2).status_code == 200:
                    break
            except httpx.HTTPError:
                pass
            time.sleep(.25)
        else:
            pytest.fail('Configured isolated Synapse failed to become ready')
        yield {'base_url': base_url, 'server_name': server_name, 'container': name}
    finally:
        _docker(['rm', '-f', name], check=False)
        assert data_dir.is_relative_to(ARTIFACT_ROOT.resolve()) and data_dir != ARTIFACT_ROOT.resolve()
        shutil.rmtree(data_dir)


@pytest.fixture()
def transfer_case(synapse):
    import httpx

    from app.core.database import Base, create_session_factory
    import app.modules.identity.models  # noqa: F401  (users 先注册)
    import app.modules.groups.models  # noqa: F401
    import app.modules.audit.models  # noqa: F401
    from app.modules.groups.registry import GroupRegistryService
    from app.modules.groups.transfer_coordination import GroupTransferCoordinator
    from sqlalchemy import create_engine
    from sqlalchemy.pool import StaticPool

    base, server = synapse["base_url"], synapse["server_name"]
    suffix = uuid.uuid4().hex[:8]
    admin = _register_user(synapse, "itadmin" + suffix, secrets.token_hex(16), admin=True)
    owner = _register_user(synapse, "itowner" + suffix, secrets.token_hex(16), admin=False)
    new_owner = _register_user(synapse, "itnew" + suffix, secrets.token_hex(16), admin=False)
    owner_token = httpx.post(f"{base}/_matrix/client/v3/login", json={
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": owner["user_id"]},
        "password": owner["password"]}, timeout=10).json()["access_token"]
    new_token = httpx.post(f"{base}/_matrix/client/v3/login", json={
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": new_owner["user_id"]},
        "password": new_owner["password"]}, timeout=10).json()["access_token"]

    room = httpx.post(f"{base}/_matrix/client/v3/createRoom",
        headers={"Authorization": f"Bearer {owner_token}"},
        json={"preset": "private_chat", "name": "it-room"}, timeout=10).json()["room_id"]
    httpx.post(f"{base}/_matrix/client/v3/rooms/{room}/invite",
        headers={"Authorization": f"Bearer {owner_token}"},
        json={"user_id": new_owner["user_id"]}, timeout=10)
    httpx.post(f"{base}/_matrix/client/v3/rooms/{room}/join",
        headers={"Authorization": f"Bearer {new_token}"}, json={}, timeout=10)

    # 业务侧：真实网关 + 内存注册表库
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False},
        poolclass=__import__("sqlalchemy.pool", fromlist=["StaticPool"]).StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    from app.modules.identity.models import User as BizUser

    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for uid, mxid in (("owner", owner["user_id"]), ("newowner", new_owner["user_id"])):
            session.add(BizUser(id=uid, username=uid, username_normalized=uid,
                email=f"{uid}@x.test", email_normalized=f"{uid}@x.test", password_hash="x",
                status="ACTIVE", matrix_user_id=mxid, created_at=now, updated_at=now))
        session.flush()
        from app.modules.groups.models import BusinessGroup

        session.add(BusinessGroup(room_id=room, owner_user_id="owner", owner_since=now,
            tenure_source="creation", created_at=now, updated_at=now))
    from app.core.config import Settings

    settings = Settings(_env_file=None, environment="test", jwt_secret="x" * 32,
        matrix_homeserver_url=base, matrix_server_name=server)
    from app.integrations.matrix_admin import SynapseMatrixAdminGateway

    admin_token = httpx.post(f"{base}/_matrix/client/v3/login", json={
        "type": "m.login.password", "identifier": {"type": "m.id.user", "user": admin["user_id"]},
        "password": admin["password"]}, timeout=10).json()["access_token"]
    gateway_client = httpx.Client(timeout=10.0)
    gateway = SynapseMatrixAdminGateway(homeserver_url=base, server_name=server,
        admin_access_token=admin_token, client=gateway_client)
    registry = GroupRegistryService(factory, matrix_gateway=gateway)
    coordinator = GroupTransferCoordinator(factory, registry=registry, matrix_gateway=gateway)

    # Seed nondefault ACL fields so preserving an empty/default event cannot pass.
    before = deepcopy(next(e['content'] for e in gateway.get_room_state(room)
        if e.get('type') == 'm.room.power_levels'))
    before.update({'invite': 35, 'redact': 55, 'events_default': 3, 'notifications': {'room': 50}})
    before['events'] = {**before.get('events', {}), 'org.starchat.review': 42}
    response = httpx.put(f'{base}/_matrix/client/v3/rooms/{room}/state/m.room.power_levels',
        headers={'Authorization': f'Bearer {owner_token}'}, json=before, timeout=10)
    response.raise_for_status()
    try:
        yield dict(coordinator=coordinator, gateway=gateway, registry=registry, room=room,
            owner=owner, new_owner=new_owner, new_token=new_token, base=base, before=before)
    finally:
        gateway_client.close()
        engine.dispose()


def test_real_synapse_transfer_coordination(transfer_case):
    case = transfer_case
    coordinator, room = case['coordinator'], case['room']
    view = coordinator.request(room_id=room, requester_user_id='owner', current_owner_user_id='owner',
        new_owner_user_id='newowner', idempotency_key='normal-transfer')
    view = coordinator.advance(intent_id=view['id'])
    assert view['stage'] == 'MATRIX_APPLIED'
    assert coordinator.complete(intent_id=view['id'])['stage'] == 'COMPLETED'
    expected = deepcopy(case['before'])
    expected['users'][case['owner']['user_id']] = 0
    expected['users'][case['new_owner']['user_id']] = 100
    actual = next(e['content'] for e in case['gateway'].get_room_state(room)
        if e.get('type') == 'm.room.power_levels')
    assert actual == expected
    assert case['registry'].get(room).owner_user_id == 'newowner'
    from app.modules.groups.registry import GroupOwnerError
    with pytest.raises(GroupOwnerError) as error:
        coordinator.request(room_id=room, requester_user_id='owner', current_owner_user_id='owner',
            new_owner_user_id='newowner', idempotency_key='second-owner-transfer')
    assert error.value.code == 'GROUP_OWNER_MISMATCH'
    import httpx
    changed = deepcopy(actual)
    changed['users'][case['owner']['user_id']] = 100
    response = httpx.put(f"{case['base']}/_matrix/client/v3/rooms/{room}/state/m.room.power_levels",
        headers={'Authorization': f"Bearer {case['new_token']}"}, json=changed, timeout=10)
    response.raise_for_status()
    view_after = case['registry'].group_view(room)
    assert view_after['owner_user_id'] == 'newowner'
    assert view_after['owner_desync'] is True


def test_real_synapse_lost_response_review_does_not_resend(transfer_case):
    case = transfer_case
    coordinator, gateway = case['coordinator'], case['gateway']
    real_send = gateway.send_room_state_as_user
    writes = []
    def lost_response(*args, **kwargs):
        result = real_send(*args, **kwargs)
        writes.append(result)
        raise TimeoutError('Injected loss after real Matrix accepted the state event')
    gateway.send_room_state_as_user = lost_response
    view = coordinator.request(room_id=case['room'], requester_user_id='owner', current_owner_user_id='owner',
        new_owner_user_id='newowner', idempotency_key='lost-response-transfer')
    assert coordinator.advance(intent_id=view['id'])['stage'] == 'MATRIX_PENDING'
    assert coordinator.review_intent(intent_id=view['id'], action='confirm_applied', actor_id='owner')['stage'] == 'COMPLETED'
    assert coordinator.review_intent(intent_id=view['id'], action='confirm_applied', actor_id='owner')['stage'] == 'COMPLETED'
    assert case['registry'].get(case['room']).owner_user_id == 'newowner'
    assert len(writes) == 1
