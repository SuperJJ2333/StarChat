ARG PYTHON_IMAGE=python:3.12.11-slim@sha256:47ae396f09c1303b8653019811a8498470603d7ffefc29cb07c88f1f8cb3d19f
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /opt/business-api
COPY services/business-api/ /opt/business-api/
RUN pip install --no-cache-dir -r requirements.lock \
    && pip install --no-cache-dir --no-deps --no-build-isolation . \
    && pip check
COPY scripts/wallet_release_preflight.py /opt/business-api/release_preflight.py

EXPOSE 8082
CMD ["sh", "-c", "alembic -c alembic.ini upgrade head && exec uvicorn app.main:create_default_app --factory --host 0.0.0.0 --port 8082 --workers ${BUSINESS_API_WORKERS:-2}"]
