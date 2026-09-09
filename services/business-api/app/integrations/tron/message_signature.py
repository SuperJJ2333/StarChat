"""TronWeb signMessageV2 recovery, using libsecp256k1 and Keccak libraries."""
import hashlib
import hmac

from coincurve import PublicKey
from Crypto.Hash import keccak

_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'


def _encode(raw: bytes) -> str:
    value = int.from_bytes(raw, 'big')
    result = ''
    while value:
        value, digit = divmod(value, 58)
        result = _ALPHABET[digit] + result
    return '1' * (len(raw) - len(raw.lstrip(b'\0'))) + result


def canonical_address(address: str) -> str:
    if not isinstance(address, str) or len(address) != 34 or not address.startswith('T'):
        raise ValueError('invalid TRON address')
    try:
        value = 0
        for char in address:
            value = value * 58 + _ALPHABET.index(char)
        raw = value.to_bytes(25, 'big')
    except (ValueError, OverflowError):
        raise ValueError('invalid TRON address') from None
    checksum = hashlib.sha256(hashlib.sha256(raw[:21]).digest()).digest()[:4]
    if raw[0] != 0x41 or not hmac.compare_digest(checksum, raw[21:]) or _encode(raw) != address:
        raise ValueError('invalid TRON address')
    return address


def address_from_public_key(public_key: bytes) -> str:
    uncompressed = PublicKey(public_key).format(compressed=False)
    payload = b'\x41' + keccak.new(digest_bits=256, data=uncompressed[1:]).digest()[-20:]
    return _encode(payload + hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4])


def message_digest(message: str) -> bytes:
    raw = message.encode('utf-8')
    return keccak.new(digest_bits=256, data=b'\x19TRON Signed Message:\n' + str(len(raw)).encode('ascii') + raw).digest()


class TronMessageVerifier:
    def verify(self, message: str, signature: str, address: str) -> bool:
        try:
            canonical_address(address)
            raw = bytes.fromhex(signature.removeprefix('0x'))
            if len(raw) != 65 or raw[-1] not in (0, 1, 27, 28):
                return False
            normalized = raw[:64] + bytes([raw[-1] - 27 if raw[-1] >= 27 else raw[-1]])
            public = PublicKey.from_signature_and_message(normalized, message_digest(message), hasher=None)
            return hmac.compare_digest(address_from_public_key(public.format()), address)
        except (ValueError, TypeError, AttributeError):
            return False
