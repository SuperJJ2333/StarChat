"""业务域图片压缩（Pillow 多规格演绎版）。

适用边界：仅处理业务 API 自有的非加密媒体（头像/朋友圈类业务上传产物）。
E2EE 聊天媒体按规格 §8.1 服务端不可解密，其缩略图/压缩版一律由发送端
客户端生成并加密附带（见 apps/mobile_flutter media_thumbnail）。

策略：
- 输入支持 JPEG/PNG/GIF/WebP（GIF 取首帧转静态图）；
- 规格档位为最长边像素上限，小图不放大；
- 输出 WebP（默认，质量 80）或 JPEG（质量 85），体积显著小于原图。
"""

from dataclasses import dataclass
from io import BytesIO

from PIL import Image, ImageOps

from app.core.errors import AppError

SOURCE_MIME_TYPES: dict[str, str] = {
    # mime -> Pillow 格式名
    "image/jpeg": "JPEG",
    "image/png": "PNG",
    "image/gif": "GIF",
    "image/webp": "WEBP",
}

ALLOWED_SIZES: tuple[int, ...] = (160, 240, 320, 480, 640, 800, 1280)

OUTPUT_FORMATS: dict[str, str] = {
    # 对外格式名 -> (Pillow 格式, 扩展名, 保存参数)
    "webp": ("WEBP", ".webp", {"quality": 80, "method": 4}),
    "jpeg": ("JPEG", ".jpg", {"quality": 85, "optimize": True}),
}

MAX_SIZES_PER_REQUEST = 4


@dataclass(frozen=True)
class Rendition:
    size: int
    width: int
    height: int
    format: str
    content: bytes
    extension: str


@dataclass(frozen=True)
class CompressResult:
    source_width: int
    source_height: int
    source_format: str
    renditions: list[Rendition]


def parse_sizes(raw: str | None) -> list[int]:
    """解析并校验 sizes 查询参数（如 "320,800"）。"""
    if raw is None or not raw.strip():
        return [320, 800]
    values: list[int] = []
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            value = int(chunk)
        except ValueError:
            raise AppError(
                code="MEDIA_SIZE_INVALID",
                message="压缩规格无效",
                status_code=422,
            ) from None
        if value not in ALLOWED_SIZES:
            raise AppError(
                code="MEDIA_SIZE_INVALID",
                message=f"压缩规格仅支持 {','.join(map(str, ALLOWED_SIZES))}",
                status_code=422,
            )
        if value not in values:
            values.append(value)
    if not values or len(values) > MAX_SIZES_PER_REQUEST:
        raise AppError(
            code="MEDIA_SIZE_INVALID",
            message=f"压缩规格需 1-{MAX_SIZES_PER_REQUEST} 个",
            status_code=422,
        )
    return values


def compress_renditions(
    content: bytes,
    *,
    content_type: str,
    sizes: list[int],
    output_format: str = "webp",
) -> CompressResult:
    """按规格档位生成压缩演绎版（最长边不超过规格值，小图不放大）。"""
    pillow_format = SOURCE_MIME_TYPES.get(content_type.casefold())
    if pillow_format is None:
        raise AppError(
            code="MEDIA_FORMAT_UNSUPPORTED",
            message="仅支持 JPEG/PNG/GIF/WebP 图片",
            status_code=415,
        )
    output = OUTPUT_FORMATS.get(output_format)
    if output is None:
        raise AppError(
            code="MEDIA_FORMAT_UNSUPPORTED",
            message="输出格式仅支持 webp/jpeg",
            status_code=422,
        )
    try:
        with Image.open(BytesIO(content)) as image:
            source_format = (image.format or pillow_format).casefold()
            rotated = ImageOps.exif_transpose(image)
            if rotated is not None:
                image = rotated
            source_width, source_height = image.size
            renditions: list[Rendition] = []
            for size in sizes:
                rendition = _render(image, size=size, output=output)
                renditions.append(rendition)
    except AppError:
        raise
    except Exception as exc:
        raise AppError(
            code="MEDIA_INVALID",
            message="图片内容无法解析",
            status_code=422,
        ) from exc
    return CompressResult(
        source_width=source_width,
        source_height=source_height,
        source_format=source_format,
        renditions=renditions,
    )


def _render(image: Image.Image, *, size: int, output: tuple) -> Rendition:
    pillow_format, extension, save_options = output
    frame = image
    if frame.mode not in ("RGB", "RGBA"):
        frame = frame.convert("RGBA" if pillow_format == "WEBP" else "RGB")
    elif pillow_format == "JPEG" and frame.mode == "RGBA":
        frame = frame.convert("RGB")
    if max(frame.size) > size:
        frame = frame.copy()
        frame.thumbnail((size, size), Image.LANCZOS)
    buffer = BytesIO()
    frame.save(buffer, format=pillow_format, **save_options)
    return Rendition(
        size=size,
        width=frame.size[0],
        height=frame.size[1],
        format=pillow_format.casefold(),
        content=buffer.getvalue(),
        extension=extension,
    )
