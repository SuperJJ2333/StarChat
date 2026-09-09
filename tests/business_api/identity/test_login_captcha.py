import base64
from io import BytesIO

import pytest
from PIL import Image
from app.core.errors import AppError
from app.modules.identity.login_captcha import LoginCaptcha


class Store:
    def __init__(self):
        self.values = {}
    def set(self, key, value, *, ex):
        assert ex == 120
        self.values[key] = value
    def getdel(self, key):
        return self.values.pop(key, None)


def test_png_and_no_plaintext_answer(monkeypatch):
    monkeypatch.setattr('app.modules.identity.login_captcha.secrets.choice', lambda alphabet: 'A')
    store = Store()
    result = LoginCaptcha(store).issue()
    assert set(result) == {'challenge_id', 'image', 'expires_in'}
    assert result['expires_in'] == 120
    png = base64.b64decode(result['image'].split(',')[1])
    assert Image.open(BytesIO(png)).format == 'PNG'
    assert 'AAAAAA' not in list(store.values.values())[0]
    LoginCaptcha(store).verify(result['challenge_id'], 'aaaaaa')
    with pytest.raises(AppError):
        LoginCaptcha(store).verify(result['challenge_id'], 'AAAAAA')


def test_wrong_answer_consumes_challenge(monkeypatch):
    monkeypatch.setattr('app.modules.identity.login_captcha.secrets.choice', lambda alphabet: 'A')
    service = LoginCaptcha(Store())
    challenge = service.issue()['challenge_id']
    for answer in ('WRONG', 'AAAAAA'):
        with pytest.raises(AppError) as error:
            service.verify(challenge, answer)
        assert error.value.code == 'CAPTCHA_INVALID'


def test_missing_expired_and_unavailable_store_fail_closed():
    service = LoginCaptcha(Store())
    with pytest.raises(AppError):
        service.verify('missing', 'AAAAAA')
    class Broken(Store):
        def getdel(self, key):
            raise ConnectionError('private connection information')
    with pytest.raises(AppError) as error:
        LoginCaptcha(Broken()).verify('missing', 'AAAAAA')
    assert error.value.code == 'CAPTCHA_UNAVAILABLE'
    assert 'private' not in str(error.value)
