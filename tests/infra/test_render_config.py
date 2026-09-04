"""render_config.py：服务器配置渲染机制的单元测试。

核心红线：
- {{TOKEN}} 未解析硬失败；
- 原地写保 inode（单文件 bind-mount 语义）；
- --check 漂移检测退出码；
- --require-production 拒绝 TURN 类占位值（事故根因的机器拦截）；
- sygnal.yaml 已存在时绝不覆盖（保护未来手工填入的凭据）。
"""
import json
import os
import stat
import subprocess
import sys
import textwrap

import pytest

RENDERER = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "infra", "render_config.py")
)


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="")


def scaffold(tmp_path, env_extra="", nginx_body="resolver x;", sygnal_exists=False):
    """最小部署骨架：模板 + env + 可选已有 sygnal.yaml。"""
    write(tmp_path / "infra/synapse/homeserver.yaml.template",
          "server_name: \"{{MATRIX_SERVER_NAME}}\"\npassword: \"{{POSTGRES_PASSWORD}}\"\n")
    write(tmp_path / "infra/nginx/nginx.conf.template",
          "server_name {{PUBLIC_HOSTNAME}};\n" + nginx_body)
    write(tmp_path / "infra/element/config.json.template",
          "{\"brand\": \"{{MATRIX_SERVER_NAME}}\"}")
    write(tmp_path / "infra/sygnal/sygnal.yaml.template", "apps: {}\n")
    write(tmp_path / "infra/sygnal/nooppushkin.py", "# static\n")
    env = "\n".join([
        "MATRIX_SERVER_NAME=example.test",
        "POSTGRES_PASSWORD=secret-value",
        "PUBLIC_HOSTNAME=app.example.test",
    ] + ([env_extra] if env_extra else []))
    write(tmp_path / ".env", env)
    if sygnal_exists:
        write(tmp_path / "data/sygnal/sygnal.yaml", "apps: {REAL_CREDS: hidden}\n")
    return tmp_path


def run(args, cwd):
    return subprocess.run(
        [sys.executable, str(RENDERER), *args],
        cwd=cwd, capture_output=True, text=True, encoding="utf-8",
    )


def test_renders_all_targets_and_is_idempotent(tmp_path):
    root = scaffold(tmp_path)
    first = run([], root)
    assert first.returncode == 0, first.stderr
    homeserver = (root / "data/synapse/homeserver.yaml").read_text(encoding="utf-8")
    assert 'server_name: "example.test"' in homeserver
    assert "secret-value" in homeserver
    nginx = (root / "data/nginx/nginx.conf").read_text(encoding="utf-8")
    assert "server_name app.example.test;" in nginx
    element = json.loads((root / "data/element/config.json").read_text(encoding="utf-8"))
    assert element["brand"] == "example.test"
    # 幂等：第二次运行零变更。
    second = run([], root)
    assert second.returncode == 0
    assert "NO CHANGE" in second.stdout


def test_missing_variable_fails_hard(tmp_path):
    root = scaffold(tmp_path)
    (root / ".env").write_text("MATRIX_SERVER_NAME=x\n", encoding="utf-8", newline="")
    result = run([], root)
    assert result.returncode != 0
    assert "POSTGRES_PASSWORD" in result.stderr + result.stdout


def test_unresolved_token_fails_hard(tmp_path):
    root = scaffold(tmp_path)
    # 模板里放一个 env 没有的 token（大小写规则内）。
    write(tmp_path / "infra/nginx/nginx.conf.template",
          "server_name {{PUBLIC_HOSTNAME}}; extra {{NOT_PROVIDED}};")
    result = run([], root)
    assert result.returncode != 0


def test_in_place_write_preserves_inode(tmp_path):
    root = scaffold(tmp_path)
    assert run([], root).returncode == 0
    target = root / "data/nginx/nginx.conf"
    inode_before = target.stat().st_ino
    # 内容变更仍必须保持 inode（bind-mount 语义）。
    env = (root / ".env").read_text(encoding="utf-8")
    write(root / ".env", env.replace("app.example.test", "changed.example.test"))
    assert run([], root).returncode == 0
    assert target.stat().st_ino == inode_before
    assert "changed.example.test" in target.read_text(encoding="utf-8")


def test_check_mode_detects_drift_and_exit_codes(tmp_path):
    root = scaffold(tmp_path)
    # 未渲染：全部漂移。
    result = run(["--check"], root)
    assert result.returncode == 1
    assert "homeserver.yaml" in result.stdout
    # 渲染后：零漂移。
    assert run([], root).returncode == 0
    assert run(["--check"], root).returncode == 0
    # 手工改服务器副本（漂移复现）→ 必须被抓。
    target = root / "data/synapse/homeserver.yaml"
    target.write_text("hand-edited\n", encoding="utf-8", newline="")
    result = run(["--check"], root)
    assert result.returncode == 1
    assert "homeserver.yaml" in result.stdout


def test_sygnal_yaml_never_overwritten_once_present(tmp_path):
    root = scaffold(tmp_path, sygnal_exists=True)
    assert run([], root).returncode == 0
    content = (root / "data/sygnal/sygnal.yaml").read_text(encoding="utf-8")
    assert "REAL_CREDS" in content, "已存在的 sygnal.yaml（含真实凭据）绝不被模板覆盖"


def test_production_guard_rejects_placeholder_turn_values(tmp_path):
    root = scaffold(tmp_path, env_extra="\n".join([
        "TURN_SHARED_SECRET=development-turn-shared-secret",
        "TURN_URI_UDP=turn:10.0.2.2:3478?transport=udp",
        "TURN_URI_TCP=turn:liuhetong888.com:3478?transport=tcp",
        "TURN_URI_TLS=turns:liuhetong888.com:5349?transport=tcp",
        "SYNAPSE_PUBLIC_BASEURL=https://liuhetong888.com",
    ]))
    result = run(["--require-production"], root)
    assert result.returncode != 0
    combined = result.stderr + result.stdout
    assert "TURN_SHARED_SECRET" in combined
    assert "TURN_URI_UDP" in combined


def test_production_guard_accepts_real_values(tmp_path):
    root = scaffold(tmp_path, env_extra="\n".join([
        "TURN_SHARED_SECRET=a-real-random-secret",
        "TURN_URI_UDP=turn:liuhetong888.com:3478?transport=udp",
        "TURN_URI_TCP=turn:liuhetong888.com:3478?transport=tcp",
        "TURN_URI_TLS=turns:liuhetong888.com:5349?transport=tcp",
        "SYNAPSE_PUBLIC_BASEURL=https://liuhetong888.com",
    ]))
    result = run(["--require-production"], root)
    assert result.returncode == 0, result.stderr + result.stdout


def test_element_output_must_be_valid_json(tmp_path):
    root = scaffold(tmp_path)
    # 模板产出非法 JSON → 渲染必须硬失败。
    write(tmp_path / "infra/element/config.json.template", "{\"brand\": {{MATRIX_SERVER_NAME}}}")
    result = run([], root)
    assert result.returncode != 0


def test_noop_pushkin_updated_when_source_changes(tmp_path):
    root = scaffold(tmp_path)
    assert run([], root).returncode == 0
    write(root / "infra/sygnal/nooppushkin.py", "# static v2\n")
    result = run([], root)
    assert result.returncode == 0
    assert "nooppushkin.py (updated)" in result.stdout
    assert (root / "data/sygnal/nooppushkin.py").read_text(encoding="utf-8").startswith("# static v2")
