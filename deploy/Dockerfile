# Imagem de produção da API + frontend estático (somente Python).
FROM python:3.13-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    RG_AMBIENTE=producao \
    RG_MODO_DEMO=false \
    RG_HIBP_ENABLED=false \
    RG_FRONTEND_DIR=/app/frontend \
    RG_STORAGE_DIR=/data/storage

# Sem OCR, IA ou serviços externos: a imagem contém apenas Python e as dependências da API.
RUN useradd --system --uid 10001 --home /app rg \
 && mkdir -p /data/storage && chown -R rg /data

WORKDIR /app
COPY backend/requirements.txt backend/requirements.txt
RUN pip install -r backend/requirements.txt

COPY backend/ backend/
COPY frontend/ frontend/
COPY deploy/start.sh deploy/start.sh
RUN rm -f backend/.env && chown -R rg /app

USER rg
WORKDIR /app/backend
EXPOSE 8000
VOLUME ["/data/storage"]

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/api/v1/saude' % os.environ.get('PORT', '8000'), timeout=4)"

# gthread é obrigatório para WebSockets (cada conexão ativa ocupa uma thread).
# A porta vem de $PORT (Render e similares); padrão 8000. O script aplica as migrações antes de subir.
CMD ["sh", "/app/deploy/start.sh"]
