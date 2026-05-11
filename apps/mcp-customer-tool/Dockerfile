# Multi-stage build keeps the runtime layer ~110 MB.
FROM python:3.13-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.13-slim
WORKDIR /app

# Non-root by default — APIM is the only client anyway.
RUN useradd -u 10001 -m -s /usr/sbin/nologin mcp
COPY --from=builder /opt/venv /opt/venv
COPY server.py customers.json ./

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8765

USER mcp
EXPOSE 8765
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import socket,sys; s=socket.socket(); s.settimeout(2); \
    sys.exit(0 if s.connect_ex(('127.0.0.1',8765))==0 else 1)" || exit 1
ENTRYPOINT ["python", "server.py"]
