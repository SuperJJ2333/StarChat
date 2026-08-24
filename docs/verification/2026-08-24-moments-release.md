# 朋友圈修复发布记录

日期：2026-08-24

## 公网 Docker

- SSH 目标：`207.56.8.8:23421`，部署目录 `/opt/starchat`。
- 后端归档：`fd1edb0-backend.tar`。
- 归档 SHA-256：`43B6CFA238387C64445FB7B64780F7F6A127B3F1125574A10B0C6F95D57123F7`，本地与公网一致。
- `business-api` 与 `business-worker` 已重建、强制重建容器并处于 healthy。
- Alembic：`0026_moment_cover_media (head)`。
- Ready：`https://liuhetong888.com/api/v1/health/ready` 返回 HTTP 200 和 database ready。

## Android 模拟器

- 最终提交：`ff7ba63`（包含选图即时本地预览）。
- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`。
- 最终 APK 字节数：242,564,476。
- 最终 SHA-256：`0520DEC54E0A7A541FA8F45CEE0319ECE7599EAD233F342EC576C6E1223CDB5E`。
- `emulator-5554` 覆盖安装成功，设备端 base.apk 哈希与本地一致，MainActivity 启动成功。
- ADB 同时列出 `127.0.0.1:5555`，但它与 `emulator-5554` 的 Android ID、应用 PID 和 activity 完全相同，确认是同一模拟器的重复连接入口；环境中没有独立的 `emulator-5556`。
- 运行态检查：单信息流、自定义头像、即时点赞/数字、评论输入框、封面放大、“换封面”和系统相册入口均已复现。
- 为避免污染现有账号，未提交测试评论、未选择图片覆盖现有封面；评论提交与封面持久化由通过的集成/widget 测试验证。

## 产物

- `docs/verification/artifacts/2026-08-24/moments-identity-interaction-repair/fd1edb0-backend.tar`
- `docs/verification/artifacts/2026-08-24/moments-identity-interaction-repair/emulator-moments-before.png`
- `docs/verification/artifacts/2026-08-24/moments-identity-interaction-repair/emulator-moments-unliked.png`

## 同步状态

本地 main 已提交；origin push 因当前 GitHub 账号无仓库写权限返回 403，尚未完成。公网 Docker 和模拟器部署不受此权限问题影响。
