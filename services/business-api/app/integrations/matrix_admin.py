from base64 import urlsafe_b64encode
from hashlib import sha256
import hmac
from typing import Protocol
from urllib.parse import quote

import httpx

from app.core.errors import AppError


class MatrixAdminGateway(Protocol):
    def ensure_user(self, localpart: str, password: str) -> str: ...


class MatrixCredentialCodec:
    def __init__(self, secret: bytes) -> None:
        if len(secret) < 16:
            raise ValueError("matrix provisioning secret must be at least 16 bytes")
        self._secret = secret

    def password_for(self, user_id: str) -> str:
        digest = hmac.new(self._secret, user_id.encode("utf-8"), sha256).digest()
        return urlsafe_b64encode(digest).decode("ascii").rstrip("=")


class SynapseMatrixAdminGateway:
    def __init__(
        self,
        *,
        homeserver_url: str,
        server_name: str,
        admin_access_token: str,
        client: httpx.Client | None = None,
    ) -> None:
        self._homeserver_url = homeserver_url.rstrip("/")
        self._server_name = server_name
        self._admin_access_token = admin_access_token
        self._client = client or httpx.Client(timeout=10.0)

    def ensure_user(self, localpart: str, password: str) -> str:
        matrix_user_id = f"@{localpart}:{self._server_name}"
        path_user_id = quote(matrix_user_id, safe="")
        response = self._client.put(
            f"{self._homeserver_url}/_synapse/admin/v2/users/{path_user_id}",
            headers={"Authorization": f"Bearer {self._admin_access_token}"},
            json={
                "password": password,
                "admin": False,
                "deactivated": False,
                "displayname": localpart,
            },
        )
        if response.status_code not in (200, 201):
            raise AppError(
                code="MATRIX_PROVISION_FAILED",
                message="Matrix 账号创建暂时失败",
                status_code=502,
            )
        body = response.json()
        returned_name = body.get("name", matrix_user_id)
        if returned_name != matrix_user_id:
            raise AppError(
                code="MATRIX_PROVISION_IDENTITY_MISMATCH",
                message="Matrix 返回了不匹配的账号",
                status_code=502,
            )
        return matrix_user_id
