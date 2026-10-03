"""Reviewed operational provider. Run production commands only by the release owner.

Primary: systemd encrypted credentials. Independent: Windows CurrentUser DPAPI.
Only sealed ciphertext and nonsecret readback proofs cross stdout/SSH.
"""
import argparse
import contextlib
import ctypes
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from chatflow_recovery_crypto import canonical, decode, encode, generate_envelope, unwrap

PRIMARY = Path('/etc/credstore.encrypted/chatflow-recovery-keyring.cred')
INDEPENDENT = Path.home() / '.chatflow-recovery-vault/credentials/207.56.8.8'
REMOTE = 'root@207.56.8.8'
REMOTE_HELPER = '/opt/chatflow-recovery/chatflow_recovery_provider.py'
REMOTE_PYTHON = '/opt/chatflow-recovery/venv/bin/python'
OAEP = padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=b'chatflow-recovery-dr-v1')


class ProviderError(Exception):
    def __init__(self): super().__init__('Recovery credential operation unavailable')


def key_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,64}', value):
        raise ProviderError()
    return value


def proof(name, key):
    return hmac.new(key, b'independent-readback-v1\0' + name.encode(), hashlib.sha256).hexdigest()


def prepare(ring, name):
    key_id(name)
    if name not in ring['keys']:
        if len(ring['keys']) >= 64: raise ProviderError()
        ring['keys'][name] = {'key': encode(os.urandom(32)), 'state': 'primary_inactive', 'confirmation': None}
    return ring


def confirm(ring, name, acknowledgement):
    entry = ring['keys'][key_id(name)]
    expected = proof(name, decode(entry['key']))
    if not isinstance(acknowledgement, str) or not hmac.compare_digest(expected, acknowledgement):
        raise ProviderError()
    entry['confirmation'] = expected
    if entry['state'] == 'primary_inactive': entry['state'] = 'independent_protected_and_readback_confirmed'


def activate(ring, name):
    entry = ring['keys'][key_id(name)]
    if (entry['state'] not in ('independent_protected_and_readback_confirmed', 'active_for_writes', 'bounded_rewrap')
            or entry['confirmation'] != proof(name, decode(entry['key']))):
        raise ProviderError()
    entry['state'] = 'active_for_writes'
    ring['active'] = name


def seal(ring, name, public_pem):
    public = serialization.load_pem_public_key(public_pem)
    if not isinstance(public, rsa.RSAPublicKey) or public.key_size != 3072: raise ProviderError()
    entry = ring['keys'][key_id(name)]
    return public.encrypt(canonical({'key_id': name, 'key': entry['key']}), OAEP)


