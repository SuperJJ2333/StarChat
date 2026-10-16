from pathlib import Path
import subprocess,json
H=Path(__file__).resolve().parent
R=H.parents[4]
PRIMARY=Path('D:/pythonProject/outsource/StarChat')
entry='''## 2026-10-16 Android2216正式包及普通更新已发布

11:04:15+08发布Android0.4.47+2216，固定75b31签名ARM64 APK SHA db914f66…41039/73,262,170B，包含五项体验优化与超级表情自动播放。20构建门禁全0、共享6038PASS/9SKIP复用、实包与发布SPEC→QUALITY通过；官网/CDN与route/audit后验PASS，Android三键审计、iOS2215/min3/35容器保持。备份0700，旧APK保留，自建隧道已关闭。既有libcrypto16KiB与ARM64真机/客户端弹窗实测缺口保留。见[任务](tasks/2026-10-16-android2216-release.md)与[报告](../verification/2026-10-16-android2216-release.md)。

'''
for root in (R,PRIMARY):
    p=root/'docs/workflow/current-state.md'
    text=p.read_text(encoding='utf-8')
    if entry.splitlines()[0] not in text:
        assert text.startswith('# 当前工作状态\n')
        p.write_text(text.replace('# 当前工作状态\n','# 当前工作状态\n\n'+entry,1),encoding='utf-8')
for name in ['docs/workflow/tasks/2026-10-16-android2216-release.md','docs/verification/2026-10-16-android2216-release.md']:
    text=(R/name).read_text(encoding='utf-8')
    if '/verification/' in name:text=text.replace('(artifacts/', '('+(R/'docs/verification/artifacts').as_posix()+'/')
    (PRIMARY/name).write_text(text,encoding='utf-8')
plan='docs/superpowers/plans/2026-10-16-mobile-experience-2216.md'
source=(R/plan).read_text(encoding='utf-8')
section=source.split('### User-approved Android publication (2026-10-16)\n',1)[1].split('\n - Preserve',1)[0] if '\n - Preserve' in source else source.split('### User-approved Android publication (2026-10-16)\n',1)[1].split('\n- Preserve',1)[0]
p=PRIMARY/plan;text=p.read_text(encoding='utf-8')
if '### User-approved Android publication (2026-10-16)' not in text:
    text=text.replace('## Global Constraints\n','## Global Constraints\n### User-approved Android publication (2026-10-16)\n'+section+'\n',1);p.write_text(text,encoding='utf-8')
# Stage only our current-state entry on HEAD; preserve older unstaged history.
name='docs/workflow/current-state.md'
base=subprocess.check_output(['git','-C',str(R),'show','HEAD:'+name]).decode('utf-8')
assert entry.splitlines()[0] not in base
staged=base.replace('# 当前工作状态\n','# 当前工作状态\n\n'+entry,1)
blob=subprocess.check_output(['git','-C',str(R),'hash-object','-w','--stdin'],input=staged.encode('utf-8')).decode().strip()
subprocess.run(['git','-C',str(R),'update-index','--cacheinfo','100644,'+blob+','+name],check=True)
print('DOCS_SYNCED_CURRENT_ENTRY_STAGED_OTHER_HISTORY_PRESERVED')
