import {adminSession} from './admin-session.js?v=20260908-modern';
const DEFAULT_BASE_URL = "";

export class AdminApiError extends Error {
  constructor({ code = "REQUEST_FAILED", message = "请求失败，请重试。", status = 0, traceId = null, fields = [] }) {
    super(message);
    this.name = "AdminApiError";
    this.code = code;
    this.status = status;
    this.traceId = traceId;
    this.fields = Array.isArray(fields) ? fields : [];
  }
}

export function normalizeAdminContext(payload = {}) {
  return {
    actor: payload.actor ?? { display_name: "管理员", roles: [] },
    permissions: Array.isArray(payload.permissions) ? payload.permissions : [],
    overview: payload.overview ?? {},
    modules: payload.modules && typeof payload.modules === "object" ? payload.modules : {},
    updated_at: payload.updated_at ?? null
  };
}

export function can(context, permission) {
  const permissions = context?.permissions ?? [];
  return permissions.includes("*") || permissions.includes(permission);
}

export function createAdminApi({ baseUrl = DEFAULT_BASE_URL, token = null, tokenProvider = null, fetchImpl = globalThis.fetch } = {}) {
  if (typeof fetchImpl !== "function") throw new TypeError("fetch implementation is required");
  const request = async (path, options = {}) => {
    let activeToken=token;
    if(tokenProvider&&!path.startsWith('/api/v1/auth/')){
      try{activeToken=await tokenProvider();}catch(error){if(error.status===401&&typeof globalThis.dispatchEvent==='function')globalThis.dispatchEvent(new Event('admin-session-expired'));throw error;}
    }
    const headers = { ...(options.headers || {}), Accept: "application/json" };
    if (activeToken) headers.Authorization = `Bearer ${activeToken}`;
    let response;
    try { response = await fetchImpl(`${baseUrl}${path}`, { ...options, headers }); }
    catch {
      // A lost response may follow a committed command. Never retry it here.
      throw new AdminApiError({code:'NETWORK_ERROR',message:'网络连接中断，未能确认请求结果。请检查网络并刷新状态。'});
    }
    const contentType = response.headers?.get?.("content-type") ?? "";
    let body = {};
    if (contentType.includes("application/json") || typeof response.json === "function") { try { body = await response.json(); } catch { body = {}; } }
    if (!response.ok) {
      const errorBody = body?.error && typeof body.error === "object" ? body.error : body;
      if (activeToken && response.status === 401 && !path.startsWith('/api/v1/auth/') && typeof globalThis.dispatchEvent === 'function' && (tokenProvider?adminSession.peek()===activeToken:globalThis.sessionStorage?.getItem('chatflow_access_token') === token)) {
        globalThis.dispatchEvent(new Event('admin-session-expired'));
      }
      throw new AdminApiError({ code: errorBody.code || (response.status === 401 ? "UNAUTHORIZED" : response.status === 403 ? "FORBIDDEN" : "REQUEST_FAILED"), message: errorBody.message || `请求失败（HTTP ${response.status}）`, status: response.status, traceId: errorBody.trace_id, fields: errorBody.fields });
    }
    return body;
  };
  const command = async (path, body, { method = "POST", idempotencyKey } = {}) => {
    if (!idempotencyKey) throw new TypeError("idempotencyKey is required");
    const headers = { "Content-Type": "application/json", "Idempotency-Key": idempotencyKey };
    return request(path, { method, headers, cache: "no-store", body: JSON.stringify(body ?? {}) });
  };
  return {
    getManualWalletDiagnostics: async () => request('/api/v1/admin/wallet/manual/operations/diagnostics', {cache:'no-store'}),
    getOverview: async ({days=30}={})=>request(`/api/v1/admin/overview?days=${days}`,{cache:'no-store'}),
    getPointIssuance: async ({limit=25,cursor,kind}={})=>{const query=new URLSearchParams({limit:String(limit)});if(cursor)query.set('cursor',cursor);if(kind)query.set('kind',kind);return request(`/api/v1/admin/point-issuance?${query}`,{cache:'no-store'});},
    getPointIssuanceDetail: async id=>request(`/api/v1/admin/point-issuance/${encodeURIComponent(id)}`,{cache:'no-store'}),
    getLoginCaptcha: async () => request('/api/v1/auth/admin-captcha', {cache:'no-store'}),
    adminLogin: async body => request('/api/v1/auth/admin-login', {method:'POST', headers:{'Content-Type':'application/json'}, cache:'no-store', body:JSON.stringify({...body, device_key:'admin-browser', device_name:'ChatFlow Admin'})}),
    getWalletIncidents: async ({limit = 25, cursor} = {}) => {
      const query = new URLSearchParams({limit: String(limit)});
      if (cursor) query.set('cursor', cursor);
      return request(`/api/v1/admin/wallet/incidents?${query}`, {cache: 'no-store'});
    },
    getWalletIncident: async id => request(`/api/v1/admin/wallet/incidents/${encodeURIComponent(id)}`, {cache: 'no-store'}),
    getWalletMonitorStatus: async () => request('/api/v1/admin/wallet/monitor/status', {cache: 'no-store'}),
    manualWalletIncidentAction: async (id, action, body, options) => {
      if (!['ack', 'review', 'resolve'].includes(action)) throw new TypeError('Invalid incident action');
      return command(`/api/v1/admin/wallet/manual/operations/incidents/${encodeURIComponent(id)}/${action}`, body, options);
    },
    getManualWalletControl: async () => request('/api/v1/admin/wallet/manual/operations/control', {cache:'no-store'}),
    prepareWalletHandover: async (body,options) => command('/api/v1/admin/wallet/manual/handover/prepare',body,options),
    getWalletHandover: async id => request(`/api/v1/admin/wallet/manual/handover/${encodeURIComponent(id)}`,{cache:'no-store'}),
    walletHandoverAction: async (id,action,body,options) => {
      if(!['notify','confirm'].includes(action)) throw new TypeError('Invalid handover action');
      return command(`/api/v1/admin/wallet/manual/handover/${encodeURIComponent(id)}/${action}`,body,options);
    },
    manualWalletControlAction: async (action, body, options) => {
      if (!['pause','resume'].includes(action)) throw new TypeError('Invalid control action');
      return command(`/api/v1/admin/wallet/manual/operations/control/${action}`, body, options);
    },
    getManualPayouts: async ({limit = 50, cursor} = {}) => {
      const query = new URLSearchParams({limit: String(limit)});
      if (cursor != null && cursor !== "") query.set("cursor", cursor);
      return request(`/api/v1/admin/wallet/manual/payouts?${query}`, {cache: "no-store"});
    },
    getManualPayout: async id => request(`/api/v1/admin/wallet/manual/payouts/${encodeURIComponent(id)}`, {cache: "no-store"}),
    claimManualPayout: async (id, body, options) => command(`/api/v1/wallet/manual/payouts/${encodeURIComponent(id)}/claim`, body, options),
    submitManualPayoutTxid: async (id, body, options) => command(`/api/v1/wallet/manual/payouts/${encodeURIComponent(id)}/txid`, body, options),
    correctManualPayoutCandidate: async (id, body, options) => command(`/api/v1/wallet/manual/payouts/${encodeURIComponent(id)}/correct-candidate`, body, options),
    getWalletOperationSecurity: async () => request('/api/v1/admin/wallet/security', {cache:'no-store'}),
    setWalletOperationPassword: async (body,options) => command('/api/v1/admin/wallet/security/operation-password',body,options),
    getWalletMfaStatus: async () => request("/api/v1/security/mfa", {cache: "no-store"}),
    enrollWalletMfa: async (body, options) => command("/api/v1/security/mfa/enroll", body, options),
    enableWalletMfa: async (body, options) => command("/api/v1/security/mfa/enable", body, options),
    abortWalletMfaEnrollment: async (body, options) => command("/api/v1/security/mfa/abort-pending", body, options),
    getChainSummary: async () => request("/api/v1/admin/wallet/chain/summary"),
    getChainTransactions: async (filters = {}) => {
      const query = new URLSearchParams();
      for (const key of ["direction", "start_ms", "end_ms", "txid", "limit", "offset", "snapshot"]) {
        const value = filters[key];
        if (value !== undefined && value !== null && value !== "") query.set(key, String(value));
      }
      return request(`/api/v1/admin/wallet/chain/transactions?${query}`);
    },
    getChainTransaction: async (txid, logIndex) => request(`/api/v1/admin/wallet/chain/transactions/${encodeURIComponent(txid)}/${encodeURIComponent(logIndex)}`),
    getContext: async () => normalizeAdminContext(await request("/api/v1/admin/context")),
    login: async ({ username, password, device_key = "admin-browser", device_name = "ChatFlow Admin" }) => request("/api/v1/auth/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username, password, device_key, device_name }) }),
    getModule: async (module, accessToken = token) => {
      const scoped = createAdminApi({ baseUrl, token: accessToken, tokenProvider, fetchImpl });
      return scoped.requestModule(module);
    },
    command,
    requestModule: async (module) => request(`/api/v1/admin/modules/${encodeURIComponent(module)}`)
  };
}

export function browserAdminApi() {
  // A URL query must never redirect administrator credentials to another origin.
  return {...createAdminApi({tokenProvider:()=>adminSession.getToken()}),adminLogin:body=>adminSession.login({...body,device_key:'admin-browser',device_name:'ChatFlow Admin'})};
}
