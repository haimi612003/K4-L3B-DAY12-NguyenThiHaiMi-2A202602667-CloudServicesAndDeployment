# ═══════════════════════════════════════════════════════════════════
# CP2 — Containerization (bản production-ready)
#
#   [x] Multi-stage: `builder` cài dependency, `runtime` chỉ copy kết quả
#   [x] Base image python:3.11-slim
#   [x] COPY requirements.txt + pip install TRƯỚC khi COPY source (tận dụng cache)
#   [x] Chạy bằng user thường `appuser` (uid 10001), không phải root
#   [x] HEALTHCHECK gọi /health
#   [x] Đọc cổng từ biến môi trường PORT (mặc định 8000)
#
# Build:  docker build -t day12-agent:prod .
# ═══════════════════════════════════════════════════════════════════

# ── Stage 1: builder — cài thư viện vào /install, stage này bị vứt đi ──
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

COPY requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# ── Stage 2: runtime — chỉ mang theo Python + thư viện đã cài + code ──
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

COPY --from=builder /install /usr/local

RUN useradd --create-home --uid 10001 appuser

WORKDIR /app
COPY --chown=appuser:appuser app ./app
COPY --chown=appuser:appuser utils ./utils

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\", \"8000\")}/health', timeout=4).read()" || exit 1

# `exec` để uvicorn thay thế shell làm PID 1 → nhận thẳng SIGTERM từ orchestrator
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
