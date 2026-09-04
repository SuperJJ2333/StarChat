"""getui-bridge 配置：密钥只来自环境变量（服务器 .env），绝不入仓库。"""
from pydantic_settings import BaseSettings


class BridgeSettings(BaseSettings):
    # 个推应用标识。AppID 为公开信息；AppKey/签名密钥为服务端机密。
    getui_app_id: str = ""
    getui_app_key: str = ""

    # v2 鉴权 sign = sha256(appkey + timestamp + secret)。
    # 官方经典控制台该密钥为 MasterSecret；新版控制台签发 AppSecret——
    # 两者算法相同，仅密钥值不同（部署时以真实凭据实测为准）。
    getui_sign_secret: str = ""

    getui_rest_base: str = "https://restapi.getui.com"

    # 只处理该 Matrix pusher app_id 的设备。
    matrix_app_id: str = "com.liuhetong.mobile.getui"

    # 通知有效期（毫秒）：过期不投递（settings.ttl）。
    notify_ttl_ms: int = 300_000

    # 同 CID 最小下发间隔（毫秒）：风暴收敛。
    rate_limit_ms: int = 1_500

    class Config:
        env_file = None
