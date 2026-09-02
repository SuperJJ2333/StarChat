const DEFAULT_BASE_URL = "";

export class AdminApiError extends Error {
  constructor({ code = "REQUEST_FAILED", message = "请求失败，请重试。", status = 0, traceId = null }) {
    super(message);
    this.name = "AdminApiError";
    this.code = code;
    this.status = status;
    this.traceId = traceId;
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

export function createAdminApi({ baseUrl = DEFAULT_BASE_URL, token = null, fetchImpl = globalThis.fetch } = {}) {
  if (typeof fetchImpl !== "function") throw new TypeError("fetch implementation is required");
  const request = async (path, options = {}) => {
    const headers = { ...(options.headers || {}), Accept: "application/json" };
    if (token) headers.Authorization = `Bearer ${token}`;
    const response = await fetchImpl(`${baseUrl}${path}`, { ...options, headers });
    const contentType = response.headers?.get?.("content-type") ?? "";
    let body = {};
    if (contentType.includes("application/json") || typeof response.json === "function") { try { body = await response.json(); } catch { body = {}; } }
    if (!response.ok) {
      const errorBody = body?.error && typeof body.error === "object" ? body.error : body;
      throw new AdminApiError({ code: errorBody.code || (response.status === 401 ? "UNAUTHORIZED" : response.status === 403 ? "FORBIDDEN" : "REQUEST_FAILED"), message: errorBody.message || `请求失败（HTTP ${response.status}）`, status: response.status, traceId: errorBody.trace_id });
    }
    return body;
  };
  return {
    getContext: async () => normalizeAdminContext(await request("/api/v1/admin/context")),
    login: async ({ username, password, device_key = "admin-browser", device_name = "ChatFlow Admin" }) => request("/api/v1/auth/login", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ username, password, device_key, device_name }) }),
    getModule: async (module, accessToken = token) => {
      const scoped = createAdminApi({ baseUrl, token: accessToken, fetchImpl });
      return scoped.requestModule(module);
    },
    command: async (path, body, { method = "POST", idempotencyKey } = {}) => {
      if (!idempotencyKey) throw new TypeError("idempotencyKey is required");
      const headers = { "Content-Type": "application/json", "Idempotency-Key": idempotencyKey };
      return request(path, { method, headers, body: JSON.stringify(body ?? {}) });
    },
    requestModule: async (module) => request(`/api/v1/admin/modules/${encodeURIComponent(module)}`)
  };
}

export function browserAdminApi() {
  const params = new URLSearchParams(globalThis.location?.search ?? "");
  return createAdminApi({
    baseUrl: params.get("apiBase") ?? globalThis.__CHATFLOW_API_BASE__ ?? DEFAULT_BASE_URL,
    token: globalThis.sessionStorage?.getItem("chatflow_access_token") ?? null
  });
}
