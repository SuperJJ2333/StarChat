"""守卫：Android CI/发布工作流结构断言（仿 test_ios_simulator_ci.py）。

保证 CI 工作流不被静默弱化：全量 flutter test 必须在门禁里、
Flutter 版本必须固定、签名构建必须检测 Secrets 并 fail-fast、
publish 不得自动化。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


def test_android_ci_workflow_exists_and_pins_flutter():
    ci = (WORKFLOWS / "android-ci.yml").read_text(encoding="utf-8")
    assert "subosito/flutter-action@v2" in ci
    assert "flutter-version: '3.44.9'" in ci, "Flutter 版本必须固定（与本地/iOS 工作流一致）"
    # 三个 job 齐备
    for job in ("backend:", "flutter:", "android-debug-build:"):
        assert job in ci, f"缺少 job：{job}"
    # 全量测试必须存在（不得被降级为 analyze-only）
    assert "run: flutter test" in ci


def test_android_ci_backend_job_runs_all_python_suites():
    ci = (WORKFLOWS / "android-ci.yml").read_text(encoding="utf-8")
    for suite in (
        "tests/infra",
        "tests/getui_bridge",
        "tests/business_api",
        "tests/business_worker",
        "tests/mobile",
    ):
        assert suite in ci, f"backend job 缺少 {suite}"
    # Linux PYTHONPATH 分隔符（Windows 的 ; 在 CI 上会静默失效）
    assert "PYTHONPATH: services/getui-bridge" in ci
    assert "services/business-api:services/business-worker/app" in ci
    # OpenAPI 与 compose 渲染守卫
    assert "export_openapi.py --check" in ci
    assert "docker compose --env-file .env.example config --quiet" in ci


def test_release_workflow_requires_secrets_and_never_auto_publishes():
    release = (WORKFLOWS / "android-release.yml").read_text(encoding="utf-8")
    # Secrets fail-fast（不得静默跳过或伪装成功）
    assert "ANDROID_KEYSTORE_BASE64" in release
    assert "ANDROID_KEY_PROPERTIES" in release
    assert "缺少 ANDROID_KEYSTORE_BASE64" in release or "::error::" in release
    # 签名密钥不落日志：只打印字段名
    assert "cut -d= -f1 key.properties" in release
    # publish 不自动化：工作流内不得调用 app-update-settings PUT
    assert "app-update-settings" not in release.replace("docs/RUNBOOK_RELEASE.md", "")
    # 上传用别名必须是 ln -sfn（0.3.32 cp 穿透符号链接事故教训）
    assert "ln -sfn" in release
    assert not any(
        line.strip().startswith("cp ") and "latest-" in line
        for line in release.splitlines()
    ), "禁止 cp 到 latest-*（符号链接会被穿透）"


def test_release_workflow_uses_keystore_file_env():
    release = (WORKFLOWS / "android-release.yml").read_text(encoding="utf-8")
    assert "KEYSTORE_FILE:" in release, "签名路径经 KEYSTORE_FILE 环境变量（gradle 侧支持）"


def test_release_script_follows_hard_rules():
    script = (ROOT / "scripts" / "release.ps1").read_text(encoding="utf-8")
    # 别名硬规矩
    assert "ln -sfn" in script
    # 幂等键约定
    assert "app-update-publish-" in script
    # 回拉验证
    assert "PUBLISH_RESULT" in script
    assert "Get-FileHash" in script
    # SSH 限流退避
    assert "Invoke-Remote" in script
    assert "Connection reset" in script
    # 版本三方一致预检
    assert "app_config.dart" in script
