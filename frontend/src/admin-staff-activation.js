// Activation never stores credentials or grants a session. Login remains explicit.
export function createStaffActivationApi({fetchImpl=globalThis.fetch}={}) {
  async function call(action,body) {
    let response;
    try {response=await fetchImpl(`/api/v1/auth/staff-activation/${action}`,{
      method:'POST',credentials:'same-origin',cache:'no-store',
      headers:{Accept:'application/json','Content-Type':'application/json','X-Admin-CSRF':'1'},
      body:JSON.stringify(body)});} catch {throw Error('网络连接中断，请重试；验证码不会自动重发。');}
    let result={};try{result=await response.json();}catch{}
    if(!response.ok){const error=result.error??result;throw Object.assign(Error(error.message??'开通失败，请重试。'),{code:error.code,status:response.status});}
    return result;
  }
  return {requestStaffActivation:body=>call('challenges',body),confirmStaffActivation:body=>call('confirm',body)};
}
