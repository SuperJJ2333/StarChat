import {walletAccessPanel} from './admin-wallet-access.js?v=20260910-completion';

export function supportOrderAccessPanel(api,{onReauthenticate,...options}={}) {
  const scoped={...api,getWalletAccess:()=>api.getSupportOrderAccess(),verifyWalletAccess:proof=>api.verifySupportOrderAccess(proof)};
  return walletAccessPanel(scoped,{...options,title:'客服充值与提现订单',scope:'support-orders',renderSetup:(gateway,onChanged,state)=>{
    if(state.auth_mode==='totp'){
      const message=document.createElement('p');message.className='admin-audit-note';
      message.textContent='当前策略要求动态验证码。请先在官方 APP 使用同一客服账号开通 TOTP，再点击“配置完成，检查验证状态”。';
      return message;
    }
    const form=document.createElement('form');form.className='admin-command-form';
    const fields={};
    for(const [name,label] of [['login_password','后台登录密码'],['new_operation_password','设置操作密码']]){
      const wrapper=document.createElement('label');wrapper.textContent=label;
      const input=document.createElement('input');input.type='password';input.name=name;input.required=true;input.autocomplete='off';input.className='admin-filter';fields[name]=input;wrapper.append(input);form.append(wrapper);
    }
    const submit=document.createElement('button');submit.type='submit';submit.className='admin-primary';submit.textContent='设置订单操作密码';
    const status=document.createElement('p');status.setAttribute('role','status');
    const reauthenticate=document.createElement('button');reauthenticate.type='button';reauthenticate.className='admin-secondary';reauthenticate.textContent='重新验证登录身份';reauthenticate.hidden=true;
    reauthenticate.addEventListener('click',async()=>{reauthenticate.disabled=true;try{status.textContent=await onReauthenticate?.()?'身份已验证，请重新填写密码后提交。':'未完成验证。';}finally{reauthenticate.disabled=false;}});
    form.append(submit,status,reauthenticate);
    form.addEventListener('submit',async event=>{
      event.preventDefault();if(submit.disabled)return;submit.disabled=true;status.textContent='正在设置…';
      const body=Object.fromEntries(Object.entries(fields).map(([name,input])=>{const value=input.value;input.value='';return [name,value];}));
      try {await gateway.setSupportOrderPassword(body,{idempotencyKey:crypto.randomUUID()});status.textContent='操作密码已设置，请验证后进入。';await onChanged();}
      catch(error){status.textContent=error.message??'设置未确认，请刷新状态后重试。';reauthenticate.hidden=error.code!=='RECENT_LOGIN_REQUIRED';}
      finally{for(const name of Object.keys(body))delete body[name];submit.disabled=false;}
    });
    return form;
  }});
}
