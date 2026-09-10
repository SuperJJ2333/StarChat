from base64 import urlsafe_b64encode
from datetime import datetime, timezone
from hashlib import sha256
import hmac
from typing import NoReturn, Protocol
from urllib.parse import quote

import httpx

from app.core.errors import AppError


class MatrixAdminGateway(Protocol):
    def ensure_user(self, localpart: str, password: str) -> str: ...

    def invite_room_as_user(self, inviter_id: str, matrix_user_id: str, room_id: str) -> None: ...

    def join_room_as_user(
        self,
        matrix_user_id: str,
        room_id: str,
        *,
        join_content: dict | None = None,
    ) -> None: ...

    def get_room_state(self, room_id: str) -> list[dict]: ...

    def get_room_members(self, room_id: str) -> set[str]: ...

    def issue_login_token(self, matrix_user_id: str, expires_in: int) -> str: ...

    def session_identity(self, access_token: str) -> tuple[str, str]: ...

    def list_devices(self, matrix_user_id: str) -> list[str]: ...

    def revoke_device(self, matrix_user_id: str, device_id: str) -> None: ...

    def complete_mobile_login(self, *, matrix_user_id: str, device_id: str,
        generation: int, display_name: str | None) -> dict: ...

    def upload_profile_media(self, content: bytes, mime_type: str) -> str: ...

    def set_user_profile(
        self,
        matrix_user_id: str,
        *,
        display_name: str,
        avatar_url: str | None,
    ) -> None: ...


class MatrixCredentialCodec:
    def __init__(self, secret: bytes) -> None:
        if len(secret) < 16:
            raise ValueError("matrix provisioning secret must be at least 16 bytes")
        self._secret = secret

    def password_for(self, user_id: str) -> str:
        digest = hmac.new(self._secret, user_id.encode("utf-8"), sha256).digest()
        return urlsafe_b64encode(digest).decode("ascii").rstrip("=")


