import {createStaffActivationApi} from './admin-staff-activation.js';
function node(tag, className, text) {
  const item = document.createElement(tag); item.className = className || '';
  if (text) item.textContent = text;
  return item;
}
export function loginView(api, onSuccess) {
  const page = node('main', 'admin-login-page');
  const brand = node('header', 'admin-login-brand');
  const mark=node('img','admin-login-mark');mark.src='/assets/branding/admin-logo.png';mark.alt='畅聊';
  brand.append(mark, node('p', 'admin-login-eyebrow', 'CHATFLOW'), node('h1', '', '畅聊管理后台'), node('p', 'admin-login-intro', '让每一次管理，都清晰有序。'));
  const card = node('section', 'admin-card admin-login-card');
  card.append(node('p', 'admin-login-kicker', '管理员入口'), node('h2', '', '欢迎回来'), node('p', 'admin-audit-note', '登录保留 48 小时；新设备登录后，旧设备将退出。'));
  const form = node('form', 'admin-login-form');
  function field(name, title, type, autocomplete) {
    const label = node('label', 'admin-login-label', title), input = node('input', 'admin-filter');
    input.name = name; input.type = type; input.autocomplete = autocomplete; input.required = true;
    input.setAttribute('aria-label', title); input.placeholder = title;
    label.append(input); return {label, input};
  }
  const username = field('username', '管理员账号', 'text', 'username');
  username.input.autocapitalize = 'none'; username.input.spellcheck = false;
  const password = field('password', '登录密码', 'password', 'current-password');
  const row = node('div', 'admin-password-row');
  const toggle = node('button', 'admin-password-toggle', '显示'); toggle.type = 'button';
  toggle.setAttribute('aria-label', '显示密码'); toggle.setAttribute('aria-pressed', 'false');
  toggle.addEventListener('click', () => { const show = password.input.type === 'password'; password.input.type = show ? 'text' : 'password'; toggle.textContent = show ? '隐藏' : '显示'; toggle.setAttribute('aria-label', show ? '隐藏密码' : '显示密码'); toggle.setAttribute('aria-pressed', String(show)); });
  row.append(password.input, toggle); password.label.append(row);
  const captcha = field('captcha_answer', '图形验证码', 'text', 'off');
  captcha.input.maxLength = 6; captcha.input.spellcheck = false; captcha.input.autocapitalize = 'characters';
  const pictureRow = node('div', 'admin-captcha-row'), picture = node('img', 'admin-captcha-image');
  picture.alt = '六位图形验证码，不区分大小写'; picture.width = 216; picture.height = 64; picture.hidden = true;
  const refresh = node('button', 'admin-captcha-refresh', '换一张'); refresh.type = 'button';
  const challengeStatus = node('p', 'admin-audit-note'); challengeStatus.setAttribute('role', 'status');
  pictureRow.append(picture, refresh);
  const submit = node('button', 'admin-primary', '登录'); submit.type = 'submit'; submit.disabled = true;
  const status = node('p', 'admin-login-status'); status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
  const activationCode=field('activation_code','绑定手机或邮箱验证码','text','one-time-code');
  activationCode.input.inputMode='numeric';activationCode.input.maxLength=6;activationCode.input.pattern='[0-9]{6}';
  activationCode.label.hidden=true;activationCode.input.required=false;
  const entry=node('div','admin-captcha-row'),admin=node('button','admin-secondary','管理员入口'),staff=node('button','admin-secondary','客服入口'),activate=node('button','admin-secondary','首次开通');
  entry.append(admin,staff,activate);
  const activationApi=createStaffActivationApi();
  let challengeId = null, busy = false, generation = 0, mode='admin', activationId=null;
  function viewMode(next) {
    mode=next;activationId=null;activationCode.input.value='';password.input.value='';
    activationCode.label.hidden=true;activationCode.input.required=false;
    username.label.hidden=false;password.label.hidden=false;captcha.label.hidden=false;pictureRow.hidden=false;challengeStatus.hidden=false;
    username.input.required=true;password.input.required=true;captcha.input.required=true;
    submit.textContent=next==='activate'?'发送开通验证码':'登录';
    status.textContent=next==='activate'?'仅限已有官方客服身份；验证码发送到 APP 当前已验证的绑定联系方式。':next==='staff'?'客服入口：使用原 APP 账号与登录密码。':'使用现有管理员账号与登录密码。';
  }
  for(const [button,next] of [[admin,'admin'],[staff,'staff'],[activate,'activate']]) {
    button.type='button';button.addEventListener('click',()=>{if(busy)return;viewMode(next);return loadChallenge();});
  }
  async function loadChallenge() {
    const revision = ++generation; challengeId = null; submit.disabled = true; refresh.disabled = true;
    picture.hidden = true; picture.removeAttribute('src'); captcha.input.value = ''; challengeStatus.textContent = '正在加载验证码…';
    try {
      const data = await api.getLoginCaptcha();
      if (revision !== generation) return;
      if (!data.challenge_id || !/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(data.image || '')) throw Error('验证码数据无效，请重试。');
      challengeId = data.challenge_id; picture.src = data.image; picture.hidden = false;
      challengeStatus.textContent = '不区分大小写 · 有效期 2 分钟';
    } catch (error) { if (revision === generation) challengeStatus.textContent = error.message || '验证码加载失败，请点击换一张。'; }
    finally { if (revision === generation) {refresh.disabled = busy; submit.disabled = busy || !challengeId;} }
  }
  picture.addEventListener('error', () => {challengeId = null; submit.disabled = true; picture.hidden = true; challengeStatus.textContent = '验证码图片未能显示，请点击换一张。';});
  refresh.addEventListener('click', () => {if (!busy) return loadChallenge();});
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (busy || (!challengeId && !activationId)) return;
    busy = true; submit.disabled = true; refresh.disabled = true; form.setAttribute('aria-busy', 'true'); status.textContent = '正在验证…';
    const body = {username: username.input.value.trim(), password: password.input.value, challenge_id: challengeId, captcha_answer: captcha.input.value};
    challengeId = null; password.input.value = ''; captcha.input.value = '';
    try {
      if(mode==='activate') {
        if(activationId) {
          const code=activationCode.input.value;activationCode.input.value='';
          const result=await (api.confirmStaffActivation??activationApi.confirmStaffActivation)({activation_id:activationId,code});
          if(result.status!=='activated')throw Error('开通响应无效，请重新核对。');
          viewMode('staff');await loadChallenge();status.textContent='开通成功，请使用原 APP 账号与登录密码登录。';
        } else {
          const result=await (api.requestStaffActivation??activationApi.requestStaffActivation)(body);
          if(typeof result.activation_id!=='string'||!result.activation_id||!['phone','email'].includes(result.channel)||typeof result.masked_target!=='string')throw Error('验证码响应无效，请重试。');
          activationId=result.activation_id;
          username.label.hidden=true;password.label.hidden=true;captcha.label.hidden=true;pictureRow.hidden=true;challengeStatus.hidden=true;
          username.input.required=false;password.input.required=false;captcha.input.required=false;
          activationCode.label.hidden=false;activationCode.input.required=true;activationCode.input.focus();
          submit.textContent='确认开通';status.textContent=`验证码已发送至 ${result.masked_target}，5 分钟内有效。`;
        }
        return;
      }
      const tokens = await api.adminLogin(body);
      if (typeof tokens.access_token !== 'string' || !tokens.access_token) throw Error('登录响应无效，请重新登录。');
      await onSuccess(tokens); status.textContent = '登录成功';
    } catch (error) {status.textContent = error.message || '登录失败，请重试。'; if(!activationId){await loadChallenge();password.input.focus();}}
    finally {busy = false; refresh.disabled = false; submit.disabled = !challengeId&&!activationId; form.setAttribute('aria-busy', 'false');}
  });
  form.append(entry,username.label, password.label, captcha.label, pictureRow, challengeStatus, activationCode.label, submit, status);
  card.append(form); page.append(brand, card, node('p', 'admin-login-footer', 'ChatFlow · 管理员安全入口')); void loadChallenge(); return page;
}

