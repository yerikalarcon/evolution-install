#!/usr/bin/env bash
# instala-evolution.sh — Evolution API + Docker Compose + Nginx reverse-proxy (Ubuntu 24.x)
# Idempotente: puede ejecutarse múltiples veces sin romper el estado.
# Requisitos: dominio apuntando a este servidor y certificado wildcard listo.

set -euo pipefail

### === Parámetros ===
if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <DOMINIO> [--cert RUTA_CERT] [--key RUTA_KEY] [--allow-origins \"https://a,https://b\"] [--apikey CLAVE] [--port 8080]"
  exit 1
fi

DOMAIN="$1"; shift || true
CERT_PATH="**REEMPLAZAR_AQUI_CERT_PATH**"
KEY_PATH="**REEMPLAZAR_AQUI_KEY_PATH**"
ALLOW_ORIGINS="*"
APIKEY=""
API_PORT="8080"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT_PATH="${2:-}"; shift 2;;
    --key)  KEY_PATH="${2:-}"; shift 2;;
    --allow-origins) ALLOW_ORIGINS="${2:-}"; shift 2;;
    --apikey) APIKEY="${2:-}"; shift 2;;
    --port) API_PORT="${2:-8080}"; shift 2;;
    *) echo "Opción desconocida: $1"; exit 1;;
  esac
done

if [[ -z "$APIKEY" ]]; then
  # genera una clave aleatoria si no se proporciona
  APIKEY="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48)"
fi

if [[ "$CERT_PATH" == "**REEMPLAZAR_AQUI_CERT_PATH**" || "$KEY_PATH" == "**REEMPLAZAR_AQUI_KEY_PATH**" ]]; then
  echo "ATENCIÓN: Debes pasar --cert y --key con rutas válidas a tu wildcard SSL."
  echo "Ejemplo: --cert /etc/ssl/certs/fullchain.pem --key /etc/ssl/private/privkey.pem"
  exit 1
fi

### === Utilidades de impresión ===
info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
ok(){ echo -e "\e[32m[OK]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
err(){ echo -e "\e[31m[ERROR]\e[0m $*"; }

### === 1) Paquetes base & Docker ===
info "Actualizando índices APT..."
apt-get update -y

if ! command -v docker >/dev/null 2>&1; then
  info "Instalando Docker Engine y plugin compose (vía repo oficial Docker)..."
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker ya está instalado."
fi

### === 2) Estructura de proyecto ===
INSTALL_DIR="/opt/evolution"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

### === 3) docker-compose.yml ===
# Publica el contenedor sólo en localhost y Nginx hace el proxy con SSL.
cat > docker-compose.yml <<'YAML'
version: '3'
services:
  evolution-api:
    image: atendai/evolution-api
    container_name: evolution_api
    restart: always
    # Exponer sólo en loopback para que Nginx haga de reverse-proxy
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    env_file:
      - .env
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances

volumes:
  evolution_store:
  evolution_instances:
YAML

### === 4) .env de Evolution API ===
# Variables principales tomadas de la documentación:
# AUTHENTICATION_API_KEY, SERVER_URL, CORS_ORIGIN, Webhooks, WebSocket, Logs, etc.
cat > .env <<EOF
# Autenticación
AUTHENTICATION_TYPE=apikey
AUTHENTICATION_API_KEY=${APIKEY}

# URL pública (usada por enlaces internos y webhooks)
SERVER_URL=https://${DOMAIN}

# CORS (puedes restringir orígenes)
CORS_ORIGIN=${ALLOW_ORIGINS}
CORS_METHODS=POST,GET,PUT,DELETE
CORS_CREDENTIALS=true

# Webhooks globales hacia n8n (ajústalo a tu webhook de n8n)
WEBHOOK_GLOBAL_ENABLED=true
WEBHOOK_GLOBAL_URL=**REEMPLAZAR_AQUI_URL_WEBHOOK_N8N**

# WebSocket (para eventos en vivo y /docs si los usa)
WEBSOCKET_ENABLED=true
WEBSOCKET_GLOBAL_EVENTS=true

# Logs
LOG_LEVEL=INFO
LOG_COLOR=true

# Almacenamientos internos en volumen (persisten instancias y store)
# DATABASE_* opcional si deseas Mongo; Redis opcional.
# Ver documentación para más opciones.
EOF

# Sustituye la variable API_PORT en compose (simple envsubst)
sed -i "s|\${API_PORT}|${API_PORT}|g" docker-compose.yml

### === 5) Levantar contenedor ===
info "Descargando imagen y levantando Evolution API..."
/usr/bin/docker compose up -d
ok "Contenedor levantado."

### === 6) Nginx reverse-proxy (SSL + WebSocket) ===
info "Instalando Nginx y creando VirtualHost..."
apt-get install -y nginx

# Archivo del sitio
NGINX_SITE="/etc/nginx/sites-available/evolution.conf"
cat > "$NGINX_SITE" <<NGINX
# HTTP -> HTTPS (opcional, ya que usas wildcard SSL)
server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  return 301 https://\$host\$request_uri;
}

# HTTPS con wildcard SSL existente
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate ${CERT_PATH};
  ssl_certificate_key ${KEY_PATH};

  # Encabezados y ajustes recomendados
  client_max_body_size 20m;
  add_header X-Frame-Options SAMEORIGIN;
  add_header X-Content-Type-Options nosniff;
  add_header Referrer-Policy no-referrer-when-downgrade;

  # Proxy a Evolution en loopback
  location / {
    proxy_pass http://127.0.0.1:${API_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_cache_bypass \$http_upgrade;
  }

  # Estáticos: cache largo
  location ~* \.(jpg|jpeg|gif|png|webp|svg|woff|woff2|ttf|css|js|ico|xml)$ {
    expires 360d;
  }

  # Bloqueos básicos
  location ~ /\.ht { deny all; }
}
NGINX

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/evolution.conf
rm -f /etc/nginx/sites-enabled/default || true

info "Probando configuración Nginx..."
nginx -t
systemctl reload nginx
ok "Nginx recargado."

### === 7) Comprobación de salud básica ===
sleep 2
if curl -fsS "http://127.0.0.1:${API_PORT}/" | grep -qi "Evolution"; then
  ok "Evolution API responde en loopback."
  echo "Abre https://${DOMAIN}/docs para Swagger (usa header: apikey: ${APIKEY})"
else
  warn "No se detectó respuesta HTTP en loopback. Revisa 'docker logs evolution_api'."
fi

### === 8) Resumen y credenciales ===
echo "==========================================="
echo " Dominio:        https://${DOMAIN}"
echo " Swagger:        https://${DOMAIN}/docs"
echo " Header APIKEY:  apikey: ${APIKEY}"
echo " CORS:           ${ALLOW_ORIGINS}"
echo " Nginx vhost:    ${NGINX_SITE}"
echo " Proyecto:       ${INSTALL_DIR}"
echo "==========================================="

exit 0
