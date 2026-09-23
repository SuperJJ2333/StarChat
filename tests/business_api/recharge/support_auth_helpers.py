"""Real management-session/proof fixtures for legacy recharge HTTP tests."""
from datetime import datetime, timezone
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender
from app.modules.identity.staff_activation import StaffActivationService
from app.modules.identity.operation_password import AdminWalletOperationPasswordService
from app.modules.identity.wallet_grant import WalletAccessGrantService


def staff_token(factory, settings, tokens, user_id='agent'):
    clock = lambda: datetime.now(timezone.utc)
    password = 'fixture-login-password-123'
    with factory.begin() as session:
        user = session.get(User, user_id)
        user.password_hash = PasswordHasher().hash(password)
        user.email_verified_at = clock()
    sms = RecordingSmsSender()
    otp = PhoneOtpService(factory, sender=sms, secret='fixture-otp-secret')
    service = StaffActivationService(factory, phone_otp=otp, email_code_deriver=lambda _: '728415')
    challenge = service.request(username=user_id, password=password)
    service.confirm(activation_id=challenge['activation_id'], code='728415')
    pair = tokens.issue_admin_pair(user_id=user_id, display_name='support browser')
    # The historical HTTP fixtures do not construct a live chain runtime.
    # Proof policy is nevertheless real and is checked by the route/service.
    settings.wallet_real_mode = 'manual_tron'
    settings.wallet_admin_auth_mode = 'operation_password'
    settings.wallet_access_grant_enabled = True
    settings.wallet_manual_owner_admin_id = 'root'
    claims = tokens.decode_access_token(pair.access_token)
    operations = AdminWalletOperationPasswordService(factory, owner_id=lambda:'root',
        auth_mode=lambda:'operation_password', clock=clock, scope='support-orders')
    operations.set_password(claims=claims, login_password=password,
        new_operation_password='fixture-separate-operation-password', idempotency_key='operation-setup')
    WalletAccessGrantService(settings, factory, clock, scope='support-orders').verify(
        claims=claims, operation_password='fixture-separate-operation-password')
    return pair.access_token
