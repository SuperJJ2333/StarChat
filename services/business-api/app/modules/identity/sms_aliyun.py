"""ADR-0075：阿里云验证码短信适配器（dypnsapi 2017-05-25）。

用户 2026-09-21 指定供应商与接口：
- SendSmsVerifyCode：阿里云生成验证码并下发（模板 `##code##` 占位符，
  `min` 有效分钟数），业务侧不接触验证码明文；
- CheckSmsVerifyCode：用户提交码的权威校验。

红线：
- AccessKey/Secret 只从服务端配置（SecretStr）进入 SDK，绝不进日志、
  错误、Outbox、测试快照；
- 手机号只以供应商要求的形式（大陆 11 位）出现在 SDK 请求里，日志一律
  脱敏；异常映射不携带凭据或完整号码；
- 未配置/超时/供应商失败一律 fail-closed（绝不伪成功、不写假验证码）。

测试不依赖 SDK 安装：client_factory 可注入替身（返回带
send_sms_verify_code / check_sms_verify_code 的客户端对象）。生产装配
使用默认工厂（惰性导入 alibabacloud SDK）。
"""
from __future__ import annotations

import json
from hashlib import sha256
from typing import Any, Callable

from app.core.errors import AppError
from app.modules.identity.phone import SmsSender, mask_phone

SDK_ENDPOINT = "dypnsapi.aliyuncs.com"  # SDK 2.0.0 endpoint rule is central.
# 阿里云 OpenAPI 业务返回码：OK=成功；其余视为失败（保留前缀判断以覆盖
# 可能的子码，如 "FAIL"、"CODE_INVALID" 等由具体实现如实上报）。
PROVIDER_OK = "OK"


def _provider_error_code(error: Exception) -> str | None:
    # TeaException and OpenAPI ClientException both expose a structured code.
    # Never classify from message text: it can contain unrelated upstream data.
    code = getattr(error, "code", None)
    return code if isinstance(code, str) else None


def _is_provider_rejection(error: Exception) -> bool:
    code = _provider_error_code(error)
    status = getattr(error, "status_code", getattr(error, "statusCode", None))
    return status == 403 or bool(code and (code == "Forbidden" or code.startswith("Forbidden.")))


