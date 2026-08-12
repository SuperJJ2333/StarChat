ARG PYTHON_IMAGE
FROM ${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY services/business-api/ /opt/business-api/
RUN pip install --no-cache-dir /opt/business-api
COPY services/business-worker/ /opt/business-worker/

WORKDIR /opt/business-worker/app
CMD ["python", "main.py"]
