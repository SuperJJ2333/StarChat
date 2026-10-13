import subprocess,json,datetime,concurrent.futures,socket,struct,os
r={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
def check(item):
 url,res=item;a=['curl','-sS','--max-time','15','-o','/dev/null','-w','%{http_code} %{time_total}']
 if res:a+=['--resolve',res]
 p=subprocess.run(a+[url],capture_output=True,text=True);return {'url':url,'resolve':res,'exit':p.returncode,'result':p.stdout,'error':p.stderr[:180]}
items=[('https://d2bc5pp65dxo0s.cloudfront.net/',None),('https://d2bc5pp65dxo0s.cloudfront.net/api/health',None),('https://d2tkooe3ua5wf2.cloudfront.net/',None),('https://www.liuhetong888.com/','www.liuhetong888.com:443:127.0.0.1'),('https://liuhetong888.com/health/live','liuhetong888.com:443:127.0.0.1')]
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:r['checks']=list(ex.map(check,items))
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(3);tid=os.urandom(12)
try:
 s.sendto(struct.pack('!HHI',1,0,0x2112A442)+tid,('172.31.46.134',3478));d,_=s.recvfrom(2048);r['stun_binding']={'success':d[:2]==b'\x01\x01' and d[8:20]==tid,'bytes':len(d)}
except Exception as e:r['stun_binding']={'error':type(e).__name__}
finally:s.close()
p=subprocess.run(['sudo','-n','docker','logs','--since','5m','--tail','2000','coscene-edge'],capture_output=True,text=True);r['edge_connection_refused_last5m']=(p.stdout+p.stderr).lower().count('connection refused')
print(json.dumps(r))