def atomic(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.parent.is_symlink(): raise ProviderError()
    descriptor, temporary = tempfile.mkstemp(prefix='.recovery-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            if os.name == 'posix': os.fchmod(stream.fileno(), mode)
            stream.write(content); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        if os.name == 'posix':
            parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(parent)
            finally: os.close(parent)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def dpapi(data, protect=True):
    if os.name != 'nt': raise ProviderError()
    from ctypes import wintypes
    class Blob(ctypes.Structure):
        _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    output = Blob()
    crypt = ctypes.windll.crypt32
    # CRYPTPROTECT_UI_FORBIDDEN; CurrentUser (never LOCAL_MACHINE).
    function = crypt.CryptProtectData if protect else crypt.CryptUnprotectData
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(output)):
        raise ProviderError()
    try: return ctypes.string_at(output.data, output.size)
    finally: ctypes.windll.kernel32.LocalFree(output.data)


def private_windows_directory(path):
    if os.name != 'nt': raise ProviderError()
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    if path.is_symlink(): raise ProviderError()
    # SIDs avoid locale-dependent account names. Existing explicit foreign ACEs
    # are removed by a fresh exact protected ACL, not merely disabling inheritance.
    script = """$ErrorActionPreference='Stop'
$p=$args[0]
$sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=[System.Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner($sid)
foreach($s in @($sid,[System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
 $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($s,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $p -AclObject $acl
$read=Get-Acl -LiteralPath $p
if(-not $read.AreAccessRulesProtected -or $read.Access.Count -ne 2){exit 2}
foreach($r in $read.Access){if($r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -notin @($sid.Value,'S-1-5-18')){exit 3}}
foreach($child in Get-ChildItem -LiteralPath $p -File){
 if($child.Extension -ne '.dpapi'){continue}
 foreach($r in (Get-Acl -LiteralPath $child.FullName).Access){
  if($r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -notin @($sid.Value,'S-1-5-18')){exit 4}
 }
}
"""
    import base64
    # Passing the directory through stdin avoids interpolation/code execution.
    wrapper = "$p=[Console]::In.ReadToEnd(); & {" + script + "} $p"
    result = subprocess.run(['pwsh.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand',
        base64.b64encode(wrapper.encode('utf-16-le')).decode()], input=str(path).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.returncode: raise ProviderError()


def receive_and_protect(private, sealed, destination, expected_name, failure=None):
    payload = json.loads(private.decrypt(sealed, OAEP))
    if set(payload) != {'key_id', 'key'} or payload['key_id'] != key_id(expected_name): raise ProviderError()
    key = decode(payload['key'])
    if len(key) != 32: raise ProviderError()
    path = Path(destination) / (expected_name + '.dpapi')
    private_windows_directory(path.parent)
    if failure == 'before_save': raise ProviderError()
    if path.exists():
        if dpapi(path.read_bytes(), False) != canonical(payload): raise ProviderError()
    else:
        atomic(path, dpapi(canonical(payload)))
    if failure == 'after_save': raise ProviderError()
    recovered = json.loads(dpapi(path.read_bytes(), False))
    restored = decode(recovered['key'])
    if restored != key or recovered['key_id'] != expected_name: raise ProviderError()
    sample = generate_envelope('dr.test.invalid', '@synthetic:dr.test.invalid', 'readback', expected_name, key)
    if unwrap(sample, {expected_name: restored}) != unwrap(sample, {expected_name: key}): raise ProviderError()
    if failure == 'before_ack': raise ProviderError()
    return proof(expected_name, restored)


def ssh(action, name, data):
    result = subprocess.run(['ssh', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15', '-J', 'jumper', '-p', '23421', REMOTE,
        REMOTE_PYTHON, REMOTE_HELPER, action, key_id(name)], input=data,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or len(result.stdout) > 16384: raise ProviderError()
    return result.stdout


def independent_backup(name):
    private = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    public = private.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    sealed = ssh('seal', name, public)
    acknowledgement = receive_and_protect(private, sealed, INDEPENDENT, name)
    # Idempotent confirmation; lost ACK retries exactly this key, never a new one.
    ssh('confirm', name, acknowledgement.encode())


def systemd_read():
    if not PRIMARY.is_file() or PRIMARY.is_symlink(): raise ProviderError()
    completed = subprocess.run(['systemd-creds', 'decrypt', '--name=chatflow-recovery-keyring', str(PRIMARY), '-'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if completed.returncode or len(completed.stdout) > 32768: raise ProviderError()
    ring = json.loads(completed.stdout)
    if ring.get('format') != 1 or not isinstance(ring.get('keys'), dict): raise ProviderError()
    return ring


def systemd_write(ring):
    completed = subprocess.run(['systemd-creds', 'encrypt', '--name=chatflow-recovery-keyring', '-', '-'],
        input=canonical(ring), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if completed.returncode or not completed.stdout: raise ProviderError()
    atomic(PRIMARY, completed.stdout)
    if systemd_read() != ring: raise ProviderError()


def materialize():
    source = Path(os.environ['CREDENTIALS_DIRECTORY']) / 'chatflow-recovery-keyring'
    ring = json.loads(source.read_bytes())
    if ring['active'] is None: raise ProviderError()
    destination = Path('/run/chatflow-recovery/keyring.json')
    atomic(destination, canonical(ring), 0o400)
    os.chown(destination, 991, 991)
    os.chmod(destination.parent, 0o711)


def restore_receive(active):
    """Fresh replacement host only. Ephemeral public key out, sealed records in."""
    if PRIMARY.exists(): raise ProviderError()
    private = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    public = private.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    print(encode(public), flush=True)
    ring = {'format': 1, 'active': None, 'keys': {}}
    for _ in range(65):
        line = sys.stdin.buffer.readline(2049)
        if line == b'DONE\n': break
        if not line.endswith(b'\n') or len(ring['keys']) >= 64: raise ProviderError()
        payload = json.loads(private.decrypt(decode(line.rstrip().decode()), OAEP))
        if set(payload) != {'key_id', 'key'}: raise ProviderError()
        name, key = key_id(payload['key_id']), decode(payload['key'])
        if len(key) != 32 or name in ring['keys']: raise ProviderError()
        ring['keys'][name] = {'key': payload['key'], 'state': 'independent_protected_and_readback_confirmed',
                             'confirmation': proof(name, key)}
    else:
        raise ProviderError()
    activate(ring, active)
    systemd_write(ring)


def restore_send(active):
    """Restore all independent historical IDs, not just today's active key."""
    if os.name != 'nt': raise ProviderError()
    child = subprocess.Popen(['ssh', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15', '-J', 'jumper', '-p', '23421', REMOTE,
        REMOTE_PYTHON, REMOTE_HELPER, 'restore-receive', key_id(active)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        public_line = child.stdout.readline(8193)
        public = serialization.load_pem_public_key(decode(public_line.rstrip().decode()))
        if not isinstance(public, rsa.RSAPublicKey) or public.key_size != 3072: raise ProviderError()
        paths = sorted(INDEPENDENT.glob('*.dpapi'))
        if not 1 <= len(paths) <= 64: raise ProviderError()
        for path in paths:
            payload = json.loads(dpapi(path.read_bytes(), False))
            if payload['key_id'] != path.stem: raise ProviderError()
            child.stdin.write(encode(public.encrypt(canonical(payload), OAEP)).encode() + b'\n')
        child.stdin.write(b'DONE\n'); child.stdin.flush()
        child.stdin.close()
        if child.wait(timeout=60): raise ProviderError()
    finally:
        if child.poll() is None: child.kill(); child.wait()


def rewrap_batch(ring, old):
    import psycopg
    from chatflow_recovery_store import VaultStore
    active = ring['active']
    if active == old: raise ProviderError()
    activate(ring, active)  # verifies independent proof before ANY envelope write
    ring['keys'][active]['state'] = 'bounded_rewrap'
    systemd_write(ring)
    class Transaction:
        def __init__(self, cursor): self.cursor = cursor
        def execute(self, query, params=()): self.cursor.execute(query.replace('?', '%s'), params)
        def fetchall(self): return self.cursor.fetchall()
        @property
        def rowcount(self): return self.cursor.rowcount
    with psycopg.connect('') as connection:
        with connection.cursor() as cursor:
            return VaultStore().rewrap_batch(Transaction(cursor), old, active,
                {name: decode(value['key']) for name, value in ring['keys'].items()}, 40)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['init', 'prepare', 'seal', 'confirm', 'activate', 'backup',
                                         'materialize', 'restore-send', 'restore-receive', 'rewrap'])
    parser.add_argument('key_id', nargs='?')
    args = parser.parse_args()
    try:
        if args.action == 'backup':
            independent_backup(key_id(args.key_id))
        elif args.action == 'restore-send':
            restore_send(key_id(args.key_id))
        elif args.action == 'materialize':
            materialize()
        else:
            import fcntl
            if os.geteuid() != 0: raise ProviderError()
            with open('/run/lock/chatflow-recovery-provider.lock', 'a+b') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                if args.action == 'restore-receive':
                    restore_receive(key_id(args.key_id))
                    print('Recovery credential operation confirmed')
                    return 0
                if args.action == 'init':
                    if PRIMARY.exists(): raise ProviderError()
                    ring = {'format': 1, 'active': None, 'keys': {}}
                else:
                    ring = systemd_read()
                name = key_id(args.key_id)
                if args.action in ('init', 'prepare'): prepare(ring, name)
                elif args.action == 'seal':
                    sys.stdout.buffer.write(seal(ring, name, sys.stdin.buffer.read(8193)))
                    return 0
                elif args.action == 'confirm': confirm(ring, name, sys.stdin.buffer.read(65).decode())
                elif args.action == 'activate': activate(ring, name)
                elif args.action == 'rewrap':
                    print('Recovery envelopes rewrapped:', rewrap_batch(ring, name))
                    return 0
                systemd_write(ring)
        print('Recovery credential operation confirmed')
        return 0
    except Exception:
        print('Recovery credential operation unavailable', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
