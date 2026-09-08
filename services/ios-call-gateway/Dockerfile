FROM python:3.12.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONUTF8=1 PYTHONIOENCODING=utf-8
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt && groupadd --gid 10001 gateway && useradd --uid 10001 --gid gateway --no-create-home gateway && mkdir /data && chown gateway:gateway /data && chmod 700 /data
COPY gateway.py ./
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "gateway:production_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log", "--limit-concurrency", "64", "--timeout-keep-alive", "5"]
