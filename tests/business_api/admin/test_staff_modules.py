from datetime import datetime, timezone, timedelta

import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from test_admin_api import admin_app  # noqa: F401
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole
from app.modules.identity.rbac import ROLE_PERMISSIONS, Permission
from app.modules.admin.models import AdminBan
from app.modules.admin.service import AdminControlService
from app.modules.audit.models import AuditEvent
from app.core.outbox import OutboxEvent
from app.modules.identity.staff_activation import StaffActivation, staff_identity
from app.core.errors import AppError


@pytest.mark.asyncio
async def test_activated_staff_five_modules_and_negative_boundaries(admin_app):
    app, _, token = admin_app
    headers = {'Authorization': f'Bearer {token}'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        for path in ['modules/security', 'modules/analytics', 'modules/ads', 'modules/notice', 'ledger-entries', 'point-issuance', 'security/bans']:
            response = await client.get('/api/v1/admin/' + path, headers=headers)
            assert response.status_code == 200, (path, response.text)
        for path in ['support-agents', 'modules/wallet', 'app-update-settings']:
            response = await client.get('/api/v1/admin/' + path, headers=headers)
            assert response.status_code == 403, (path, response.text)


@pytest.mark.asyncio
async def test_staff_cannot_ban_management_account(admin_app):
    app, _, token = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.post('/api/v1/admin/security/bans', json={'target_type': 'user', 'target': 'admin-1', 'reason_code': 'SECURITY_RISK'}, headers={'Authorization': f'Bearer {token}', 'Idempotency-Key': 'protected-user'})
    assert response.status_code == 403
    assert response.json()['error']['code'] == 'BAN_TARGET_PROTECTED'


def test_staff_permissions_do_not_include_financial_or_system_shortcuts():
    permissions = ROLE_PERMISSIONS[RoleCode.SUPPORT_AGENT]
    assert Permission.LEDGER_VIEW in permissions
    assert Permission.SYSTEM_ADMIN not in permissions
    assert Permission.FINANCE_REVIEW not in permissions
    assert Permission.AUDIT_VIEW not in permissions


def test_unban_rejects_old_round_after_reban(admin_app):
    app, _, _ = admin_app
    factory = app.state.session_factory
    now = datetime.now(timezone.utc)
    service = AdminControlService(factory, now_factory=lambda: now)
    first = service.ban(actor_id='admin-1', target_type='ip', target='192.0.2.15', reason_code='SPAM', duration_minutes=60, idempotency_key='first-round', trace_id='test')
    with factory() as session:
        stamp = session.get(AdminBan, first['id']).starts_at.replace(tzinfo=timezone.utc).isoformat()
    service._now = lambda: now + timedelta(seconds=1)
    service.ban(actor_id='admin-1', target_type='ip', target='192.0.2.15', reason_code='SPAM', duration_minutes=60, idempotency_key='second-round', trace_id='test')
    with pytest.raises(AppError) as error:
        service.unban(actor_id='admin-1', ban_id=first['id'], expected_starts_at=stamp, reason_code='BAN_REVOKE', idempotency_key='stale-unban', trace_id='test')
    assert error.value.code == 'BAN_STATE_CHANGED'
    with factory() as session:
        assert session.get(AdminBan, first['id']).revoked_at is None


@pytest.mark.asyncio
async def test_staff_ban_unban_and_operational_writes_preserve_audit(admin_app):
    app, _, token = admin_app
    headers = {'Authorization': f'Bearer {token}', 'Idempotency-Key': 'staff-user-ban'}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        banned = await client.post('/api/v1/admin/security/bans', json={'target_type':'user','target':'u1','reason_code':'SPAM'}, headers=headers)
        assert banned.status_code == 201, banned.text
        page = await client.get('/api/v1/admin/security/bans',headers=headers)
        record = page.json()['items'][0]
        response = await client.post(f"/api/v1/admin/security/bans/{record['id']}/revoke",json={'reason_code':'BAN_REVOKE','expected_starts_at':record['starts_at']},headers={**headers,'Idempotency-Key':'staff-user-unban'})
        assert response.status_code == 200,response.text
        for path,body in [('notices',{'title':'测试公告','content':'测试正文','audience':'ALL'}),('ads',{'advertiser_name':'测试广告','text':'测试文案','link_url':'https://example.com'})]:
            response = await client.post('/api/v1/admin/'+path,json=body,headers={**headers,'Idempotency-Key':path})
            assert response.status_code == 201,(path,response.text)
    with app.state.session_factory() as session:
        actions = set(session.scalars(select(AuditEvent.action).where(AuditEvent.actor_id == 'finance-1')))
        assert {'admin.ban.created','admin.ban.revoked','admin.notice.created','admin.ad.created'} <= actions
        assert {'admin.ban.created','admin.ban.revoked','notice.publish.requested','native_ad.created'} <= set(session.scalars(select(OutboxEvent.event_type)))


@pytest.mark.asyncio
async def test_staff_cannot_replay_admin_receipt_and_revocation_is_live(admin_app):
    app, admin, token = admin_app
    payload = {'target_type':'ip','target':'192.0.2.30','reason_code':'SPAM'}
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as client:
        for credential in [admin,token]:
            response = await client.post('/api/v1/admin/security/bans',json=payload,headers={'Authorization':f'Bearer {credential}','Idempotency-Key':'shared-string'})
            assert response.status_code == 201,response.text
        with app.state.session_factory.begin() as session:
            role = session.scalar(select(UserRole).where(UserRole.user_id == 'finance-1'))
            session.delete(role)
        response = await client.post('/api/v1/admin/security/bans',json=payload,headers={'Authorization':f'Bearer {token}','Idempotency-Key':'shared-string'})
        assert response.status_code == 403,response.text
    with app.state.session_factory() as session:
        assert len(list(session.scalars(select(AuditEvent).where(AuditEvent.action == 'admin.ban.created')))) == 2


@pytest.mark.asyncio
async def test_single_role_removal_preserves_remaining_staff_session(admin_app):
    app, admin, token = admin_app
    factory = app.state.session_factory
    with factory.begin() as session:
        session.add(UserRole(id='additional-staff-role',user_id='finance-1',role_code=RoleCode.SUPPORT_AGENT,assigned_by='admin-1',assigned_at=datetime.now(timezone.utc)))
        session.flush()
        from app.modules.identity.models import User
        _, _, digest = staff_identity(session,session.get(User,'finance-1'))
        session.get(StaffActivation,'finance-1').identity_digest = digest
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as client:
        result = await client.delete('/api/v1/admin/support-roles/finance-1/FINANCE_SUPPORT',headers={'Authorization':f'Bearer {admin}','Idempotency-Key':'remove-one-role'})
        assert result.status_code == 200,result.text
        headers = {'Authorization':f'Bearer {token}'}
        assert (await client.get('/api/v1/admin/ledger-entries',headers=headers)).status_code == 200
        assert (await client.get('/api/v1/admin/modules/finance',headers=headers)).status_code == 403
        result = await client.delete('/api/v1/admin/support-roles/finance-1/SUPPORT_AGENT',headers={'Authorization':f'Bearer {admin}','Idempotency-Key':'remove-last-role'})
        assert result.status_code == 200,result.text
        assert (await client.get('/api/v1/admin/ledger-entries',headers=headers)).status_code == 403


@pytest.mark.asyncio
async def test_online_pagination_counts_users_before_devices(admin_app):
    from app.modules.identity.models import Device
    app, admin, _ = admin_app
    now = datetime.now(timezone.utc)+timedelta(seconds=5)
    with app.state.session_factory.begin() as session:
        for index in range(12):
            session.add(Device(id=f'multiple-device-{index}',user_id='u1',device_key=f'multiple-{index}',display_name='fixture',last_seen_at=now,created_at=now))
    async with AsyncClient(transport=ASGITransport(app=app),base_url='http://test') as client:
        headers={'Authorization':f'Bearer {admin}'}
        first=await client.get('/api/v1/admin/modules/online?limit=1',headers=headers)
        second=await client.get('/api/v1/admin/modules/online?limit=1&offset=1',headers=headers)
    assert first.json()['has_more'] is True
    assert first.json()['items'][0]['id'] != second.json()['items'][0]['id']
