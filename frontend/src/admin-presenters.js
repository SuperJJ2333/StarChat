import {formatBeijingTime, reasonLabel, statusLabel} from './admin-formatters.js';

const display=value=>value===undefined||value===null||value===''?'—':String(value);
const user=item=>display(item.username||item.user_id);
const users=item=>[formatBeijingTime(item.created_at),display(item.username),display(item.nickname),item.email_verified_at?`已验证 · ${formatBeijingTime(item.email_verified_at)}`:'未验证',statusLabel(item.status)];
const presenters={
  ledger:item=>[display(item.transaction_id),formatBeijingTime(item.time),user(item),item.type==='ledger.post'?'账本记账':reasonLabel(item.type),display(item.amount),reasonLabel(item.reason_code)],
  wallet:item=>[display(item.id),user(item),display(item.amount),display(item.address),statusLabel(item.status)],
  finance:item=>[display(item.id),user(item),display(item.amount),statusLabel(item.status),reasonLabel(item.reason_code),formatBeijingTime(item.created_at)],
  'support-role':item=>[display(item.username),statusLabel(item.role),formatBeijingTime(item.assigned_at)],
  ads:item=>[display(item.id),display(item.advertiser_name),display(item.text),formatBeijingTime(item.created_at),statusLabel(item.status)],
  online:item=>[display(item.username),statusLabel(item.status),formatBeijingTime(item.last_seen_at)],
  notice:item=>[display(item.title),statusLabel(item.audience),formatBeijingTime(item.publish_at),statusLabel(item.status)],
  analytics:users,security:users,
};
export function presentModuleRows(key,items=[]) {
  return presenters[key]&&Array.isArray(items)?items.map(presenters[key]):[];
}
