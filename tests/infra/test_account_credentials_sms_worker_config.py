from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


def test_api_and_worker_share_sms_and_otp_settings():
    services = yaml.safe_load((ROOT / "docker-compose.yml").read_text(encoding="utf-8"))["services"]
    api = services["business-api"]["environment"]
    worker = services["business-worker"]["environment"]
    required = (
        "PHONE_AUTH_ENABLED", "OTP_HASH_SECRET", "SMS_PROVIDER",
        "SMS_ALIYUN_ACCESS_KEY_ID", "SMS_ALIYUN_ACCESS_KEY_SECRET",
        "SMS_ALIYUN_SIGN_NAME", "SMS_ALIYUN_TEMPLATE_CODE",
        "SMS_ALIYUN_REGION", "SMS_ALIYUN_CODE_VALID_MINUTES",
        "EMAIL_VERIFICATION_SECRET",
    )
    for suffix in required:
        key = f"BUSINESS_{suffix}"
        assert key in api and key in worker, f"{key} is needed by both OTP producer and delivery worker"
        assert api[key] == worker[key], f"{key} must use the same deployment input"
    assert api["BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES"] == "${BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES:-15}"


def test_sms_example_is_disabled_and_has_no_credential_default():
    entries = dict(line.split("=", 1) for line in (ROOT / ".env.example").read_text(encoding="utf-8").splitlines()
                   if line and not line.startswith("#") and "=" in line)
    assert entries["BUSINESS_PHONE_AUTH_ENABLED"] == "false"
    assert entries["BUSINESS_SMS_PROVIDER"] == "disabled"
    assert entries["BUSINESS_SMS_ALIYUN_CODE_VALID_MINUTES"] == "15"
    for key in ("BUSINESS_OTP_HASH_SECRET", "BUSINESS_SMS_ALIYUN_ACCESS_KEY_ID", "BUSINESS_SMS_ALIYUN_ACCESS_KEY_SECRET"):
        assert entries[key] == ""
