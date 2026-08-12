from dataclasses import dataclass
from typing import Any

from fastapi import HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


@dataclass(frozen=True)
class FieldError:
    loc: list[Any]
    msg: str
    type: str

    def as_dict(self) -> dict[str, Any]:
        return {"loc": self.loc, "msg": self.msg, "type": self.type}


class AppError(Exception):
    def __init__(
        self,
        *,
        code: str,
        message: str,
        status_code: int = 400,
        fields: list[FieldError] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.fields = fields or []


def _payload(
    *, code: str, message: str, trace_id: str, fields: list[FieldError] | None = None
) -> dict[str, Any]:
    return {
        "error": {
            "code": code,
            "message": message,
            "trace_id": trace_id,
            "fields": [field.as_dict() for field in (fields or [])],
        }
    }


def _trace_id(request: Request) -> str:
    return getattr(request.state, "trace_id", "unknown")


def install_error_handlers(app) -> None:
    @app.exception_handler(AppError)
    async def app_error_handler(request: Request, exc: AppError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=_payload(
                code=exc.code,
                message=exc.message,
                trace_id=_trace_id(request),
                fields=exc.fields,
            ),
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        fields = [
            FieldError(loc=list(error.get("loc", [])), msg=error["msg"], type=error["type"])
            for error in exc.errors()
        ]
        return JSONResponse(
            status_code=422,
            content=_payload(
                code="VALIDATION_ERROR",
                message="请求参数校验失败",
                trace_id=_trace_id(request),
                fields=fields,
            ),
        )

    @app.exception_handler(HTTPException)
    async def http_error_handler(request: Request, exc: HTTPException) -> JSONResponse:
        message = exc.detail if isinstance(exc.detail, str) else "请求失败"
        return JSONResponse(
            status_code=exc.status_code,
            content=_payload(code="HTTP_ERROR", message=message, trace_id=_trace_id(request)),
        )

    @app.exception_handler(Exception)
    async def unhandled_error_handler(request: Request, exc: Exception) -> JSONResponse:
        return JSONResponse(
            status_code=500,
            content=_payload(
                code="INTERNAL_ERROR", message="服务内部错误", trace_id=_trace_id(request)
            ),
        )
