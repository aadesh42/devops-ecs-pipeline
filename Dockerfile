FROM python:3.12-slim AS builder
WORKDIR /install
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install/deps -r requirements.txt

FROM python:3.12-slim
RUN useradd --create-home --uid 10001 appuser
WORKDIR /srv
COPY --from=builder /install/deps /usr/local
COPY app/ ./app/
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request;urllib.request.urlopen('"'"'http://localhost:8000/health'"'"')"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
