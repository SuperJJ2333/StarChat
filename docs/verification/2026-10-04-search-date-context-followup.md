# 旧日期定位与消息上下文：调查与回归测试中

用户在安装0.4.31+2200后确认旧媒体缩略图与点击正常，随后报告选择十天前日期未找到消息、关键词跳转只有单条气泡且不可上下滚动。本报告仅跟踪后两项，沿[批准计划](../superpowers/plans/2026-10-04-search-date-context-followup.md)与[任务](../workflow/tasks/2026-10-04-search-date-context-followup.md)。2200没有包含本轮尚未实现的修复。

源码调查基线574ef30：SDK application capability读取到持久合法anchor后直接创建单条fragment并返回，没有请求上下文，且无分页token。日期路径退出搜索立即定位，搜索route完成清理又取消同一SDK context generation；实际延迟读取RED仍在准备，尚不能说已复现或修复。完整来源/调用链见[调查](artifacts/2026-10-04/search-date-context-followup/investigation.md)。

最小拟修复保持本地日期索引权威，明确搜索到房间定位的生命周期移交。合法持久anchor在线时有界请求真实SDK上下文，读取真正前后token；离线/暂时网络故障保留合法anchor，不伪造token、不允许权限拒绝/来源异常/取消绕过。无密钥、原生存储或恢复契约变化。实现、真实RED/GREEN、有序规格/质量安全审查、新候选门禁与设备交付均尚待。

前序iOS run37209352829绑定574ef30全部3job SUCCESS，仅证明前序媒体2200与不变密钥输入；不能当新上下文源码通过。新driver仅准备0.4.32+2201暂定参数，未修改源码版本、冻结、构建或安装；冻结前重新核号。整库verify仍须环境预检，不引入秘密，不把缺环境跳过计为通过。