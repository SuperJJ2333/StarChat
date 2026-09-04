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


def test_release_workflow_creates_github_release_with_sums():
    """CI 主发布路径：tag 构建 → GitHub Release（APK + SHA256SUMS）。"""
    release = (WORKFLOWS / "android-release.yml").read_text(encoding="utf-8")
    assert "gh release create" in release, "tag 构建必须创建 GitHub Release（服务器下行拉取的数据源）"
    assert "SHA256SUMS" in release, "Release 必须附带 SHA256SUMS（服务器部署前校验依据）"
    assert "sha256sum ChatFlow-*.apk" in release
    # tag 与 pubspec 版本一致性（防错位发布）
    assert "Version consistency" in release
    assert "与 pubspec" in release
    # Release 只在 tag 触发时创建（dispatch 产物不挂可变分支）
    assert "github.event_name == 'push'" in release
    # publish 仍未自动化（守护既有断言之外的再确认）
    assert "app-update-settings" not in release.replace("docs/RUNBOOK_RELEASE.md", "")


def test_server_pull_release_script_follows_hard_rules():
    """服务器下行拉取脚本的部署红线。"""
    script = (ROOT / "scripts" / "server_pull_release.sh").read_text(encoding="utf-8")
    # 部署前强制 SHA256SUMS 校验
    assert "sha256sum -c SHA256SUMS" in script
    # 校验失败即中止
    assert "set -euo pipefail" in script
    # 别名硬规矩：ln -sfn，绝 cp 到 latest-
    assert "ln -sfn" in script
    assert not any(
        line.strip().startswith("cp ") and "latest-" in line
        for line in script.splitlines()
    ), "禁止 cp 到 latest-*（符号链接会被穿透）"
    # publish 不默认执行（--publish 显式开启；发布是业务决策）
    assert "--publish" in script
    assert "PUBLISH=0" in script
    # 下载必须来自 GitHub Release（不经任何第三方镜像）
    assert "https://github.com/" in script
    assert "releases/download" in script


def test_release_ci_trigger_follows_hard_rules():
    """本地触发脚本的发布红线。"""
    script = (ROOT / "scripts" / "release_ci.ps1").read_text(encoding="utf-8")
    # CI 构建的是 git 内容：脏树必须拒绝（测过的=发出的）
    assert "status --porcelain" in script
    assert "工作树有未提交变更" in script
    # 版本三方一致预检
    assert "app_config.dart" in script
    # 回拉验证对照 GitHub Release 的 SHA256SUMS
    assert "SHA256SUMS" in script
    assert "aapt" in script
    # 幂等发布契约
    assert "PUBLISH_RESULT PASS" in script
    # SSH 限流退避
    assert "Invoke-Remote" in script


def test_publish_app_update_script_is_parameterized_and_safe():
    """publish 脚本（release.ps1 内嵌版抽出）：只写 app 更新设置。"""
    script = (ROOT / "scripts" / "publish_app_update.py").read_text(encoding="utf-8")
    assert "app-update-settings" in script
    assert "RELEASE_VERSION" in script
    assert "NOTES_FILE" in script
    assert "PUBLISH_RESULT" in script
    # 幂等键约定与 release.ps1 一致
    assert "app-update-publish-" in script
    # 唯一 SQL 是 super-admin 会话查询（绝不直接 UPDATE 其他业务表）
    import re as _re

    sqls = _re.findall(r'execute\(text\(\s*"([^"]+)"', script)
    assert sqls, "应包含 super-admin 会话查询 SQL"
    assert all(
        stmt.lstrip().lower().startswith("select") for stmt in sqls
    ), f"publish 脚本不得直接改业务表：{sqls}"
