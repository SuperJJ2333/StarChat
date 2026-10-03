"""Actual Windows DPAPI + RSA; all inputs are isolated random synthetic material."""
import copy
import json
import os
from pathlib import Path
import sys

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'third_party/synapse'))
import chatflow_recovery_provider as provider
from chatflow_recovery_crypto import decode, generate_envelope, unwrap


def test_every_key_requires_independent_readback_before_activation():
    ring = {'format': 1, 'active': None, 'keys': {}}
    provider.prepare(ring, 'old')
    with pytest.raises(provider.ProviderError): provider.activate(ring, 'old')
    old = decode(ring['keys']['old']['key'])
    provider.confirm(ring, 'old', provider.proof('old', old))
    provider.activate(ring, 'old')
    provider.prepare(ring, 'new')
    pending = copy.deepcopy(ring)
    provider.prepare(ring, 'new')
    assert ring == pending
    with pytest.raises(provider.ProviderError): provider.activate(ring, 'new')
    assert ring['active'] == 'old'
    with pytest.raises(provider.ProviderError): provider.confirm(ring, 'new', provider.proof('old', old))


@pytest.mark.skipif(os.name != 'nt', reason='actual Windows CurrentUser DPAPI required')
def test_dpapi_failures_same_key_retry_and_primary_host_loss_restore(tmp_path, capsys):
    # pytest basetemp is set to the task evidence runtime by the invocation.
    ring = {'format': 1, 'active': None, 'keys': {}}
    private = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    public = private.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    envelopes, originals = [], []
    for name in ('old', 'new'):
        provider.prepare(ring, name)
        sealed = provider.seal(ring, name, public)
        for failure in ('before_save', 'after_save', 'before_ack'):
            with pytest.raises(provider.ProviderError):
                provider.receive_and_protect(private, sealed, tmp_path, name, failure)
            with pytest.raises(provider.ProviderError): provider.activate(ring, name)
            assert ring['active'] == ('old' if name == 'new' else None)
        ack = provider.receive_and_protect(private, sealed, tmp_path, name)
        provider.confirm(ring, name, ack)
        assert ring['active'] == ('old' if name == 'new' else None)  # before-active failure
        provider.activate(ring, name)
        key = decode(ring['keys'][name]['key'])
        envelope = generate_envelope('dr.test', '@synthetic:dr.test', name, name, key)
        envelopes.append(envelope)
        originals.append(unwrap(envelope, {name: key}))
    # Lose the primary provider/host. Only independent files + mixed-key ciphertext remain.
    del ring, key, private, sealed
    restored = {}
    for path in tmp_path.glob('*.dpapi'):
        payload = json.loads(provider.dpapi(path.read_bytes(), False))
        restored[payload['key_id']] = decode(payload['key'])
    assert [unwrap(envelope, restored) for envelope in envelopes] == originals
    captured = capsys.readouterr()
    assert captured.out == captured.err == ''
