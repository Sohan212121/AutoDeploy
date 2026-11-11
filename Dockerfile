# Base image
FROM python:3.13-slim

# Prevent Python from writing .pyc files and enable unbuffered output
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

# Copy requirements first to leverage Docker layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy ONLY the app directory (tests, venv, and docs are excluded)
COPY app/ ./app/

# Build arguments with defaults
ARG APP_VERSION=1.0.0
ARG GIT_COMMIT_SHA=unknown
ARG BUILD_TIME=unknown
ARG DEPLOY_ENV=production

# Expose build args as environment variables for dynamic runtime access
ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT_SHA=${GIT_COMMIT_SHA} \
    BUILD_TIME=${BUILD_TIME} \
    DEPLOY_ENV=${DEPLOY_ENV} \
    DEPLOY_HISTORY_FILE=/data/deployment_history.json

# Create non-root user (UID 10001) and configure directory ownership
RUN useradd -u 10001 -m -s /bin/bash appuser && \
    mkdir -p /data && \
    chown -R appuser:appuser /app /data

USER appuser

EXPOSE 8000

# Health check using python urllib (no curl required)
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')" || exit 1

# Production WSGI server command
CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:8000", "--access-logfile", "-", "--error-logfile", "-", "app.app:app"]

