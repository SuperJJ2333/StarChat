// Access tokens exist only in memory. The server owns the absolute 48-hour deadline.
export function createAdminSession({fetchImpl=globalThis.fetch,locks=globalThis.navigator?.locks,now=Date.now}={}) {
  let access=null,expires=0,pending=null,generation=0,identity=null,sessionId=null,blocked=false;
  const exclusive=run=>locks?.request?locks.request('chatflow-admin-session',run):run();
  const clear=()=>{access=null;expires=0;identity=null;sessionId=null;blocked=true;generation++;};
  async function call(path,body,token){
    let response;try{response=await fetchImpl(`/api/v1/auth/${path}`,{method:body===undefined?'GET':'POST',credentials:'same-origin',cache:'no-store',headers:{Accept:'application/json','Content-Type':'application/json','X-Admin-CSRF':'1',...(sessionId&&path.startsWith('admin-session')?{'X-Admin-Session':sessionId}:{}),...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:JSON.stringify(body)})});}catch{throw Object.assign(Error('网络连接中断，请重试；操作不会自动重放。'),{code:'NETWORK_ERROR'});}
    let data={};try{data=await response.json();}catch{}
    if(!response.ok){const error=data.error??data;throw Object.assign(Error(error.message??'管理会话不可用，请重新登录。'),{code:error.code??'AUTH_REQUIRED',status:response.status});}return data;
  }
  function accept(data,version){if(version!==generation)throw Error('管理会话已变化');if(typeof data.access_token!=='string'||!Number.isFinite(data.expires_in)||typeof data.user_id!=='string'||typeof data.session_id!=='string')throw Error('登录响应异常');const nextIdentity=JSON.stringify([data.user_id,data.session_id]);if(identity!==null&&identity!==nextIdentity){clear();throw Object.assign(Error('当前浏览器已切换管理账号，请重新载入页面。'),{status:401,code:'ADMIN_SESSION_CHANGED'});}identity=nextIdentity;sessionId=data.session_id??null;access=data.access_token;expires=now()+data.expires_in*1000;return access;}
  async function refresh(){if(pending)return pending;const version=generation;pending=exclusive(async()=>accept(await call('admin-session/refresh',{}),version)).finally(()=>{pending=null;});return pending;}
  const getToken=()=>blocked?Promise.reject(Object.assign(Error("请重新登录后继续。"),{status:401,code:"AUTH_REQUIRED"})):access&&expires-now()>30000?Promise.resolve(access):refresh();
  return {
    getToken,peek:()=>access,clear,
    async login(body){const version=++generation;return exclusive(async()=>{const data=await call('admin-login',body);identity=null;accept(data,version);blocked=false;return data;});},
    async logout(){try{await exclusive(()=>call('admin-session/logout',{}));}finally{clear();}},
    async stepUp(password){const token=await getToken(),version=generation;const data=await call('admin-session/step-up',{password},token);accept(data,version);return data;},
    async check(){try{const token=await getToken();return await call('admin-session',undefined,token);}catch(error){if(error.status===401)clear();throw error;}}
  };
}
export const adminSession=createAdminSession();
