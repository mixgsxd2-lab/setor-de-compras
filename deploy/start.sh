#!/bin/sh
# Inicialização em PaaS (Render): aplica migrações e sobe o gunicorn na porta $PORT.
set -eu
cd /app/backend
if [ -n "${RG_MIGRATION_DATABASE_URL:-}" ]; then
  RG_DATABASE_URL="$RG_MIGRATION_DATABASE_URL" python -m rg.cli migrar
else
  python -m rg.cli migrar
fi
# Chave de cifragem: usa RG_ENCRYPTION_KEYS se definida; senão deriva (Fernet) de RG_SECRET_KEY.
if [ -z "${RG_ENCRYPTION_KEYS:-}" ]; then
  RG_ENCRYPTION_KEYS="$(python -c "import base64,hashlib,os;print(base64.urlsafe_b64encode(hashlib.sha256(os.environ['RG_SECRET_KEY'].encode()).digest()).decode())")"
  export RG_ENCRYPTION_KEYS
fi
# Plano free não tem Shell: cria o administrador a partir de RG_ADMIN_EMAIL/NOME/SENHA, se informados.
if [ -n "${RG_ADMIN_EMAIL:-}" ] && [ -n "${RG_ADMIN_SENHA:-}" ]; then
  python -m rg.cli criar-admin --nome "${RG_ADMIN_NOME:-Administrador}" --email "$RG_ADMIN_EMAIL" || echo "aviso: criar-admin falhou"
fi
exec gunicorn wsgi:app --bind "0.0.0.0:${PORT:-8000}" --worker-class gthread \
  --workers "${WEB_CONCURRENCY:-2}" --threads 64 --timeout 120 --graceful-timeout 30 \
  --access-logfile - --forwarded-allow-ips "*"
