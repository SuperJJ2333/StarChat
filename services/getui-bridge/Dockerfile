ARG PYTHON_IMAGE=python:3.12.11-slim
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY services/getui-bridge/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip && pip install -r /tmp/requirements.txt

COPY services/getui-bridge/app /app/app

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8088", "--no-server-header", "--no-access-log"]
