# Multi-stage Dockerfile for the Mergington High School API
# Stage 1: builder – install dependencies
# Stage 2: runtime – minimal image with only what's needed to run

# ── Builder stage ──────────────────────────────────────────────────────────
FROM python:3.11-slim AS builder

WORKDIR /build

# Copy and install dependencies first (layer cache-friendly)
COPY requirements.txt .
RUN pip install --upgrade pip \
 && pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Runtime stage ──────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

# Create a non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local

# Copy application source
COPY src/ ./src/

# Switch to non-root user
USER appuser

EXPOSE 8000

# Health check – matches the ECS task definition healthCheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/activities')"

# Start the FastAPI app with uvicorn
CMD ["uvicorn", "src.app:app", "--host", "0.0.0.0", "--port", "8000"]
