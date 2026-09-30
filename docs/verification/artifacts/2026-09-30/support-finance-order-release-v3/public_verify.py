"""Strict TLS public metadata checks; anonymous probes cannot write financial state."""
import argparse,json,os,subprocess
from hashlib import sha256
from urllib.parse import quote
from release import MANIFEST,validate_manifest
API='https://liuhetong888.com';ADMIN='https://admin.liuhetong888.com'
def curl(url,proxy,status=False,post=False):
    command=['curl','--proto','=https','--tlsv1.2','--silent','--show-error','--max-time','30','--noproxy','']
    command+=['--socks5-hostname',proxy] if proxy else ['--proxy','']
    command+=['--output',os.devnull,'--write-out','%{http_code}'] if status else ['--fail']
    if post:command+=['--request','POST','--header','Content-Type: application/json','--data','{}']
    return subprocess.check_output(command+[url],timeout=40)
def verify(m,proxy,expect):
    health=json.loads(curl(API+'/api/v1/health/ready',proxy))
    if health.get('ok') is not True or health.get('database')!='ready':raise ValueError('strict TLS JSON readiness failed')
    for path in ('/api/v1/admin/context','/api/v1/admin/support-orders/payouts','/api/v1/recharge/admin/requests/pending'):
        if curl(API+path,proxy,True).decode() not in ('401','403'):raise ValueError('anonymous business reads must reject')
    if expect=='candidate':
        for path in ('/api/v1/admin/support-orders/payouts/release-synthetic/takeover','/api/v1/admin/support-orders/payouts/release-synthetic/select-discovered','/api/v1/recharge/admin/requests/release-synthetic/takeover'):
            if curl(API+path,proxy,True,post=True).decode() not in ('401','403'):
                raise ValueError('candidate route must reject anonymous POST with401/403')
    for item in m['static']:
        body=curl(ADMIN+'/'+quote(item['dest'],safe='/'),proxy)
        expected=item['after_sha256'] if expect=='candidate' else item['before_sha256']
        if sha256(body).hexdigest()!=expected:raise ValueError('public static SHA mismatch')
    return {'strict_tls':True,'ready':True,'anonymous_denial':True,'static_files':len(m['static']),'expect':expect}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--socks5-hostname');p.add_argument('--expect',choices=['candidate','rollback'],default='candidate');a=p.parse_args()
    m=validate_manifest(json.loads(MANIFEST.read_text(encoding='utf-8')));print(json.dumps(verify(m,a.socks5_hostname,a.expect)))
if __name__=='__main__':main()
