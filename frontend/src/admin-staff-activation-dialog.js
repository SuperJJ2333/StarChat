import {createStaffActivationApi} from './admin-staff-activation.js';

function element(tag, className, text) {
  const item = document.createElement(tag);
  item.className = className || '';
  if (text) item.textContent = text;
  return item;
}

export function showStaffActivationDialog({api, username, password, onActivated, onClose}) {
  const activationApi = createStaffActivationApi();
  const state = {password, challengeId: null, activationId: null, busy: false, closed: false, revision: 0};
  let expiryTimer;
  const dialog = element('dialog', 'admin-session-dialog admin-activation-dialog');
  dialog.setAttribute('aria-label', '首次开通验证方式');
  const form = element('form', 'admin-login-form');
  const title = element('h2', '', '首次开通验证方式');
  const note = element('p', 'admin-audit-note', '选择当前账号已验证的邮箱或手机，完成一次验证即可开通。');
  const channelLabel = element('label', 'admin-login-label', '验证方式');
  const channel = element('select', 'admin-filter');
  channel.name = 'channel';
  channel.setAttribute('aria-label', '验证方式');
  for (const [value, label] of [['email', '邮箱'], ['phone', '手机']]) {
    const option = element('option', '', label); option.value = value; channel.append(option);
  }
  channel.value = 'email'; channelLabel.append(channel);
  const captchaLabel = element('label', 'admin-login-label', '图形验证码');
  const answer = element('input', 'admin-filter');
  answer.name = 'captcha_answer'; answer.type = 'text'; answer.required = true;
  answer.maxLength = 6; answer.autocapitalize = 'characters'; answer.spellcheck = false;
  answer.setAttribute('aria-label', '图形验证码'); captchaLabel.append(answer);
  const pictureRow = element('div', 'admin-captcha-row');
  const picture = element('img', 'admin-captcha-image');
  picture.alt = '六位图形验证码，不区分大小写'; picture.width = 216; picture.height = 64; picture.hidden = true;
  const refresh = element('button', 'admin-captcha-refresh', '换一张'); refresh.type = 'button';
  pictureRow.append(picture, refresh);
  const codeLabel = element('label', 'admin-login-label', '绑定邮箱或手机验证码');
  const code = element('input', 'admin-filter');
  code.name = 'activation_code'; code.type = 'text'; code.inputMode = 'numeric'; code.maxLength = 6;
  code.autocomplete = 'one-time-code'; code.pattern = '[0-9]{6}'; code.required = false;
  code.setAttribute('aria-label', '绑定邮箱或手机验证码'); codeLabel.append(code); codeLabel.hidden = true;
  const status = element('p', 'admin-login-status');
  status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
  const actions = element('div', 'admin-activation-actions');
  const submit = element('button', 'admin-primary', '发送验证码'); submit.type = 'submit'; submit.disabled = true;
  const cancel = element('button', 'admin-secondary', '取消'); cancel.type = 'button';
  actions.append(submit, cancel);
  form.append(title, note, channelLabel, captchaLabel, pictureRow, codeLabel, status, actions);
  dialog.append(form);

  function close() { if (!state.closed) dialog.close(); }
  const leave = () => close();
  globalThis.addEventListener?.('pagehide', leave);
  dialog.addEventListener('cancel', event => {event.preventDefault(); close();});
  dialog.addEventListener('close', () => {
    state.closed = true; state.revision++; state.password = '';
    if(expiryTimer !== undefined) clearTimeout(expiryTimer);
    globalThis.removeEventListener?.('pagehide', leave);
    answer.value = ''; code.value = ''; picture.removeAttribute('src');
    dialog.remove(); onClose?.();
  });
  cancel.addEventListener('click', close);

  async function loadCaptcha() {
    const revision = ++state.revision;
    state.challengeId = null; submit.disabled = true; refresh.disabled = true;
    picture.hidden = true; picture.removeAttribute('src'); answer.value = '';
    status.textContent = '正在加载图形验证码…';
    try {
      const challenge = await api.getLoginCaptcha();
      if (state.closed || revision !== state.revision) return;
      if (!challenge.challenge_id || !/^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(challenge.image || '')) {
        throw Error('验证码数据无效，请换一张。');
      }
      state.challengeId = challenge.challenge_id;
      picture.src = challenge.image; picture.hidden = false;
      status.textContent = '图形验证码有效期 2 分钟';
    } catch (error) {
      if (!state.closed && revision === state.revision) status.textContent = error.message || '验证码加载失败，请换一张。';
    } finally {
      if (!state.closed && revision === state.revision) {
        submit.disabled = state.busy || !state.challengeId;
        refresh.disabled = state.busy;
      }
    }
  }
  picture.addEventListener('error', () => {
    if (state.closed || state.activationId) return;
    state.challengeId = null; submit.disabled = true; picture.hidden = true;
    status.textContent = '验证码图片未能显示，请换一张。';
  });
  refresh.addEventListener('click', () => {if (!state.busy && !state.activationId) void loadCaptcha();});
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (state.closed || state.busy || (!state.activationId && !state.challengeId)) return;
    state.busy = true; submit.disabled = true; refresh.disabled = true;
    form.setAttribute('aria-busy', 'true');
    try {
      if (!state.activationId) {
        const requestedAt = globalThis.performance?.now?.() ?? Date.now();
        const body = {username, password: state.password, channel: channel.value,
          challenge_id: state.challengeId, captcha_answer: answer.value};
        state.challengeId = null; answer.value = '';
        status.textContent = '正在发送开通验证码…';
        const result = await (api.requestStaffActivation ?? activationApi.requestStaffActivation)(body);
        if (state.closed) return;
        if (!result?.activation_id || !['email', 'phone'].includes(result.channel) || !result.masked_target) {
          throw Error('开通验证码响应无效，请重试。');
        }
        if (!Number.isSafeInteger(result.expires_in) || result.expires_in <= 0 || result.expires_in > 300) {
          close();
          return;
        }
        const elapsed = (globalThis.performance?.now?.() ?? Date.now()) - requestedAt;
        expiryTimer = setTimeout(close, Math.max(0, result.expires_in * 1000 - elapsed));
        expiryTimer?.unref?.();
        state.activationId = result.activation_id;
        channelLabel.hidden = true; captchaLabel.hidden = true; pictureRow.hidden = true;
        answer.required = false; codeLabel.hidden = false; code.required = true;
        submit.textContent = '确认开通';
        status.textContent = `验证码已发送至 ${result.masked_target}，5 分钟内有效。`;
        code.focus();
      } else {
        const activationId = state.activationId;
        const enteredCode = code.value; code.value = '';
        status.textContent = '正在确认开通…';
        const result = await (api.confirmStaffActivation ?? activationApi.confirmStaffActivation)({activation_id: activationId, code: enteredCode});
        if (state.closed) return;
        if (result?.status !== 'activated') throw Error('开通响应无效，请重新核对。');
        const credentials = {username, password: state.password};
        state.password = '';
        close();
        await onActivated(credentials);
      }
    } catch (error) {
      if (!state.closed) {
        status.textContent = error.message || '开通失败，请重试。';
        if (!state.activationId) void loadCaptcha();
      }
    } finally {
      state.busy = false; form.setAttribute('aria-busy', 'false');
      if (!state.closed) {
        submit.disabled = !state.activationId && !state.challengeId;
        refresh.disabled = false;
      }
    }
  });
  document.body.append(dialog); dialog.showModal(); channel.focus();
  void loadCaptcha();
  return {dialog, close};
}
