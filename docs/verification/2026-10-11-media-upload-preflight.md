# R8a 媒体发送前上限预检

执行已批准 IM 可靠性计划 R8a。root 负责 MediaMessageService、新只读能力接口和测试；matrix_e2ee_client 的单一 owner 在独立提交补齐 SDK 与房间 lease 接线，避免并行修改。客户端单文件上限 100MiB；已知 Matrix 代理上限默认 100MiB，可由 `CHATFLOW_MATRIX_PROXY_UPLOAD_LIMIT_BYTES` 随发布配置，取服务器 `m.upload.size` 与这两者的最小值。未修改服务器上传容量。

普通文件/语音在整文件读取前获取 SDK 缓存的服务器限制；查询失败/5秒未完成在读取前失败，服务器不提供字段时仍受已知客户端/代理限制。视频先走原转码链，仅按最终产物大小预检，在生成海报和 readAsBytes 前拒绝过大产物。排队后重验文件 stat，读取后再验实际长度，SDK 的最终容量守卫保持。原 txid、发送加密格式和业务接口未变；SDK/lease 对账号撤销和迟到结果作身份检查。

本子项减少明确超限文件的无用内存和加密工作，未解决所有合法附件的峰值，也未实现活动字节预算或进程重启恢复。其他相册/表情媒体入口仍由各自策略及 SDK 守卫负责；100MiB 客户端上限不表示生产服务器可接受该大小。

证据目录：`artifacts/2026-10-11/im-reliability-implementation/`。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 64MiB实际稀疏普通文件、50MiB服务器，File读取spy | 原行为2 RED，修后读取0/上传0 | r8a-red-behavior.txt |
| SDK/真实room lease能力、撤销后的迟到回包 | 原4 RED，接线后4 GREEN | r8a-sdk-red.txt、r8a-sdk-green.txt |
| effective min、未知/失败、等于边界、转码16MiB对8/20MiB两限制 | 10 PASS | r8a-boundaries-final.txt |
| 最终 SDK4+预检10+文件视频12 | 26 PASS，exit0 | r8a-sdk-green.txt |
| 原相邻相机/媒体/视频及最初预检组合 | 42 PASS，exit0；与上行有重叠，不相加 | r8a-green.txt |
| 最终生产3文件/测试2文件 analyze | 无问题，exit0 | r8a-analyze-final.txt |

保留环境/夹具失败：首次spy未实现path导致1项设置错误（另一项为真实行为RED）；修spy后两项均以错误放行复现。视频spy第一次delete返回类型错误、第二次absolute在IOOverride中重入使转码夹具错误；修测试代理后10项通过，未更改转码生产逻辑。首次analyze有一项多余import，移除后最终通过。各失败日志保留，不把它们写成产品RED或隐藏。

Flutter/Powershell/依赖锁沿用主任务，pub.dev offline enforce-lockfile；夹具仅位于docs/verification/artifacts并按创建的临时目录清理。实施约11:32–11:45 UTC+08，精确独立步骤起止未全记录。后续独立规格→质量审查通过，最终预检/SDK两文件14项复跑通过（review-r8a-focused.txt），包括最终txid断言；共享门禁、成品及真机验证待完成，本报告不声明已分发到手机。
