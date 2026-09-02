import re
from uuid import uuid4

from fastapi import Request


_TRACE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


def install_trace_middleware(app) -> None:
    @app.middleware("http")
    async def trace_middleware(request: Request, call_next):
        candidate = request.headers.get("X-Trace-Id", "")
        trace_id = candidate if _TRACE_ID_PATTERN.fullmatch(candidate) else uuid4().hex
        request.state.trace_id = trace_id
        response = await call_next(request)
        response.headers["X-Trace-Id"] = trace_id
        return response
