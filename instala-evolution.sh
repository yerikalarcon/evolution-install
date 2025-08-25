#!/usr/bin/env bash
# instala-evolution.sh — Evolution API v2 + Postgres + Evolution Manager + NGINX (Ubuntu 24.x)
# Idempotente: seguro de re-ejecutar. Publica contenedores sólo en loopback; NGINX hace el proxy TLS.
# Requiere: wildcard SSL válido y DNS apuntado a este servidor para api.

set -Eeuo pipefail
trap 'echo -e "\e[31m[ERROR]\e[0m Falló en línea $LINENO ejecutando: $BASH_COMMAND" >&2' ERR

### =================== PARÁMETROS ===================
if [[ $# -lt 1 ]]; then
  cat <<USO
Uso: sudo bash $0 <API_DOMINIO> [--cert /ruta/fullchain.pem] [--key /ruta/privkey.pem] \
[--allow-origins "*|https://a,https://b"] [--apikey CLAVE] [--api-port 8080] [--mgr-port 3000] \
[--db-name evolution] [--db-user evolution] [--db-pass evolutionpass]
Ejemplo:
sudo bash $0 evolution.urmah.ai \
  --cert /etc/ssl/certificados/fullchain.pem --key /etc/ssl/certificados/privkey.pem \
  --allow-origins "*" --apikey "MI_SUPER_KEY"
USO
  exit 1
fi

API_DOMAIN="$1"; shift || true
CERT_PATH=""
KEY_PATH=""
ALLOW_ORIGINS="*"
APIKEY=""
API_PORT="8080"
MGR_PORT="3000"
DB_NAME="evolution"
DB_USER="evolution"
DB_PASS="evolutionpass"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT_PATH="${2:-}"; shift 2;;
    --key) KEY_PATH="${2:-}"; shift 2;;
    --allow-origins) ALLOW_ORIGINS="${2:-*}"; shift 2;;
    --apikey) APIKEY="${2:-}"; shift 2;;
    --api-port) API_PORT="${2:-8080}"; shift 2;;
    --mgr-port) MGR_PORT="${2:-3000}"; shift 2;;
    --db-name) DB_NAME="${2:-evolution}"; shift 2;;
    --db-user) DB_USER="${2:-evolution}"; shift 2;;
    --db-pass) DB_PASS="${2:-evolutionpass}"; shift 2;;
    *) echo "[ERROR] Opción desconocida: $1"; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "[ERROR] Ejecuta como root (sudo)."; exit 1; }

STEP(){ echo -e "\e[34m[STEP]\e[0m $*"; }
OK(){ echo -e "\e[32m[OK]\e[0m $*"; }
WARN(){ echo -e "\e[33m[WARN]\e[0m $*"; }

# Autodetección de certs si no se pasaron
_try_paths_cert=(
  "$CERT_PATH"
  "/etc/ssl/certificados/fullchain.pem"
  "/etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem"
  "/etc/ssl/certs/fullchain.pem"
)
_try_paths_key=(
  "$KEY_PATH"
  "/etc/ssl/certificados/privkey.pem"
  "/etc/letsencrypt/live/${API_DOMAIN}/privkey.pem"
  "/etc/ssl/private/privkey.pem"
)
_pick_first_existing() { for p in "$@"; do [[ -n "$p" && -f "$p" ]] && { echo "$p"; return; }; done; }

CERT_PATH="$(_pick_first_existing "${_try_paths_cert[@]}")"
KEY_PATH="$(_pick_first_existing  "${_try_paths_key[@]}")"

[[ -n "$CERT_PATH" && -f "$CERT_PATH" ]] || { echo "[ERROR] No se encontró fullchain.pem. Usa --cert o coloca en /etc/ssl/certificados/fullchain.pem"; exit 1; }
[[ -n "$KEY_PATH"  && -f "$KEY_PATH"  ]] || { echo "[ERROR] No se encontró privkey.pem. Usa --key o coloca en /etc/ssl/certificados/privkey.pem"; exit 1; }

if [[ -z "$APIKEY" ]]; then
  APIKEY=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48 || true)
fi

# Normaliza allow-origins a cadena para CORS_ORIGIN (v2)
format_allow_origins_for_env() {
  local raw="$1"
  if [[ "$raw" == "*" ]]; then echo "*"; return; fi
  if [[ "$raw" == \[*\] ]]; then raw=$(echo "$raw" | sed -E 's/[\[\]"]//g' | tr -d " "); fi
  echo "$raw" | tr -d " "
}
ALLOW_ORIGINS_ENV="$(format_allow_origins_for_env "$ALLOW_ORIGINS")"

