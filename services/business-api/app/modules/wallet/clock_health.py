"""Independent UTC sanity check for exceptional manual financial commands.

HTTP Date has second precision; two fresh TLS sources must agree. This does not
replace chain finality, reserve evidence or operating-system time discipline.
"""
from concurrent.futures import ThreadPoolExecutor
from email.utils import parsedate_to_datetime
import secrets
import threading
import time
import urllib.request
import json
import subprocess
import sys

SOURCES = ('https://www.cloudflare.com/cdn-cgi/trace', 'https://api.trongrid.io/wallet/getnowblock')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('reference redirects forbidden')


def probe_utc(url):
    request = urllib.request.Request(url + '?clock_probe=' + secrets.token_hex(12),
        headers={'Cache-Control': 'no-cache, no-store', 'Pragma': 'no-cache'})
    started, local = time.monotonic(), time.time()
    # No inherited workstation proxy; standard TLS certificate verification remains on.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=3) as response:
        if response.status != 200 or response.url != request.full_url or response.headers.get('Age', '0') != '0':
            raise ValueError('unusable reference response')
        dates = response.headers.get_all('Date', [])
        if len(dates) != 1:
            raise ValueError('ambiguous reference date')
        reference = parsedate_to_datetime(dates[0])
        if reference.tzinfo is None:
            raise ValueError('timezone missing')
        elapsed = time.monotonic() - started
        if abs((time.time() - local) - elapsed) > .5:
            raise ValueError('clock changed during probe')
        # Midpoint and half-second date quantization, conservative 5s health bound.
        return local + elapsed / 2 - (reference.timestamp() + .5), elapsed


class ClockHealth:
    def __init__(self, *, probe=probe_utc, monotonic=time.monotonic, wall=time.time):
        self.probe, self.monotonic, self.wall = probe, monotonic, wall
        self.lock = threading.Lock()
        self.checked = None
        self.result = False

    def trusted(self):
        with self.lock:
            now, wall = self.monotonic(), self.wall()
            if self.checked is not None:
                age = now - self.checked[0]
                if abs(wall - self.checked[1] - age) > .5:
                    self.checked, self.result = None, False
                    return False
                if 0 <= age < 15:
                    return self.result
            self.result = False
            try:
                if self.probe is probe_utc:
                    # DNS and slow response headers have no urllib overall deadline.
                    # A separate process is terminated on timeout, including its threads.
                    process = subprocess.run([sys.executable, __file__, '--probe'],
                        capture_output=True, text=True, timeout=6, check=True)
                    samples = json.loads(process.stdout)
                    if len(samples) != 2:
                        raise ValueError('invalid reference sample count')
                else:
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        samples = list(pool.map(self.probe, SOURCES))
                offsets = [item[0] for item in samples]
                self.result = (all(0 <= rtt <= 2 and abs(offset) + .5 + rtt / 2 <= 5 for offset, rtt in samples)
                    and max(offsets) - min(offsets) <= 2
                    and abs(self.wall() - wall - (self.monotonic() - now)) <= .5)
            except (OSError, ValueError, TypeError, subprocess.SubprocessError):
                self.result = False
            self.checked = (self.monotonic(), self.wall())
            return self.result


if __name__ == '__main__':
    if sys.argv[1:] != ['--probe']:
        raise SystemExit('read-only probe mode required')
    with ThreadPoolExecutor(max_workers=2) as executor:
        print(json.dumps(list(executor.map(probe_utc, SOURCES))))
