// Explicitly isolated interaction demo. No API requests or real financial writes.
import {createAdminShell} from './admin-dashboard.js';
import {rechargePanel} from './admin-recharge-panel.js?v=direct-12';
import {supportPayoutPanel} from './admin-support-payout-panel.js?v=direct-12';
const admin=new URLSearchParams(location.search).get('role')==='admin';
let offline=false,sequence=22;const actor={id:'demo-staff-'+crypto.randomUUID(),display_name:'客服小畅'};
const expires=()=>new Date(Date.now()+3600000).toISOString();
let orders=[
 {id:'RC-20260923-0018',user_id:'demo-user-1',user_display_name:'林小满',user_chat_id:'linxiaoman',amount_usdt:'100.000000',fx_rate:'6.983500',status:'SUBMITTED',processing_stage:'SUBMITTED',expires_at:expires()},
 {id:'RC-20260923-0017',user_id:'demo-user-2',user_display_name:'陈南',user_chat_id:'chennan26',amount_usdt:'50.000000',fx_rate:'6.983500',status:'SUBMITTED',processing_stage:'PAYMENT_VERIFIED',payment_verified:true,actual_received_usdt:'50.000000',expires_at:expires()},
 {id:'RC-20260923-0016',user_id:'demo-user-3',user_display_name:'许知远',user_chat_id:'xuzhiyuan',amount_usdt:'200.000000',fx_rate:'6.983500',status:'SUBMITTED',processing_stage:'CLAIMED',claimed_by:'demo-another-staff',claim_expires_at:expires(),expires_at:expires()}
];
const history=[{id:'RC-20260923-0012',user_display_name:'周末',user_chat_id:'zhoumo',amount_usdt:'80.000000',status:'CREDITED',binding_state:'REGISTERED',final_caibi_amount:'558.68'}];
const payouts=[{id:'WD-20260923-0007',user_id:'demo-user',funding_asset:'CAIBI',funding_amount:'140.00',amount:'20.000000',final_receive:'20.000000',status:'REQUESTED',processing_stage:'SUBMITTED',expires_at:expires()}];
const events=Array.from({length:22},(_,i)=>({id:'history-'+(i+1),event_type:'recharge.submitted',sequence:i+1}));
const respond=async value=>{await new Promise(r=>setTimeout(r,450));if(offline)throw Object.assign(Error('连接暂时中断，请检查网络后重试'),{status:503});return structuredClone(value);};
const overview={registered_users:1286,online_customers:83,pending_withdrawals:1,today_point_volume:'5280.00',registration_trend:[],point_supply:{total:'286450.00',issued:'300000.00',returned:'13550.00',holdings:'285990.50',platform_fees:'459.50',balanced:true}};
const api={
 getOverview:()=>respond(overview),getPointIssuance:()=>respond({items:[]}),
 getFxRate:()=>respond({rate:'6.983500',stale:false,fetched_at:new Date().toISOString(),disclaimer:'1 USDT 暂按 1 USD 估算 · 仅供参考，实际到账以客服最终结算为准'}),
 getReserveValuation:()=>respond({caibi_face:'286450.00',caibi_reference_usdt:'41018.12',usdt_obligation:'2386.50',approved_unpaid_usdt:'380.00'}),
 getRechargePending:filters=>respond({items:orders.filter(o=>o.status==='SUBMITTED'&&(filters?.scope!=='mine'||o.claimed_by===actor.id)),next_cursor:null}),
 listRechargeRequests:()=>respond({items:history,next_cursor:null}),
 claimRecharge:async id=>{await respond(null);const o=orders.find(x=>x.id===id);if(o.claimed_by&&o.claimed_by!==actor.id)throw Error('该请求已由其他客服处理，请刷新列表');Object.assign(o,{claimed_by:actor.id,claim_expires_at:expires(),claim_token:'demo-claim-'+id,processing_stage:o.payment_verified?'PAYMENT_VERIFIED':'CLAIMED'});return structuredClone(o);},
 heartbeatRecharge:id=>respond(orders.find(o=>o.id===id)),
 prepareRechargeSettlement:async(id,body)=>{await respond(null);const o=orders.find(x=>x.id===id);o.binding_adjustment_id='demo-adjustment';o.binding_final_rate=body.final_rate;o.settlement_status='SUBMITTED';o.settlement_submitted_by=actor.id;o.settlement_approval_required=false;o.binding_final_caibi_amount=(Number(o.actual_received_usdt)*Number(body.final_rate)).toFixed(2);return {...o};},
 executeRechargeSettlement:async id=>{await respond(null);const o=orders.find(x=>x.id===id);if(!o.payment_verified)throw Error('尚未核验到账');if(o.status!=='CREDITED'){Object.assign(o,{status:'CREDITED',binding_state:'REGISTERED',final_caibi_amount:o.binding_final_caibi_amount});history.unshift({...o});}return {...o};},
 rejectRecharge:async(id,body)=>{await respond(null);const o=orders.find(x=>x.id===id);o.status='REJECTED';history.unshift({...o,reason:body.reason});return {status:'REJECTED'};},
 getRechargeTimeline:id=>respond({request_id:id,status:'SUBMITTED',items:[{action:'用户提交充值请求',created_at:new Date(Date.now()-600000).toISOString(),reason:'申请已保存，等待钱包到账核验'},{action:'系统正在核验到账',created_at:new Date().toISOString(),reason:'请以系统核验结果和最终结算回执为准'}]}),
 getRechargeReviewQueue:()=>respond({items:[],next_cursor:null}),getRechargeDirectory:()=>respond({items:[]}),
 listTransferIntents:()=>respond({items:[]}),
 getSupportPayouts:()=>respond({items:payouts,next_cursor:null}),
 supportPayoutCommand:async(id,action)=>{await respond(null);const o=payouts.find(x=>x.id===id);if(action==='claim'){Object.assign(o,{claimed_by:actor.id,claim_token:'demo-payout',claim_expires_at:expires(),processing_stage:'CLAIMED'});return structuredClone(o);}throw Error('演示模式不会执行真实出款');},
 getOrderEvents:filters=>respond({items:events.filter(e=>e.sequence>Number(filters.cursor??0)).slice(0,100),next_cursor:String(sequence)})
};
let child;const content=document.createElement('section');
const showRecharge=()=>{child?.dispose?.();child=rechargePanel(api,{actor,canManage:admin,canReview:admin,canApprove:admin,onOpenPayout:showPayout});content.replaceChildren(child);};
const showPayout=()=>{child?.dispose?.();child=supportPayoutPanel(api,{actor,onBack:showRecharge});content.replaceChildren(child);};
content.refresh=()=>child?.refresh?.();content.refreshOrders=()=>child?.refreshOrders?.();content.dispose=()=>child?.dispose?.();
const context={actor,permissions:admin?['*']:['admin.overview.read','admin.finance.read'],overview,modules:{}};
const shell=createAdminShell({context,api,modules:[['充值与提现请求','处理充值、核对提现','recharge','admin.finance.read']],renderModule:()=>{showRecharge();return content;},onLogout:()=>location.reload()});
const controls=document.createElement('div');controls.className='admin-demo-controls';const hint=document.createElement('p');hint.textContent='交互演示 · 全部为模拟数据，不连接生产、不真实出款';controls.append(hint);
function control(label,run){const b=document.createElement('button');b.className='admin-secondary';b.textContent=label;b.addEventListener('click',run);controls.append(b);}
control('模拟新充值',()=>{const id='RC-DEMO-'+(++sequence);orders.unshift({...orders[0],id,user_display_name:'新用户',user_chat_id:'demo'+sequence,claimed_by:null,payment_verified:false,processing_stage:'SUBMITTED',expires_at:expires()});events.push({id:'new-'+sequence,sequence,event_type:'recharge.submitted'});void shell.querySelector('.admin-order-notifications').refresh();});
control('模拟新提现',()=>{payouts.unshift({...payouts[0],id:'WD-DEMO-'+(sequence+1),claimed_by:null,processing_stage:'SUBMITTED'});events.push({id:'new-'+(++sequence),sequence,event_type:'wallet.manual_payout_request'});void shell.querySelector('.admin-order-notifications').refresh();});
control('模拟网络故障',()=>{offline=true;void content.refresh?.();void shell.querySelector('.admin-order-notifications').refresh();});
control('恢复网络',()=>{offline=false;void content.refresh?.();void shell.querySelector('.admin-order-notifications').refresh();});
control(admin?'查看客服视角':'查看管理员工具',()=>{location.search=admin?'':'?role=admin';});
const app=document.querySelector('#app');app.append(shell);shell.querySelector('.admin-main').prepend(controls);shell.querySelector('[data-module="recharge"]').click();
addEventListener('pagehide',()=>shell.dispose());
