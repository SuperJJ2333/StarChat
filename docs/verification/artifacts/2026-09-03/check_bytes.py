import os
import sys

sys.path.insert(0, "/opt/business-api")
from io import BytesIO

from PIL import Image

from app.core.config import Settings
from app.integrations.private_storage import LocalPrivateObjectStorage

settings = Settings(_env_file=None, environment="production")
storage = LocalPrivateObjectStorage(
    root=settings.avatar_storage_root,
    signing_secret=settings.avatar_url_signing_secret or "x",
    public_base_url=settings.avatar_public_base_url,
)
key = "avatars/0462589a-ee42-47b8-abe1-34937f24288d/92dac50d-315f-49df-9b5c-22cd6a4b11ff.jpg"
content = storage.get(key)
print("bytes:", len(content))
print("head:", content[:16].hex())
image = Image.open(BytesIO(content))
print("format:", image.format, "size:", image.size, "mode:", image.mode)
