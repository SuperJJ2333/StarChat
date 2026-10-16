from pathlib import Path
import shutil
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[4]
old=ROOT/'docs/verification/artifacts/2026-10-12/android2215-public-workstation-check'
out=HERE/'public-check'
out.mkdir(exist_ok=False)
for name in ('start_tunnel.ps1','stop_tunnel.ps1'):shutil.copyfile(old/name,out/name)
s=(old/'check_public.py').read_text(encoding='utf-8')
s=s.replace('ChatFlow-0.4.46-build2215-arm64.apk','ChatFlow-0.4.47-build2216-arm64.apk').replace('4b43bd1ca655918b9754183c1713ed5eb6e864379a2e2ccc6bd861195578b6a6','db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039')
s=s.replace("'build':2215", "'build':2216").replace("'version':'0.4.46'", "'version':'0.4.47'")
s=s.replace("b'0.4.44'", "b'0.4.47'").replace("b'2213'", "b'2216'")
start=s.index("        checks['ios_manifest_unchanged_identity'] =")
end=s.index('\n    except ',start)
s=s[:start]+"        checks['ios_manifest_unchanged_identity'] = records['ios_manifest']['http_status'] == 200 and bodies['ios_manifest'] == (HERE/'expected-ios-manifest.plist').read_bytes()"+s[end:]
(out/'check_public.py').write_text(s,encoding='utf-8')
print('Prepared lightweight post-publication checker; no network requests')
