function element(tag, className, text) {
  const item = document.createElement(tag);
  item.className = className || '';
  if (text) item.textContent = text;
  return item;
}

export function staffPasswordDialog({session, onSuccess, onClose} = {}) {
  const dialog = element('dialog', 'admin-session-dialog admin-staff-password-dialog');
  dialog.setAttribute('aria-label', '修改密码');
  const form = element('form', 'admin-login-form');
  form.append(element('h2', '', '修改密码'),
    element('p', 'admin-audit-note', '此密码同时用于畅聊 App 与客服后台。修改后所有设备将退出，提现进入 24 小时保护期。'));
  function field(name, label, autocomplete) {
    const wrapper = element('label', 'admin-login-label', label);
    const input = element('input', 'admin-filter');
    input.name = name; input.type = 'password'; input.required = true; input.autocomplete = autocomplete;
    input.setAttribute('aria-label', label);
    wrapper.append(input); form.append(wrapper);
    return input;
  }
  const current = field('current_password', '当前密码', 'current-password');
  const next = field('new_password', '新密码', 'new-password');
  const confirmation = field('confirm_password', '确认新密码', 'new-password');
  next.minLength = confirmation.minLength = 12;
  next.maxLength = confirmation.maxLength = 256;
  const status = element('p', 'admin-login-status');
  status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
  const actions = element('div', 'admin-password-actions');
  const submit = element('button', 'admin-primary', '修改密码'); submit.type = 'submit';
  const cancel = element('button', 'admin-secondary', '取消'); cancel.type = 'button';
  actions.append(submit, cancel); form.append(status, actions); dialog.append(form);
  let busy = false;
  dialog.addEventListener('cancel', event => {if (busy) event.preventDefault();});
  dialog.addEventListener('close', () => {
    current.value = next.value = confirmation.value = '';
    dialog.remove(); onClose?.();
  });
  cancel.addEventListener('click', () => {if (!busy) dialog.close();});
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (busy) return;
    if (next.value.length < 12 || next.value.length > 256) {
      status.textContent = '新密码须为 12 至 256 位。'; next.focus(); return;
    }
    if (next.value !== confirmation.value) {
      status.textContent = '两次输入的新密码不一致。'; confirmation.focus(); return;
    }
    if (!current.value) {status.textContent = '请输入当前密码。'; current.focus(); return;}
    busy = true; submit.disabled = cancel.disabled = true; form.setAttribute('aria-busy', 'true');
    status.textContent = '正在修改密码…';
    try {
      await session.changeStaffPassword({current_password: current.value, new_password: next.value});
      current.value = next.value = confirmation.value = '';
      dialog.close();
      await onSuccess?.();
    } catch (error) {
      current.value = '';
      status.textContent = error.message || '密码修改未完成，请重试。';
      current.focus();
    } finally {
      busy = false; submit.disabled = cancel.disabled = false; form.setAttribute('aria-busy', 'false');
    }
  });
  document.body.append(dialog); dialog.showModal(); current.focus();
  return dialog;
}
