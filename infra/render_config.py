#!/usr/bin/env python3
"""从仓库模板渲染服务器配置（唯一真源；杜绝服务器副本漂移）。

用法（在部署根目录，如 /opt/starchat）：
  python3 infra/render_config.py                 # 渲染（原地写，保 inode）
  python3 infra/render_config.py --check         # 只比对不写；漂移 exit 1
  python3 infra/render_config.py --require-production  # 叠加生产占位值守卫

渲染映射（与 scripts/init_matrix.ps1 同源）：
  infra/synapse/homeserver.yaml.template -> data/synapse/homeserver.yaml（总是）
  infra/nginx/nginx.conf.template        -> data/nginx/nginx.conf（总是）
  infra/element/config.json.template     -> data/element/config.json（总是）
  infra/sygnal/sygnal.yaml.template      -> data/sygnal/sygnal.yaml（仅当不存在：
                                           该文件将来含真实 FCM/APNs 凭据）
  infra/sygnal/nooppushkin.py            -> data/sygnal/nooppushkin.py（总是，静态拷贝）

红线：
- 未解析的 {{TOKEN}} 一律硬失败（与 TemplateTools.psm1 同规则）；
- 写入一律"读后原地重写"（open('w')），绝不 rename/mv——单文件 bind-mount
  （nginx.conf）在 inode 替换后会指向旧内容（0.3.32 事故根因），原地写
  保 inode，改配置后仅需 nginx -s reload；
- 本脚本不打印任何 env 值（密钥不出现在日志/终端）。
"""
import argparse
import json
import os
import re
import sys

TOKEN_RE = re.compile(r"\{\{[A-Z][A-Z0-9_]*\}\}")

# 生产守卫：这些变量的值不得含开发/占位特征（TURN 事故根因的机器拦截）。
PRODUCTION_FORBIDDEN_SUBSTRINGS = ("change-this", "development-", "10.0.2.2", "matrix.localhost:5349")
PRODUCTION_GUARDED_VARS = (
    "TURN_SHARED_SECRET",
    "TURN_URI_UDP",
    "TURN_URI_TCP",
    "TURN_URI_TLS",
)


def parse_env(path):
    values = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key:
                values[key] = value
    return values


def render(template, values):
    def replace(match):
        token = match.group(0)
        name = token[2:-2]
        if name not in values or values[name] == "":
            raise SystemExit(f"render_config: 未提供模板变量 {name}")
        return values[name]

    rendered = TOKEN_RE.sub(replace, template)
    leftover = TOKEN_RE.search(rendered)
    if leftover:
        raise SystemExit(f"render_config: 存在未解析模板 token: {leftover.group(0)}")
    return rendered


def write_in_place(path, content):
    """原地重写（truncate+write，保 inode）；内容一致则零写入。"""
    try:
        with open(path, encoding="utf-8") as handle:
            if handle.read() == content:
                return False
    except FileNotFoundError:
        pass
    # 打开即截断——即使文件被 bind-mount，inode 不变，容器立即可见新内容。
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(content)
    return True


def copy_if_absent(src, dest):
    if os.path.exists(dest):
        return False
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(src, encoding="utf-8") as handle:
        content = handle.read()
    with open(dest, "w", encoding="utf-8", newline="") as handle:
        handle.write(content)
    return True


def check_production_guards(values):
    problems = []
    baseurl = values.get("SYNAPSE_PUBLIC_BASEURL", "")
    if not baseurl.startswith("https://"):
        problems.append("SYNAPSE_PUBLIC_BASEURL 必须以 https:// 开头")
    for name in PRODUCTION_GUARDED_VARS:
        value = values.get(name, "")
        if not value:
            problems.append(f"{name} 未设置")
            continue
        for marker in PRODUCTION_FORBIDDEN_SUBSTRINGS:
            if marker in value:
                problems.append(f"{name} 含开发/占位特征 '{marker}'")
                break
    if problems:
        raise SystemExit("render_config: 生产守卫失败:\n  - " + "\n  - ".join(problems))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", default=".env", help="env 文件路径（默认 ./.env）")
    parser.add_argument("--root", default=".", help="部署根目录（默认 .）")
    parser.add_argument("--check", action="store_true", help="只比对不写；漂移 exit 1")
    parser.add_argument("--require-production", action="store_true", help="启用生产占位值守卫")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    values = parse_env(os.path.abspath(args.env))
    if args.require_production:
        check_production_guards(values)

    def repo(relative):
        return os.path.join(root, relative)

    rendered_targets = [
        ("infra/synapse/homeserver.yaml.template", "data/synapse/homeserver.yaml"),
        ("infra/nginx/nginx.conf.template", "data/nginx/nginx.conf"),
        ("infra/element/config.json.template", "data/element/config.json"),
    ]
    drift = []
    changed = []
    for src_rel, dest_rel in rendered_targets:
        src, dest = repo(src_rel), repo(dest_rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(src, encoding="utf-8") as handle:
            content = render(handle.read(), values)
        if dest_rel.endswith("config.json"):
            json.loads(content)  # 渲染产物必须是合法 JSON（失败即硬失败）。
        if args.check:
            try:
                with open(dest, encoding="utf-8") as handle:
                    if handle.read() != content:
                        drift.append(dest_rel)
            except FileNotFoundError:
                drift.append(dest_rel + " (missing)")
        else:
            if write_in_place(dest, content):
                changed.append(dest_rel)

    sygnal_dest = repo("data/sygnal/sygnal.yaml")
    if args.check:
        if not os.path.exists(sygnal_dest):
            drift.append("data/sygnal/sygnal.yaml (missing)")
    else:
        os.makedirs(os.path.dirname(sygnal_dest), exist_ok=True)
        if copy_if_absent(repo("infra/sygnal/sygnal.yaml.template"), sygnal_dest):
            changed.append("data/sygnal/sygnal.yaml (first render)")
        nooppushkin = repo("data/sygnal/nooppushkin.py")
        if copy_if_absent(repo("infra/sygnal/nooppushkin.py"), nooppushkin):
            changed.append("data/sygnal/nooppushkin.py (copied)")
        else:
            with open(repo("infra/sygnal/nooppushkin.py"), encoding="utf-8") as handle:
                noop_content = handle.read()
            if write_in_place(nooppushkin, noop_content):
                changed.append("data/sygnal/nooppushkin.py (updated)")

    if args.check:
        if drift:
            print("DRIFT DETECTED（与仓库模板渲染结果不一致）:")
            for item in drift:
                print(f"  - {item}")
            raise SystemExit(1)
        print("NO DRIFT: 全部配置与仓库模板一致")
        return

    if changed:
        print("已更新（原地写，bind-mount inode 保持；nginx 变更后执行 "
              "`docker compose exec gateway nginx -t && nginx -s reload`）:")
        for item in changed:
            print(f"  - {item}")
    else:
        print("NO CHANGE: 全部配置已是模板渲染结果（幂等）")


if __name__ == "__main__":
    main()
