import pathlib
import html
import re
from urllib.parse import parse_qs, urlparse
import unittest
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))


class EnterpriseDownloadTest(unittest.TestCase):
    def test_page_has_install_and_existing_android_links(self):
        page = (ROOT / 'frontend/download.html').read_text(encoding='utf-8')
        self.assertIn('itms-services://?action=download-manifest&amp;url=https://www.liuhetong888.com/downloads/ios/manifest.plist', page)
        self.assertIn('/downloads/latest-arm64.apk', page)
        self.assertIn('/assets/download-qr.png', page)
        self.assertIn('安装验证中', page)
        self.assertIn('Safari', page)

    def test_install_link_uses_https_manifest_served_by_download_routes(self):
        # Deployed plist/IPA files are release artifacts, not source fixtures.
        page = (ROOT / 'frontend/download.html').read_text(encoding='utf-8')
        install_link = re.search(r'href="(itms-services:[^"]+)"', page).group(1)
        query = parse_qs(urlparse(html.unescape(install_link)).query)
        self.assertEqual(query['action'], ['download-manifest'])
        manifest = urlparse(query['url'][0])
        self.assertEqual(manifest.scheme, 'https')
        self.assertEqual(manifest.netloc, 'www.liuhetong888.com')
        self.assertEqual(manifest.path, '/downloads/ios/manifest.plist')
        from enterprise_download_routes import patch_routes
        fixture = 'server {\n    listen 443 ssl;\n    http2 on;\n    server_name liuhetong888.com;\n}\nserver {\n    listen 443 ssl;\n    http2 on;\n    server_name www.liuhetong888.com;\n}\n'
        rendered = patch_routes(fixture)
        self.assertIn(f'location = {manifest.path}', rendered)
        self.assertIn('default_type application/xml;', rendered)

    def test_nginx_patch_is_additive_and_idempotent(self):
        from enterprise_download_routes import patch_routes
        original = (ROOT / 'infra/nginx/nginx.conf.template').read_text(encoding='utf-8')
        original = original.replace('{{PUBLIC_HOSTNAME}}', 'liuhetong888.com').replace('{{WWW_PUBLIC_HOSTNAME}}', 'www.liuhetong888.com')
        changed = patch_routes(original)
        self.assertEqual(patch_routes(changed), changed)
        self.assertIn('location = /download', changed)
        self.assertIn('return 302 https://www.liuhetong888.com/download;', changed)
        self.assertIn('try_files /download.html =404;', changed)
        self.assertIn('default_type application/xml;', changed)
        self.assertIn('proxy_pass http://synapse_upstream;', changed)
        self.assertIn('proxy_pass http://business_api_upstream;', changed)


if __name__ == '__main__':
    unittest.main()
