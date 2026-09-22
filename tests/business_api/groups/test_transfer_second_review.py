"""Independent regressions for transfer authorization and ambiguous effects."""
import pytest

from app.core.errors import AppError
from app.modules.groups.registry import GroupOwnerError
from .test_group_transfer_coordination import env


def request(env, key='review', target='newowner'):
    return env[1].request(room_id='!room:x', requester_user_id='owner',
        current_owner_user_id='owner', new_owner_user_id=target, idempotency_key=key)


def test_transfer_preserves_all_power_level_fields(env):
    gateway = env[2]
    fields = {'events_default': 50, 'state_default': 100, 'invite': 50,
        'ban': 75, 'kick': 60, 'redact': 50, 'users_default': 0,
        'events': {'m.room.encryption': 100}, 'notifications': {'room': 70}}
    gateway.get_room_state = lambda room: [{'type': 'm.room.power_levels',
        'content': {**fields, 'users': dict(gateway.power_users)}}]
    intent = request(env)
    env[1].advance(intent_id=intent['id'])
    sent = gateway.send_calls[-1]['content']
    assert {k: sent.get(k) for k in fields} == fields


def test_unjoined_target_cannot_create_transfer(env):
    env[2].members.remove('@newowner:x')
    with pytest.raises((AppError, GroupOwnerError)):
        request(env)


def test_requester_must_be_actual_current_owner(env):
    with pytest.raises((AppError, GroupOwnerError)):
        env[1].request(room_id='!room:x', requester_user_id='m1',
            current_owner_user_id='owner', new_owner_user_id='newowner', idempotency_key='impersonate')


def test_one_unresolved_operation_per_room(env):
    request(env)
    with pytest.raises((AppError, GroupOwnerError)):
        request(env, key='second', target='m1')


def test_domain_drift_before_send_never_sends(env):
    intent = request(env)
    env[2].power_users = {'@m1:x': 100, '@owner:x': 0}
    view = env[1].advance(intent_id=intent['id'])
    assert not env[2].send_calls
    assert view['stage'] == 'NEEDS_REVIEW'


def test_completion_rechecks_authority(env):
    intent = request(env)
    env[1].advance(intent_id=intent['id'])
    env[2].power_users = {'@m1:x': 100, '@newowner:x': 0, '@owner:x': 0}
    result = env[1].complete(intent_id=intent['id'])
    assert result['stage'] == 'NEEDS_REVIEW'
    assert env[3].get('!room:x').owner_user_id == 'owner'


def test_lost_send_response_recovers_without_reapplying(env):
    gateway = env[2]
    def accepted_then_timeout(users, content):
        gateway.power_users = dict(content['users'])
        gateway.send_behavior = None
        raise TimeoutError('accepted; response lost')
    gateway.send_behavior = accepted_then_timeout
    intent = request(env)
    env[1].advance(intent_id=intent['id'])
    env[4].advance(seconds=180)
    env[1].recover_batch()
    assert len(gateway.send_calls) == 1
    assert env[3].get('!room:x').owner_user_id == 'newowner'


def test_disabled_recovery_task_does_no_work(env):
    from tasks.group_transfer_recovery import GroupTransferRecoveryTask
    request(env)
    task = GroupTransferRecoveryTask(env[0], matrix_gateway=env[2], enabled=False)
    assert task.run_batch()['scanned'] == 0
    assert not env[2].send_calls
