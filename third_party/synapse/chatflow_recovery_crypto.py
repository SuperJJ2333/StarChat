"""AES-GCM custody envelopes. No session/message decryption capability."""
import base64
import hashlib
import json
import os

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ALGORITHM = 'm.megolm_backup.v1.curve25519-aes-sha2'


class Unavailable(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def encode(value):
    return base64.b64encode(value).decode('ascii').rstrip('=')


def decode(value):
    if not isinstance(value, str) or '=' in value:
        raise ValueError('Invalid encoding')
    result = base64.b64decode(value + '=' * (-len(value) % 4), validate=True)
    if encode(result) != value:
        raise ValueError('Noncanonical encoding')
    return result


def public_key(private):
    return encode(X25519PrivateKey.from_private_bytes(private).public_key().public_bytes(
        Encoding.Raw, PublicFormat.Raw))


def aad(envelope):
    return canonical({name: envelope[name] for name in (
        'format', 'server', 'owner', 'version', 'algorithm', 'public_fingerprint', 'key_id')})


def wrap(private, binding, key_id, key):
    if len(key) != 32 or len(private) != 32:
        raise Unavailable('Recovery unavailable')
    envelope = {**binding, 'format': 1, 'key_id': key_id, 'public_key': public_key(private)}
    envelope['public_fingerprint'] = hashlib.sha256(decode(envelope['public_key'])).hexdigest()
    nonce = os.urandom(12)
    encrypted = AESGCM(key).encrypt(nonce, private, aad(envelope))
    envelope.update(nonce=encode(nonce), ciphertext=encode(encrypted[:-16]), tag=encode(encrypted[-16:]))
    return envelope


def generate_envelope(server, owner, version, key_id, key):
    return wrap(os.urandom(32), {'server': server, 'owner': owner, 'version': version,
                               'algorithm': ALGORITHM}, key_id, key)


def unwrap(envelope, keys):
    try:
        if (envelope['format'] != 1 or envelope['algorithm'] != ALGORITHM
                or len(decode(envelope['nonce'])) != 12 or len(decode(envelope['tag'])) != 16
                or len(keys[envelope['key_id']]) != 32):
            raise ValueError()
        private = AESGCM(keys[envelope['key_id']]).decrypt(decode(envelope['nonce']),
            decode(envelope['ciphertext']) + decode(envelope['tag']), aad(envelope))
        if (len(private) != 32 or public_key(private) != envelope['public_key']
                or hashlib.sha256(decode(envelope['public_key'])).hexdigest() != envelope['public_fingerprint']):
            raise ValueError()
        return private
    except Exception:
        raise Unavailable('Recovery unavailable') from None


def rewrap(envelope, keys, key_id, key):
    binding = {name: envelope[name] for name in ('server', 'owner', 'version', 'algorithm')}
    return wrap(unwrap(envelope, keys), binding, key_id, key)