class AliyunDypnsSmsSender(SmsSender):
    """供应商生成并校验验证码的适配器。

    `client_factory()` 返回实现两个方法的客户端：
      - send_sms_verify_code(request) -> body 带 code 字段的响应对象；
      - check_sms_verify_code(request) -> 同上；
    生产默认工厂惰性导入 alibabacloud SDK；测试注入替身。
    """

    def __init__(
        self,
        *,
        access_key_id: str,
        access_key_secret: str,
        sign_name: str,
        template_code: str,
        region: str = "ap-southeast-1",
        code_valid_minutes: int = 5,
        client_factory: Callable[[], Any] | None = None,
        request_factory: Callable[[str, dict], Any] | None = None,
        timeout_seconds: float = 6.0,
    ):
        if not access_key_id or not access_key_secret:
            raise ValueError("aliyun sms credentials required")
        if not sign_name or not template_code:
            raise ValueError("aliyun sms sign/template required")
        if not 1 <= int(code_valid_minutes) <= 10:
            raise ValueError("aliyun sms code validity must be 1-10 minutes")
        self._access_key_id = access_key_id
        self._access_key_secret = access_key_secret
        self._sign_name = sign_name
        self._template_code = template_code
        self._region = region
        self._code_valid_minutes = int(code_valid_minutes)
        self._timeout_seconds = float(timeout_seconds)
        self._client_factory = client_factory or self._default_client_factory
        self._request_factory = request_factory or self._default_request_factory
        self._client = None

    # ---------------------------------------------------------------- client
    def _default_client_factory(self):
        """生产装配：惰性导入 SDK；未安装即明确失败（绝不伪成功）。"""
        try:
            from alibabacloud_dypnsapi20170525.client import Client as DypnsClient
            from alibabacloud_tea_openapi import models as open_api_models
        except ImportError as error:  # pragma: no cover - 取决于部署环境
            raise AppError(code="SMS_PROVIDER_UNAVAILABLE",
                message="短信供应商 SDK 未安装", status_code=503) from error
        config = open_api_models.Config(
            access_key_id=self._access_key_id,
            access_key_secret=self._access_key_secret,
            endpoint=SDK_ENDPOINT,
        )
        config.read_timeout = int(self._timeout_seconds * 1000)
        config.connect_timeout = int(self._timeout_seconds * 1000)
        return DypnsClient(config)

    def _get_client(self):
        if self._client is None:
            self._client = self._client_factory()
        return self._client

    # ---------------------------------------------------------------- helpers
    @staticmethod
    def _provider_number(phone: str) -> str:
        """供应商要求大陆 11 位裸号（无 +86 前缀）。"""
        return phone[3:] if phone.startswith("+86") else phone

    @staticmethod
    def _body_code(response: Any) -> str | None:
        body = getattr(response, "body", None)
        code = getattr(body, "code", None)
        if code is None and isinstance(body, dict):
            code = body.get("Code") or body.get("code")
        return str(code) if code is not None else None

    @staticmethod
    def _default_request_factory(class_name: str, kwargs: dict):
        """生产装配：惰性导入 SDK 请求模型；测试注入 dict 工厂，不需要 SDK。"""
        from alibabacloud_dypnsapi20170525 import models as dypns_models

        return getattr(dypns_models, class_name)(**kwargs)

    @staticmethod
    def _scheme(purpose: str, challenge_id: str) -> str:
        # SchemeName allows 20 characters. Each issuance gets its own namespace;
        # OutId is checked too, but may merely be provider tracking metadata.
        return "sc" + sha256(f"{purpose}:{challenge_id}".encode()).hexdigest()[:18]

    # ---------------------------------------------------------------- protocol
    def send_challenge(self, phone: str, code: str, purpose: str, challenge_id: str) -> None:
        self.send(phone, code, purpose, challenge_id=challenge_id)

    def send(self, phone: str, code: str, purpose: str, *, challenge_id: str) -> None:
        """触发阿里云下发验证码（验证码由供应商生成，`code` 参数被忽略——
        仅为兼容 SmsSender 协议；业务侧哈希路径在 provider 模式下不参与校验）。"""
        del code  # provider-generated
        try:
            client = self._get_client()
            request = self._request_factory("SendSmsVerifyCodeRequest", dict(
                sign_name=self._sign_name,
                template_code=self._template_code,
                phone_number=self._provider_number(phone),
                country_code='86',
                code_type=1,
                code_length=6,
                return_verify_code=False,
                scheme_name=self._scheme(purpose, challenge_id),
                out_id=challenge_id,
                valid_time=self._code_valid_minutes * 60,
                template_param=json.dumps(
                    {"code": "##code##", "min": str(self._code_valid_minutes)},
                    separators=(",", ":")),
            ))
            response = client.send_sms_verify_code(request)
        except AppError:
            raise
        except Exception as error:
            # 供应商业务拒绝（如 RAM 403 Forbidden）不是网络超时：如实分类，
            # 不泄漏凭据与完整号码；其余按网络不可用处理。
            if _is_provider_rejection(error):
                raise AppError(code="SMS_SEND_REJECTED",
                    message="短信发送被供应商拒绝（请检查账号权限/签名/模板）",
                    status_code=503) from None
            raise AppError(code="SMS_PROVIDER_TIMEOUT",
                message="短信发送暂不可用，请稍后重试", status_code=503) from None
        result = self._body_code(response)
        if result != PROVIDER_OK or self._field(getattr(response, "body", None), "success", "Success") is False:
            raise AppError(code="SMS_SEND_FAILED",
                message="短信发送失败，请稍后重试", status_code=503)

    def verify(self, phone: str, purpose: str, code: str, challenge_id: str) -> bool:
        """CheckSmsVerifyCode 权威校验。

        返回 False = 供应商判定不匹配/过期（调用方按本地尝试次数计数）；
        抛 SMS_VERIFY_UNAVAILABLE = 供应商不可达（本次不计尝试、不消费）。
        """
        try:
            client = self._get_client()
            request = self._request_factory("CheckSmsVerifyCodeRequest", dict(
                phone_number=self._provider_number(phone),
                country_code='86',
                verify_code=str(code),
                scheme_name=self._scheme(purpose, challenge_id),
                out_id=challenge_id,
            ))
            response = client.check_sms_verify_code(request)
        except AppError:
            raise
        except Exception as error:
            # 真实契约（2026-09-23 实测）：错码/过期不返回 200+FAIL，而是抛
            # OpenAPI 业务错误 isv.ValidateFail(code:400,"验证失败")——这是
            # 权威的"不匹配"判定，必须计入尝试次数（返回 False），否则
            # 五次尝试上限会被绕过。其余 isv.* 配置类错误与网络异常按
            # 不可用处理（不计尝试、不消费）。
            if _provider_error_code(error) == "isv.ValidateFail":
                return False
            raise AppError(code="SMS_VERIFY_UNAVAILABLE",
                message="短信校验暂不可用，请稍后重试", status_code=503) from None
        result = self._body_code(response)
        if result == "isv.ValidateFail":
            return False
        if result != PROVIDER_OK or self._field(getattr(response, "body", None), "success", "Success") is False:
            # API errors are not authoritative mismatched-code verdicts.
            raise AppError(code="SMS_VERIFY_UNAVAILABLE",
                message="短信校验暂不可用，请稍后重试", status_code=503)
        body = getattr(response, "body", None)
        model = self._field(body, "model", "Model")
        verdict = self._field(model, "verify_result", "VerifyResult")
        if verdict in {"FAIL", "UNKNOWN"}:
            return False
        if verdict != "PASS":
            raise AppError(code="SMS_VERIFY_UNAVAILABLE",
                message="短信校验暂不可用，请稍后重试", status_code=503)
        return self._field(model, "out_id", "OutId") == challenge_id

    @staticmethod
    def _field(value: Any, attribute: str, key: str):
        if isinstance(value, dict):
            return value.get(key, value.get(attribute))
        return getattr(value, attribute, None)

    def describe(self) -> dict:
        """无敏感信息的装配描述（审计/健康页用）。"""
        return {"provider": "aliyun_dypns", "region": self._region,
            "sign_name": self._sign_name, "template_code": self._template_code,
            "code_valid_minutes": self._code_valid_minutes,
            "target_example": mask_phone("+8613800000000")}
