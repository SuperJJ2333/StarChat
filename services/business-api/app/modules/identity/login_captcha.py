"""Short-lived, single-use browser challenges. No plaintext answers are stored."""
import base64
import hashlib
import hmac
import secrets
from io import BytesIO

from PIL import Image, ImageDraw, ImageFont

from app.core.errors import AppError


class LoginCaptcha:
    def __init__(self, store):
        self.store = store

    @staticmethod
    def digest(challenge, answer):
        return hashlib.sha256(f'{challenge}:{answer.upper()}'.encode()).hexdigest()

    def issue(self):
        challenge = secrets.token_urlsafe(32)
        answer = ''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZ23456789') for _ in range(6))
        image = Image.new('RGB', (216, 64), '#f5f5f7')
        draw = ImageDraw.Draw(image)
        font = ImageFont.load_default(size=32)
        for i, char in enumerate(answer):
            draw.text((12 + i * 33, 12 + secrets.randbelow(9)), char, font=font, fill='#24324a')
        for _ in range(6):
            draw.line([(secrets.randbelow(216), secrets.randbelow(64)),
                       (secrets.randbelow(216), secrets.randbelow(64))], fill='#a6afbf', width=1)
        buffer = BytesIO()
        image.save(buffer, format='PNG')
        try:
            self.store.set(f'admin:captcha:{challenge}', self.digest(challenge, answer), ex=120)
        except Exception:
            raise AppError(code='CAPTCHA_UNAVAILABLE', message='验证码服务暂时不可用，请稍后重试', status_code=503) from None
        return {'challenge_id': challenge, 'image': 'data:image/png;base64,' + base64.b64encode(buffer.getvalue()).decode(), 'expires_in': 120}

    def verify(self, challenge, answer):
        try:
            expected = self.store.getdel(f'admin:captcha:{challenge}')
        except Exception:
            raise AppError(code='CAPTCHA_UNAVAILABLE', message='验证码服务暂时不可用，请稍后重试', status_code=503) from None
        if isinstance(expected, bytes):
            expected = expected.decode()
        if not expected or not hmac.compare_digest(expected, self.digest(challenge, answer.strip())):
            raise AppError(code='CAPTCHA_INVALID', message='验证码错误或已过期，请使用新图片重试', status_code=400)
