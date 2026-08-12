ARG PYTHON_IMAGE=python:3.12.11-slim
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libffi-dev libolm-dev \
    && rm -rf /var/lib/apt/lists/*

COPY services/matrix-bot/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip && pip install -r /tmp/requirements.txt

COPY services/matrix-bot/app /app/app

RUN mkdir -p /data/bot

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8081"]
