"""Selected-policy adapter. No failed password ever falls back to TOTP."""
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from app.core.errors import AppError
from app.modules.identity.operation_password import AdminWalletOperationPasswordService


class AdminWalletProofBody(BaseModel):
    model_config=ConfigDict(extra='forbid')
    mfa_proof: SecretStr | None=Field(default=None,min_length=6,max_length=6,repr=False)
    operation_password: SecretStr | None=Field(default=None,min_length=12,max_length=128,repr=False)


def operation_service(settings,factory,clock):
    return AdminWalletOperationPasswordService(factory,owner_id=lambda:settings.wallet_manual_owner_admin_id,
        auth_mode=lambda:getattr(settings,'wallet_admin_auth_mode','totp'),clock=clock)


def selected_password_authorization(settings,factory,clock,claims,body):
    mode=getattr(settings,'wallet_admin_auth_mode','totp')
    if mode=='totp':
        if body.operation_password is not None:
            raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',message='ADMIN_WALLET_AUTH_MODE_MISMATCH',status_code=403)
        if body.mfa_proof is None:
            raise AppError(code='TOTP_REQUIRED',message='TOTP_REQUIRED',status_code=403)
        return None
    if mode!='operation_password' or body.mfa_proof is not None or body.operation_password is None:
        raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',message='ADMIN_WALLET_AUTH_MODE_MISMATCH',status_code=403)
    service=operation_service(settings,factory,clock)
    proof=service.verify(claims=claims,operation_password=body.operation_password.get_secret_value())
    return service.authorization(claims=claims,proof=proof)
