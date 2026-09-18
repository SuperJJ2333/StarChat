# one-off 运维脚本（非构建产物）

这些脚本是**一次性/手动**的运维辅助工具，不属于构建、门禁或发布链路，
不被任何代码引用。它们此前散落在仓库根目录（`tmp_remote_*.py|plist`），
违反 `AGENTS.md`「根目录不得存放临时/验证产物」的约定，故集中到此目录。

| 文件 | 用途 |
| --- | --- |
| `remote_admin.py` | 远程管理后台相关的一次性排查/修补脚本 |
| `remote_app_update.py` | App 更新清单（版本/下载页）的一次性生成与推送辅助 |
| `remote_settings_service.py` | 运行时设置服务的一次性排查脚本 |
| `remote_manifest.plist` | iOS OTA 安装清单模板（配合 `remote_app_update.py`） |

约定：

- 脚本内的密钥一律从环境变量或服务端配置读取，**不得**在此写入任何真实
  凭据、令牌、恢复密钥或钱包信息；
- 生产发布请走 `docs/runbooks/admin-production-workflow.md` 与
  `docs/runbooks/mobile-delivery-workflow.md`，不要把这里的脚本当作流程入口；
- 新增同类脚本请直接放在本目录，不要再落到仓库根目录。