class SynapseMatrixAdminGateway:
    def complete_mobile_login(self, *, matrix_user_id, device_id, generation, display_name):
        try:
            response = self._client.post(
                f'{self._homeserver_url}/_synapse/client/chatflow/mobile_login',
                headers={'Authorization': f'Bearer {self._admin_access_token}'},
                json={'user_id': matrix_user_id, 'device_id': device_id,
                      'generation': generation, 'initial_device_display_name': display_name})
            if response.status_code != 200:
                raise ValueError('upstream rejected operation')
            result = response.json()
            if not isinstance(result, dict):
                raise ValueError('invalid response')
            return result
        except (httpx.HTTPError, ValueError):
            raise AppError(code='MATRIX_LOGIN_PENDING', message='聊天登录尚未完成，请重新登录重试', status_code=503) from None

    def __init__(
        self,
        *,
        homeserver_url: str,
        server_name: str,
        admin_access_token: str,
        client: httpx.Client | None = None,
        now_factory=None,
    ) -> None:
        self._homeserver_url = homeserver_url.rstrip("/")
        self._server_name = server_name
        self._admin_access_token = admin_access_token
        self._client = client or httpx.Client(timeout=10.0)
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def ensure_user(self, localpart: str, password: str) -> str:
        matrix_user_id = f"@{localpart}:{self._server_name}"
        path_user_id = quote(matrix_user_id, safe="")
        url = f"{self._homeserver_url}/_synapse/admin/v2/users/{path_user_id}"
        headers = {"Authorization": f"Bearer {self._admin_access_token}"}
        try:
            response = self._client.put(
                url,
                headers=headers,
                json={
                    "password": password,
                    "admin": False,
                    "deactivated": False,
                    "displayname": localpart,
                },
            )
        except httpx.TimeoutException:
            try:
                response = self._client.get(url, headers=headers)
            except httpx.HTTPError:
                raise AppError(
                    code="MATRIX_PROVISION_RESULT_UNKNOWN",
                    message="Matrix 账号创建结果未知",
                    status_code=503,
                ) from None
            if response.status_code != 200:
                raise AppError(
                    code="MATRIX_PROVISION_RESULT_UNKNOWN",
                    message="Matrix 账号创建结果未知",
                    status_code=503,
                )
        except httpx.HTTPError:
            raise AppError(
                code="MATRIX_PROVISION_FAILED",
                message="Matrix 账号创建暂时失败",
                status_code=502,
            ) from None
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

    def join_room_as_user(
        self,
        matrix_user_id: str,
        room_id: str,
        *,
        join_content: dict | None = None,
    ) -> None:
        path_user_id = quote(matrix_user_id, safe="")
        token_response = self._client.post(
            f"{self._homeserver_url}/_synapse/admin/v1/users/{path_user_id}/login",
            headers={"Authorization": f"Bearer {self._admin_access_token}"},
            json={"valid_until_ms": int(self._now_factory().timestamp() * 1000) + 60_000},
        )
        if token_response.status_code != 200:
            raise AppError(code="MATRIX_GROUP_JOIN_FAILED", message="群成员加入失败", status_code=502)
        token = token_response.json().get("access_token")
        # join_content 会成为 m.room.member 事件内容的一部分（如扫码加入
        # 标记 com.changliao.join_source）；仅允许白名单键，绝不放凭据。
        response = self._client.post(
            f"{self._homeserver_url}/_matrix/client/v3/join/{quote(room_id, safe='')}",
            headers={"Authorization": f"Bearer {token}"}, json=join_content or {},
        )
        if response.status_code not in (200, 201):
            raise AppError(code="MATRIX_GROUP_JOIN_FAILED", message="群成员加入失败", status_code=502)

    def invite_room_as_user(self, inviter_id: str, matrix_user_id: str, room_id: str) -> None:
        """Invite via the moderator's client API: Synapse enforces power and bans.

        This deliberately does not use an administrative forced-join endpoint.
        The short-lived token is kept only in memory and is never returned.
        """
        try:
            login = self._client.post(
                f"{self._homeserver_url}/_synapse/admin/v1/users/{quote(inviter_id, safe='')}/login",
                headers={"Authorization": f"Bearer {self._admin_access_token}"},
                json={"valid_until_ms": int(self._now_factory().timestamp() * 1000) + 60_000},
            )
            if login.status_code != 200:
                raise ValueError('login failed')
            token = login.json().get('access_token')
            if not isinstance(token, str) or not token:
                raise ValueError('missing access token')
            response = self._client.post(
                f"{self._homeserver_url}/_matrix/client/v3/rooms/{quote(room_id, safe='')}/invite",
                headers={"Authorization": f"Bearer {token}"},
                json={"user_id": matrix_user_id},
            )
            if response.status_code != 200:
                raise ValueError('invite failed')
        except (httpx.HTTPError, ValueError, AttributeError):
            raise AppError(code='MATRIX_GROUP_INVITE_FAILED', message='群成员邀请失败', status_code=502) from None

    def get_room_state(self, room_id: str) -> list[dict]:
        """读取房间全量状态（Synapse admin API）。

        返回原始 state 事件列表（type/state_key/content/sender）。用于
        服务端校验：操作者是否在房间、被邀者 invite 事件、群公开设置
        （com.changliao.group.settings）。房间不存在返回 []。
        """
        response = self._client.get(
            f"{self._homeserver_url}/_synapse/admin/v1/rooms/{quote(room_id, safe='')}/state",
            headers={"Authorization": f"Bearer {self._admin_access_token}"},
        )
        if response.status_code == 404:
            return []
        if response.status_code != 200:
            raise AppError(
                code="MATRIX_ROOM_STATE_UNAVAILABLE",
                message="群聊状态暂时不可用",
                status_code=502,
            )
        body = response.json()
        events = body.get("state", body) if isinstance(body, dict) else body
        return [event for event in events if isinstance(event, dict)]

    def get_room_members(self, room_id: str) -> set[str]:
        """当前 join 成员的 Matrix 用户 ID 集合（权威成员关系）。

        F06：红包查看/领取的房间授权数据源。只读成员状态事件（元数据），
        不触碰消息内容——E2EE 边界不受影响。房间不存在/不可达返回空集
        （调用方按"无法证明成员身份"拒绝，fail closed）。
        """
        return {
            event["state_key"]
            for event in self.get_room_state(room_id)
            if event.get("type") == "m.room.member"
            and isinstance(event.get("state_key"), str)
            and isinstance(event.get("content"), dict)
            and event["content"].get("membership") == "join"
        }
    def issue_login_token(self, matrix_user_id: str, expires_in: int) -> str:
        path_user_id = quote(matrix_user_id, safe="")
        url = (
            f"{self._homeserver_url}/_synapse/admin/v1/users/"
            f"{path_user_id}/login"
        )
        valid_until_ms = int(self._now_factory().timestamp() * 1000) + expires_in * 1000
        try:
            admin_response = self._client.post(
                url,
                headers={"Authorization": f"Bearer {self._admin_access_token}"},
                json={"valid_until_ms": valid_until_ms},
            )
        except httpx.HTTPError:
            self._login_token_failed()
        if admin_response.status_code != 200:
            self._raise_login_response_error(admin_response)
        try:
            short_lived_access_token = admin_response.json()["access_token"]
        except (ValueError, KeyError, TypeError):
            self._login_token_failed()
        if not isinstance(short_lived_access_token, str) or not short_lived_access_token:
            self._login_token_failed()

        try:
            token_response = self._client.post(
                f"{self._homeserver_url}/_matrix/client/v1/login/get_token",
                headers={"Authorization": f"Bearer {short_lived_access_token}"},
                json={},
            )
        except httpx.HTTPError:
            self._login_token_failed()
        if token_response.status_code != 200:
            self._raise_login_response_error(token_response)
        try:
            login_token = token_response.json()["login_token"]
        except (ValueError, KeyError, TypeError):
            self._login_token_failed()
        if not isinstance(login_token, str) or not login_token:
            self._login_token_failed()
        return login_token

    def session_identity(self, access_token: str) -> tuple[str, str]:
        try:
            response = self._client.get(
                f'{self._homeserver_url}/_matrix/client/v3/account/whoami',
                headers={'Authorization': f'Bearer {access_token}'})
            if response.status_code >= 500 or response.status_code == 429:
                raise httpx.HTTPError('identity temporarily unavailable')
            if response.status_code != 200:
                raise ValueError('identity unavailable')
            body = response.json()
            user_id, device_id = body.get('user_id'), body.get('device_id')
            if (body.get('is_guest') or not isinstance(user_id, str) or not user_id
                    or not isinstance(device_id, str) or not device_id):
                raise ValueError('identity incomplete')
            return user_id, device_id
        except httpx.HTTPError:
            raise AppError(code='MATRIX_SESSION_IDENTITY_UNAVAILABLE',
                message='聊天设备身份暂时无法验证，请重试', status_code=503) from None
        except (ValueError, AttributeError):
            raise AppError(code='MATRIX_SESSION_IDENTITY_INVALID',
                message='聊天设备身份验证失败', status_code=401) from None

    def list_devices(self, matrix_user_id: str) -> list[str]:
        try:
            response = self._client.get(
                f'{self._homeserver_url}/_synapse/admin/v2/users/{quote(matrix_user_id, safe="")}/devices',
                headers={'Authorization': f'Bearer {self._admin_access_token}'})
            if response.status_code != 200:
                raise ValueError('devices unavailable')
            devices = response.json().get('devices')
            if not isinstance(devices, list):
                raise ValueError('invalid devices')
            result = []
            for device in devices:
                device_id = device.get('device_id')
                if not isinstance(device_id, str) or not device_id:
                    raise ValueError('invalid device')
                result.append(device_id)
            return sorted(set(result))
        except (httpx.HTTPError, ValueError, AttributeError):
            raise AppError(code='MATRIX_SESSION_DEVICES_UNAVAILABLE',
                message='聊天设备列表暂时不可用，请重试', status_code=503) from None

    def revoke_device(self, matrix_user_id: str, device_id: str) -> None:
        try:
            response = self._client.delete(
                f'{self._homeserver_url}/_synapse/admin/v2/users/{quote(matrix_user_id, safe="")}/devices/{quote(device_id, safe="")}',
                headers={'Authorization': f'Bearer {self._admin_access_token}'})
            if response.status_code not in (200, 204, 404):
                raise ValueError('device revocation unavailable')
        except (httpx.HTTPError, ValueError):
            raise AppError(code='MATRIX_DEVICE_REVOKE_FAILED',
                message='聊天设备退出暂时失败', status_code=503) from None

    def upload_profile_media(self, content: bytes, mime_type: str) -> str:
        try:
            response = self._client.post(
                f"{self._homeserver_url}/_matrix/media/v3/upload",
                headers={
                    "Authorization": f"Bearer {self._admin_access_token}",
                    "Content-Type": mime_type,
                },
                params={"filename": "avatar"},
                content=content,
            )
        except httpx.HTTPError:
            self._profile_sync_failed()
        if response.status_code != 200:
            self._profile_sync_failed()
        try:
            content_uri = response.json()["content_uri"]
        except (ValueError, KeyError, TypeError):
            self._profile_sync_failed()
        if not isinstance(content_uri, str) or not content_uri.startswith("mxc://"):
            self._profile_sync_failed()
        return content_uri

    def set_user_profile(
        self,
        matrix_user_id: str,
        *,
        display_name: str,
        avatar_url: str | None,
    ) -> None:
        path_user_id = quote(matrix_user_id, safe="")
        try:
            response = self._client.put(
                f"{self._homeserver_url}/_synapse/admin/v2/users/{path_user_id}",
                headers={"Authorization": f"Bearer {self._admin_access_token}"},
                json={"displayname": display_name, "avatar_url": avatar_url or ""},
            )
        except httpx.HTTPError:
            self._profile_sync_failed()
        if response.status_code != 200:
            self._profile_sync_failed()

    @staticmethod
    def _raise_login_response_error(response: httpx.Response) -> NoReturn:
        if response.status_code == 429:
            try:
                payload = response.json()
                milliseconds = payload.get("retry_after_ms") if isinstance(payload, dict) else None
            except ValueError:
                milliseconds = None
            seconds = 60
            if type(milliseconds) is int and 0 < milliseconds <= 86_400_000:
                seconds = (milliseconds + 999) // 1000
            raise AppError(
                code="MATRIX_LOGIN_RATE_LIMITED",
                message=f"聊天登录请求较频繁，请等待 {seconds} 秒后重试",
                status_code=429,
                retry_after_seconds=seconds,
            )
        SynapseMatrixAdminGateway._login_token_failed()

    @staticmethod
    def _login_token_failed() -> NoReturn:
        raise AppError(
            code="MATRIX_LOGIN_TOKEN_FAILED",
            message="Matrix 登录令牌签发失败",
            status_code=502,
        )

    @staticmethod
    def _profile_sync_failed() -> NoReturn:
        raise AppError(
            code="MATRIX_PROFILE_SYNC_FAILED",
            message="Matrix 资料同步失败",
            status_code=502,
        )
