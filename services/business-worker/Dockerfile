ARG PYTHON_IMAGE=python:3.12.11-slim@sha256:47ae396f09c1303b8653019811a8498470603d7ffefc29cb07c88f1f8cb3d19f
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY services/business-api/ /opt/business-api/
RUN pip install --no-cache-dir -r /opt/business-api/requirements.lock \
    && pip install --no-cache-dir --no-deps --no-build-isolation /opt/business-api \
    && pip check
COPY scripts/wallet_release_preflight.py /opt/business-api/release_preflight.py
COPY services/business-worker/ /opt/business-worker/

WORKDIR /opt/business-worker/app
CMD ["python", "main.py"]