### =================== INSTALACIÓN BASE ===================
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

STEP "1) Paquetes base + Docker"
apt-get update -y
if ! command -v docker >/dev/null 2>&1; then
  apt-get install $APT_FLAGS ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install $APT_FLAGS docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  OK "Docker ya instalado."
fi

STEP "2) NGINX"
apt-get install $APT_FLAGS nginx
systemctl enable --now nginx

### =================== ARCHIVOS DEL PROYECTO ===================
STEP "3) Estructura en /opt/evolution"
INSTALL_DIR="/opt/evolution"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

STEP "4) .env para Evolution API + Manager"
cat > .env <<EOF
# --- Auth ---
AUTHENTICATION_TYPE=apikey
AUTHENTICATION_API_KEY=${APIKEY}

# --- Public URL (API) ---
SERVER_URL=https://${API_DOMAIN}

# --- CORS ---
CORS_ORIGIN=${ALLOW_ORIGINS_ENV}
CORS_METHODS=POST,GET,PUT,DELETE
CORS_CREDENTIALS=true

# --- Webhooks ---
WEBHOOK_GLOBAL_ENABLED=true
WEBHOOK_GLOBAL_URL=**REEMPLAZAR_AQUI_URL_WEBHOOK_N8N**

# --- WebSocket ---
WEBSOCKET_ENABLED=true
WEBSOCKET_GLOBAL_EVENTS=true

# --- Logs ---
LOG_LEVEL=INFO
LOG_COLOR=true

# --- Database ---
DATABASE_ENABLED=true
DATABASE_PROVIDER=postgresql
DATABASE_CONNECTION_URI=postgresql://${DB_USER}:${DB_PASS}@evolution-db:5432/${DB_NAME}?schema=public
EOF
chmod 600 .env || true

STEP "5) docker-compose.yml (API + DB + Manager)"
cat > docker-compose.yml <<EOF
services:
  evolution-api:
    image: atendai/evolution-api
    container_name: evolution_api
    restart: always
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    env_file:
      - .env
    depends_on:
      - evolution-db
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances

  evolution-db:
    image: postgres:15
    container_name: evolution_db
    restart: always
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - evolution_pgdata:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"

  evolution-manager:
    image: atendai/evolution-manager
    container_name: evolution_manager
    restart: always
    environment:
      API_URL: http://evolution-api:8080
      API_KEY: ${APIKEY}
    ports:
      - "127.0.0.1:${MGR_PORT}:3000"
    depends_on:
      - evolution-api

volumes:
  evolution_store:
  evolution_instances:
  evolution_pgdata:
EOF

STEP "6) Levantar contenedores"
docker compose pull
docker compose up -d
sleep 2
docker compose ps

### =================== NGINX (SOLO API, Manager via /manager) ===================
STEP "7) NGINX vhost para API (${API_DOMAIN})"
API_SITE="/etc/nginx/sites-available/evolution_api.conf"
cat > "$API_SITE" <<NGINX
server {
  listen 80;
  listen [::]:80;
  server_name ${API_DOMAIN};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${API_DOMAIN};

  ssl_certificate ${CERT_PATH};
  ssl_certificate_key ${KEY_PATH};

  client_max_body_size 20m;

  location / {
    proxy_pass http://127.0.0.1:${API_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
NGINX

ln -sf "$API_SITE" /etc/nginx/sites-enabled/evolution_api.conf
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl reload nginx
OK "NGINX recargado"

### =================== CHEQUEOS RÁPIDOS ===================
STEP "8) Salud local (loopback, con reintentos)"
TRIES=15
OKFLAG=0
for i in $(seq 1 $TRIES); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/" | grep -qi "Evolution API"; then
    OK "API responde en loopback ${API_PORT} (intento $i)"
    OKFLAG=1
    break
  fi
  sleep 2
done
if [[ "$OKFLAG" -ne 1 ]]; then
  WARN "API no respondió tras $((TRIES*2))s. Revisa: docker compose logs evolution-api"
fi

STEP "9) Resumen"
cat <<RESUMEN
==============================================
 API URL:     https://${API_DOMAIN}
 Manager:     https://${API_DOMAIN}/manager
 API Key:     (guardada en ${INSTALL_DIR}/.env)
 CORS:        ${ALLOW_ORIGINS_ENV}
 Proyecto:    ${INSTALL_DIR}
 Contenedores:
   - evolution_api    (puerto interno 8080 -> ${API_PORT})
   - evolution_db     (5432)
   - evolution_manager(puerto interno 3000 -> ${MGR_PORT})
==============================================
RESUMEN
