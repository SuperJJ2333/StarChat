"""Compatible rollback only: refuse all affected financial HTTP mutations."""
import json
from uuid import uuid4
PREFIXES=(
 '/api/v1/admin/support-orders/payouts',
 '/api/v1/manual/payouts','/api/v1/manual/payout-quotes',
 '/api/v1/wallet/manual/payouts','/api/v1/wallet/manual/payout-reconciliations',
 '/api/v1/wallet/manual/admin/payouts',
 '/api/v1/recharge',
)
class FinanceWriteFence:
    def __init__(self, app):self.app=app
    async def __call__(self,scope,receive,send):
        path=scope.get('path','')
        if scope.get('type')=='http' and scope.get('method','').upper() not in {'GET','HEAD','OPTIONS'} and any(path==p or path.startswith(p+'/') for p in PREFIXES):
            body=json.dumps({'error':{'code':'SUPPORT_FINANCE_RELEASE_WRITE_FENCE','message':'资金处理暂时关闭，请稍后重试；原订单和冻结保留。','trace_id':uuid4().hex,'fields':{}}},ensure_ascii=False).encode('utf-8')
            await send({'type':'http.response.start','status':503,'headers':[(b'content-type',b'application/json; charset=utf-8'),(b'cache-control',b'no-store')]})
            await send({'type':'http.response.body','body':body});return
        await self.app(scope,receive,send)
FACTORY_SUFFIX='''
# Dedicated compatibility rollback: affected writes fail closed before routing.
from app.release_finance_write_fence import FinanceWriteFence as _ReleaseFinanceWriteFence
_release_original_create_app = create_app
def create_app(*args, **kwargs):
    application = _release_original_create_app(*args, **kwargs)
    application.add_middleware(_ReleaseFinanceWriteFence)
    return application
'''