export function sessionExpiredDialog(onLogin) {
  const existing = document.querySelector('.admin-session-dialog'); if (existing) return existing;
  const dialog = node('dialog', 'admin-session-dialog'); dialog.setAttribute('aria-labelledby', 'admin-session-title'); dialog.setAttribute('aria-describedby', 'admin-session-description');
  const title = node('h2', '', '请重新登录'); title.id = 'admin-session-title';
  const description = node('p', '', '登录已过期或账号已在其他设备登录。请重新登录；系统不会自动重复提交操作。'); description.id = 'admin-session-description';
  const action = node('button', 'admin-primary', '重新登录'); action.type = 'button';
  action.addEventListener('click', () => {dialog.close(); onLogin();});
  dialog.addEventListener('cancel', event => event.preventDefault()); dialog.addEventListener('close', () => dialog.remove());
  dialog.append(title, description, action); document.body.append(dialog); dialog.showModal(); action.focus(); return dialog;
}

export function stepUpDialog(session) {
  return new Promise(resolve=>{
    const dialog=node('dialog','admin-session-dialog'),form=node('form','admin-login-form');
    const title=node('h2','','验证当前身份'),label=node('label','admin-login-label','当前登录密码'),input=node('input','admin-filter');input.type='password';input.autocomplete='current-password';input.required=true;input.setAttribute('aria-label','当前登录密码');label.append(input);
    const status=node('p','admin-login-status');status.setAttribute('role','status');
    const submit=node('button','admin-primary','验证'),cancel=node('button','admin-secondary','取消');submit.type='submit';cancel.type='button';let success=false,busy=false;
    form.append(title,node('p','admin-audit-note','验证后保留当前页面，请再次确认需要执行的操作。'),label,submit,cancel,status);dialog.append(form);
    form.addEventListener('submit',async event=>{event.preventDefault();if(busy)return;busy=true;submit.disabled=true;const password=input.value;input.value='';try{await session.stepUp(password);success=true;dialog.close();}catch(error){status.textContent=error.message;}finally{busy=false;submit.disabled=false;}});
    cancel.addEventListener('click',()=>dialog.close());dialog.addEventListener('close',()=>{input.value='';dialog.remove();resolve(success);});document.body.append(dialog);dialog.showModal();input.focus();
  });
}
