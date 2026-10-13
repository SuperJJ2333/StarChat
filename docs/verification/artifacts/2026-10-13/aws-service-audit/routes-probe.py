import subprocess,json,re,datetime,socket,urllib.request,ssl
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'logs':{},'configs':{}}
def run(a):return subprocess.run(a,capture_output=True,text=True,timeout=20)
for n in ['coscene-edge','coscene-postgres','starchat-sg-edge-coturn-20260927']:
 p=run(['sudo','-n','docker','logs','--since','15m','--tail','2000',n]);lines=(p.stdout+p.stderr).splitlines();out=[]
 for x in lines:
  if not re.search(r'error|fatal|refused',x,re.I):continue
  # Never return request URLs, client addresses, database identities or credentials.
  cats=[k for k in ['connection refused','database system is starting up','database system is shutting down','does not exist','password authentication failed','cli-password','empty cli','Cannot create','Permission denied'] if k.lower() in x.lower()]
  out.append({'timestamp':x[:23] if re.match(r'^\d{4}',x) else None,'categories':cats,'error_prefix':re.sub(r'"[^"\n]*"', '"[redacted]"',x.split('client:')[0])[:240] if n.endswith('coturn-20260927') else None})
 r['logs'][n]=out
p=run(['sudo','-n','docker','exec','ga-gold-aws-edge','cat','/etc/caddy/Caddyfile']);r['configs']['caddy_directives']=[x.strip() for x in p.stdout.splitlines() if re.match(r'^\s*(https?://|:[0-9]|reverse_proxy|respond|tls )',x)]
p=run(['sudo','-n','docker','exec','starchat-sg-edge-nginx-20260927','nginx','-T']);r['configs']['nginx_listen']=[x.strip() for x in p.stdout.splitlines() if re.match(r'^\s*(listen|proxy_pass)',x)]
r['http']=[]
for url in ['https://sg.liuhetong888.com:18443/healthz','https://sg.liuhetong888.com:18443/','http://127.0.0.1:8080/health/live']:
 p=run(['curl','--silent','--show-error','--max-time','10','-o','/dev/null','-w','%{http_code} %{time_total}',url]);r['http'].append({'url':url,'exit':p.returncode,'result':p.stdout,'tls_error': 'SSL' in p.stderr})
print(json.dumps(r))
