# Android 2235 安装包交付

## 恢复入口

- 授权：2026-10-25用户要求更新Android安装包，暂不推送更新提醒；已回复“交付APK，并更新官网下载入口”。允许该范围上传/下载切换，更新提醒、最低版本和iOS保持不变。
- 计划：[Android2235](../../superpowers/plans/2026-10-25-android2235-release.md)。基线9fae702508d07193bd05d13822be3d91806ae16d，包含29384fed消息顺序与0e9a760b缓存修复。
- 工作树C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat，分支codex/android2235-release-20261025；父任务独占版本对、上述计划、本记录/报告及current-state新条目。
- 当前状态：0.4.66+2235正式ARM64包与官网下载交付完成，构建/发布两组规格→质量审查PASS，后验PASS。下一步收集ARM64真机覆盖升级和群聊反馈；不自动开启提醒。APK源码固定52bbd8c5751d250d49c643c309e270ae496feb59，后续workflow元数据提交5d7d4010不追溯改变工件身份。

## 验收台账

| ID | 要求 | 状态 |
| --- | --- | --- |
| A1 | 最新修复源码与递增版本 | PASS；1721共享输入仅版本对不同，版本影响补验通过 |
| A2 | 正式ARM64、固定75b31签名、常规重建 | 20步PASS，规格与质量PASS |
| A3 | 不推送更新提醒、保留iOS | 下载切换PASS，10设置不变/数据库零写入，iOS及35容器保持 |
| A4 | 可安装包与可复核交接 | APK及官网下载入口已交付；真实ARM64覆盖与运行尚未验证 |

## 版本与证据

实际版本0.4.66+2235；fetch/refs/CI已核对，无运行中构建占用2235。历史CI失败不算通过。固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff；私钥留本机受保护目录，不进入Git或服务器。

证据根：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/android2235-release/。原主树516状态（含509删除）和全部worktree清单已保存。C盘空闲26.1GiB，D盘65.2GiB；仅发现在线模拟器5556，不推断其ARM64正式包兼容性。

## 阶段与交接

构建UTC 07:13:54至07:20:43（约6分49秒，见arm64-final/receipt.json）。最终SHA256 0e438befc0d27773333002720adf47315f54cb5b12113b622f9c9bebe570a434，73,655,386字节。构建前后2158输入一致；DEX/manifest语义一致、274原生/资产条目一致。与旧2233同体积但libapp与HTML内容不同，已排除旧包误用。

mobile首次门禁1失败（iOS未来流水线仍写2234），发现时本地构建已完成，但未线上切换。版本元数据同步后404通过/1 Ruby跳过；16运行版本测试、37Android边界、3版本契约及analyze通过。复用上轮6410PASS及诊断开关9PASS，不把历史CI、Ruby或真机缺口写成通过。原IPA2234与Android2233旧文件保持；不发布更新提醒。

官网切换UTC07:56:46，后验08:03:37，回执见distribution/switch.json、postcheck.json。已上传不可变APK并核对SHA，CDN精确路由Deployed/HEAD200/CORS通过；只切两静态文件和latest-arm64。数据库10设置、iOS清单、其他ABI别名、S3策略和35容器身份保持。备份与下载地址见[验收报告](../../verification/2026-10-25-android2235-release.md)。不重复构建或重放publish；后续提醒发布需要用户另行授权。
