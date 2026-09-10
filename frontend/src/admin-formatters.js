// Display only. Absolute server timestamps stay UTC; calendar filters are Beijing time.
const calendar = new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
function validCalendar(year,month,day,hour=0,minute=0,second=0){
  const date=new Date(Date.UTC(+year,+month-1,+day,+hour,+minute,+second));
  return date.getUTCFullYear()===+year&&date.getUTCMonth()===+month-1&&date.getUTCDate()===+day&&date.getUTCHours()===+hour&&date.getUTCMinutes()===+minute&&date.getUTCSeconds()===+second;
}
export function formatBeijingTime(value){
  if(value===null||value===undefined||value==='')return '—';
  let timestamp=value;
  if(typeof value==='string'){
    const match=value.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$/);
    if(!match||!validCalendar(match[1],match[2],match[3],match[4]??0,match[5]??0,match[6]??0))return '—';
    timestamp=match[4]===undefined?`${value}T00:00:00+08:00`:value.replace(' ','T')+(match[7]?'':'Z');
  }else if(!(value instanceof Date)&&!(typeof value==='number'&&Number.isFinite(value)))return '—';
  const date=new Date(timestamp);if(!Number.isFinite(date.getTime()))return '—';
  const parts=Object.fromEntries(calendar.formatToParts(date).map(p=>[p.type,p.value]));
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second}`;
}
export function parseBeijingInput(value){
  if(value===null||value===undefined||value==='')return undefined;
  const match=String(value).match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/);
  if(!match||!validCalendar(match[1],match[2],match[3],match[4],match[5],match[6]??0))return NaN;
  return Date.parse(`${value}+08:00`);
}
const reasons={
  SUPPORT_CAIBI_GRANT:'客服点钻发放',SUPPORT_GRANT:'客服点钻发放',SUPPORT_ADJUSTMENT:'客服点钻调整',
  ADMIN_ADJUSTMENT:'管理员调整',ADJUSTMENT:'点钻调整',ADJUSTMENT_REVIEW:'点钻调整审核',
  INITIAL_ISSUANCE:'初始发行',INITIAL_GRANT:'初始发放',ISSUANCE:'点钻发行',ISSUE:'点钻发行',
  RECOVERY:'点钻回收',RETURN:'点钻回收',REVERSAL:'交易冲正',CORRECTION:'差错更正',
  CAIBI_ISSUANCE:'点钻发行',CAIBI_RECOVERY:'点钻回收',LEDGER_REVERSAL:'账本冲正',
  MANUAL_RESERVE_PUBLISHED:'人工钱包储备核验',TRANSFER:'用户转账',TRANSFER_FEE:'转账手续费',
  RED_PACKET_SEND:'发送红包',RED_PACKET_CLAIM:'领取红包',RED_PACKET_REFUND:'红包退回',
  SPAM:'垃圾信息',HARASSMENT:'骚扰他人',FRAUD:'涉嫌欺诈',ABUSE:'违规使用',
  SECURITY_RISK:'安全风险',POLICY_VIOLATION:'违反平台规则',BAN_REVOKE:'解除封禁',
  ADMIN_BAN:'管理员封禁',OTHER:'其他违规',MANUAL_ADJUSTMENT:'人工调整',
};
export function reasonLabel(value){return value?reasons[value]??'其他原因（待补充说明）':'—';}
const statuses={ACTIVE:'正常',BANNED:'已封禁',PENDING:'待处理',PENDING_EMAIL:'待验证邮箱',PENDING_EMAIL_VERIFICATION:'待验证邮箱',DISABLED:'已停用',DELETED:'已注销',SUSPENDED:'已限制',
  REQUESTED:'待审核',POSTED:'已入账',APPROVED:'已批准',REJECTED:'已拒绝',DRAFT:'草稿',PUBLISHED:'已发布',
  SUPPORT_AGENT:'客服',SYSTEM_ADMIN:'系统管理员',FINANCE_ADMIN:'财务管理员',FINANCE_REVIEWER:'财务审核员',USER:'用户',
  SUBMITTED:'已提交',EXECUTED:'已执行',PAID:'已支付',FAILED:'失败',COMPLETED:'已完成',CANCELLED:'已取消',
  CLAIMED:'已领取',UNKNOWN:'待核实',REVIEW:'待核验',CONFIRMED:'已确认',CREDITED:'已入账',
  RETRACTED:'已撤回',SCHEDULED:'待发布',EXPIRED:'已过期',REVOKED:'已撤销',ALL:'全部用户'};
export function statusLabel(value){if(!value)return '—';return statuses[value]??(/^[A-Z][A-Z0-9_]*$/.test(value)?'其他状态':String(value));}
export function actorLabel(item={}){
  if(typeof item.actor_username==='string'&&item.actor_username)return item.actor_username;
  if(typeof item.actor_display_name==='string'&&item.actor_display_name)return item.actor_display_name;
  if(['system','SYSTEM','manual-reserve-monitor','wallet-worker'].includes(item.actor_id))return '系统操作';
  return '未关联畅聊号';
}
