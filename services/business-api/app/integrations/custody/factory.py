"""托管 provider 工厂与环境门禁（审计 A04）。

沙箱（开发/测试）：进程内 SandboxCustodyProvider——订单状态在内存字典，
生成沙箱地址/交易结果，仅用于功能开发与隔离测试。

生产门禁（红线）：
- 生产环境钱包资金功能**绝不**回退沙箱 provider 或开发密钥；
- 当前仓库尚未接入真实托管商——生产模式返回 (None, "unconfigured")，
  由路由层关闭资金入口（503 WALLET_CUSTODY_NOT_CONFIGURED），余额/
  历史等只读接口照常；
- 真实 provider 接入契约（接入时必须全部满足）：
  1. submit_withdrawal/get_withdrawal/create_deposit_address 的**持久化**
     实现（外部订单状态不得存进程内存——API 与 worker 对同一订单结果
     一致、重启可恢复）；
  2. 回调签名验证与事件重放语义（幂等 event_id + 业务订单全局唯一 ID）；
  3. 余额/对账查询接口（reconciliation 用）；
  4. 密钥经环境变量注入（列入 Settings 生产必填清单），支持轮换；
  5. 隔离环境端到端验收通过后才允许生产接线。
  在该契约完成前，本工厂不自行选择任何厂商。
"""
from typing import Literal

from app.core.config import Settings
from app.integrations.custody.sandbox import SandboxCustodyProvider

ProviderMode = Literal["sandbox", "unconfigured"]


def create_custody_provider(settings: Settings):
    """返回 (provider, mode)。生产未接真实托管时 provider 为 None。"""
    if settings.environment != "production":
        return (
            SandboxCustodyProvider(
                secret=settings.wallet_webhook_secret
                or "development-wallet-webhook-secret"
            ),
            "sandbox",
        )
    if settings.wallet_custody_provider != "production":
        # 生产显式选择沙箱 = 配置错误：拒绝提供资金能力（fail closed）。
        return None, "unconfigured"
    # 生产 + production provider：真实实现尚未接入（见模块契约清单）。
    return None, "unconfigured"
