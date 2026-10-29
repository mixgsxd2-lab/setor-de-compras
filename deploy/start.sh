#!/bin/sh
# Inicialização em PaaS (Render): aplica migrações e sobe o gunicorn na porta $PORT.
set -eu
cd /app/backend
if [ -n "${RG_MIGRATION_DATABASE_URL:-}" ]; then
  RG_DATABASE_URL="$RG_MIGRATION_DATABASE_URL" python -m rg.cli migrar
else
  python -m rg.cli migrar
fi
exec gunicorn wsgi:app --bind "0.0.0.0:${PORT:-8000}" --worker-class gthread \
  --workers "${WEB_CONCURRENCY:-2}" --threads 64 --timeout 120 --graceful-timeout 30 \
  --access-logfile - --forwarded-allow-ips "*"
