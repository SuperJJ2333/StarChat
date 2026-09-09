"""Add narrowly scoped download routes to an existing production configuration."""
import pathlib
import re
import sys


def patch_routes(config):
    if '# chatflow-enterprise-download-v1' in config:
        return config
    apex = '''
    # chatflow-enterprise-download-v1
    location = / { return 302 https://www.liuhetong888.com/download; }
    location = /download { return 302 https://www.liuhetong888.com/download; }
    location = /download/ { return 302 https://www.liuhetong888.com/download; }
'''
    www = '''
    # chatflow-enterprise-download-www-v1
    location = /download {
        try_files /download.html =404;
        add_header Cache-Control "no-store" always;
    }
    location = /download/ { return 302 /download; }
    location = /downloads/ios/manifest.plist {
        types { }
        default_type application/xml;
        try_files $uri =404;
        add_header Cache-Control "no-store" always;
    }
    location ^~ /downloads/ios/ {
        types { }
        default_type application/octet-stream;
        try_files $uri =404;
        add_header X-Content-Type-Options nosniff always;
        add_header Cache-Control "public, max-age=3600" always;
    }
'''
    for hostname, routes in [('liuhetong888.com', apex), ('www.liuhetong888.com', www)]:
        pattern = r'(server\s*\{\s*listen 443 ssl;\s*http2 on;\s*server_name ' + re.escape(hostname) + r';)'
        config, count = re.subn(pattern, lambda match: match[1] + '\n' + routes, config)
        if count != 1:
            raise ValueError('Expected exactly one HTTPS server for ' + hostname)
    return config


if __name__ == '__main__':
    source, target = map(pathlib.Path, sys.argv[1:3])
    target.write_text(patch_routes(source.read_text(encoding='utf-8')), encoding='utf-8')
