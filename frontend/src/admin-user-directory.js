import {statusLabel} from './admin-formatters.js';

const element = (tag, className, text) => {
  const item = document.createElement(tag);
  item.className = className || '';
  if (text !== undefined) item.textContent = String(text);
  return item;
};
const action = (label, handler, className = 'admin-secondary') => {
  const item = element('button', className, label);
  item.type = 'button'; item.addEventListener('click', handler);
  return item;
};
const points = value => typeof value === 'string' && /^-?\d+\.\d{2}$/.test(value)
  ? value.replace(/\B(?=(\d{3})+\.)/g, ',') : '—';
const contact = (value, verifiedAt) => value ? `${value} · ${verifiedAt ? '已验证' : '未验证'}` : '未绑定';

export function userDirectory(api) {
  const panel = element('section', 'admin-card admin-user-directory');
  panel.append(element('h2', null, '用户管理'),
    element('p', 'admin-audit-note', '仅管理员可查看。余额来自点钻账本，联系方式为账号当前绑定信息。'));
  const search = element('form', 'admin-user-search');
  search.name = 'user-directory-search';
  const input = element('input', 'admin-filter');
  input.name = 'q'; input.type = 'search'; input.maxLength = 128;
  input.placeholder = '搜索畅聊号、昵称、邮箱或手机号';
  input.setAttribute('aria-label', '搜索畅聊号、昵称、邮箱或手机号');
  const find = element('button', 'admin-primary', '搜索'); find.type = 'submit';
  search.append(input, find);
  const message = element('p', 'admin-audit-note');
  message.setAttribute('role', 'status'); message.setAttribute('aria-live', 'polite');
  const wrap = element('div', 'admin-user-table-wrap');
  const table = element('table', 'admin-table');
  const head = element('thead'), headRow = element('tr');
  for (const label of ['畅聊号','昵称','邮箱','手机号','点钻余额','账号状态','客服头衔']) headRow.append(element('th', null, label));
  head.append(headRow); const body = element('tbody'); table.append(head, body); wrap.append(table);
  const pager = element('div', 'admin-user-pagination');
  const position = element('span');
  const previous = action('上一页', () => {
    if (!loading && page > 0) void load({query, cursors:[...cursors], page:page-1});
  });
  const next = action('下一页', () => {
    if (!loading && nextCursor) void load({query, cursors:[...cursors.slice(0,page+1),nextCursor], page:page+1});
  });
  const retry = action('重新加载', () => {void load(failedRequest ?? undefined);});
  pager.append(previous, position, next, retry);
  panel.append(search, message, wrap, pager);
  let revision = 0, disposed = false, query = '', cursors = [null], page = 0;
  let nextCursor = null, loading = false, failedRequest = null;
  function controls() {
    previous.disabled = loading || page === 0;
    next.disabled = loading || !nextCursor;
    retry.disabled = loading;
  }
  function render(payload) {
    body.replaceChildren();
    const items = Array.isArray(payload.items) ? payload.items : [];
    if (!items.length) {
      const row = element('tr'), cell = element('td', null, '暂无匹配用户');
      cell.colSpan = 7; row.append(cell); body.append(row);
    }
    for (const account of items) {
      const row = element('tr');
      for (const value of [
        account.username || '—', account.nickname || '—',
        contact(account.email, account.email_verified_at),
        contact(account.phone, account.phone_verified_at),
        points(account.caibi_balance), statusLabel(account.status),
        account.official_support_title || '—'
      ]) row.append(element('td', null, value));
      body.append(row);
    }
    nextCursor = payload.next_cursor || null;
    const total = Number.isSafeInteger(payload.total) ? payload.total : items.length;
    position.textContent = `第 ${page+1} 页 · 共 ${total} 位用户`;
    message.textContent = items.length ? '点钻余额为账本当前值' : '未找到匹配用户，请调整搜索条件。';
  }
  async function load(target = {query, cursors:[...cursors], page}) {
    if (disposed) return false;
    const request = ++revision;
    loading = true; controls(); message.textContent = '正在加载用户…';
    try {
      const data = await api.searchUsers({q:target.query, limit:50, cursor:target.cursors[target.page]});
      if (disposed || request !== revision) return false;
      query = target.query; cursors = [...target.cursors]; page = target.page;
      failedRequest = null; render(data); return true;
    } catch (error) {
      if (disposed || request !== revision) return false;
      failedRequest = target;
      if ([401,403].includes(error?.status) || ['AUTH_REQUIRED','UNAUTHORIZED','FORBIDDEN','PERMISSION_DENIED'].includes(error?.code)) {
        body.replaceChildren(); nextCursor = null; position.textContent = '';
        message.textContent = '用户资料访问权限已变化，请重新登录后查看。';
      } else {
        message.textContent = `用户加载失败：${error.message || '请重新加载'}。保留上次筛选和页码，现有列表可能已过期。`;
      }
      return false;
    } finally {
      if (!disposed && request === revision) {loading = false; controls();}
    }
  }
  search.addEventListener('submit', event => {
    event.preventDefault();
    return load({query:input.value.trim(), cursors:[null], page:0});
  });
  panel.refresh = () => load();
  panel.dispose = () => {disposed = true; revision++; body.replaceChildren();};
  controls(); void load();
  return panel;
}
