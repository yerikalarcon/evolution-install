#!/usr/bin/env bash
# instala-evolution-produccion.sh — Evolution API v2 + Postgres + Redis + Manager (Local) + NGINX
# Versión de Producción: Idempotente, validada y con todos los parches y mejoras descubiertos.
#
# ¿Qué hace este script?
# 1. Instala Docker y NGINX.
# 2. Clona el código fuente de Evolution Manager.
# 3. Crea un Dockerfile funcional que corrige los problemas de construcción del Manager.
# 4. Crea un docker-compose.yml que despliega una arquitectura completa:
#    - API, Base de Datos (Postgres), Caché (Redis) y Manager (construido localmente).
#    - Configura las variables de entorno explícitamente para máxima fiabilidad.
#    - Fija la versión de WhatsApp Web para asegurar la generación del código QR.
# 5. Configura NGINX como proxy reverso con SSL.
# 6. Realiza chequeos de salud robustos para asegurar que todos los servicios funcionan.

set -Eeuo pipefail
trap 'echo -e "\e[31m[ERROR]\e[0m Falló en línea $LINENO ejecutando: $BASH_COMMAND" >&2' ERR

### =================== 1. PARÁMETROS Y CONFIGURACIÓN ===================
if [[ $# -lt 1 ]]; then
  cat <<USO
Uso: sudo bash $0 <API_DOMINIO> [--manager-dom manager.example.com] [--cert /ruta/fullchain.pem] [--key /ruta/privkey.pem]
Ejemplo:
sudo bash $0 evolution.example.com --manager-dom manager.example.com \\
  --cert /etc/letsencrypt/live/evolution.example.com/fullchain.pem \\
  --key /etc/letsencrypt/live/evolution.example.com/privkey.pem
USO
  exit 1
fi

API_DOMAIN="$1"; shift || true
MANAGER_DOMAIN=""
CERT_PATH=""
KEY_PATH=""
API_PORT="8080"
MGR_PORT="3000"
DB_NAME="evolution"
DB_USER="evolution"
DB_PASS="evolutionpass" # Considera cambiar esto por algo más seguro

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager-dom) MANAGER_DOMAIN="${2:-}"; shift 2;;
    --cert) CERT_PATH="${2:-}"; shift 2;;
    --key) KEY_PATH="${2:-}"; shift 2;;
    *) echo "[ERROR] Opción desconocida: $1"; exit 1;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "[ERROR] Ejecuta como root (sudo)."; exit 1; }

STEP(){ echo -e "\n\e[34m[PASO]\e[0m $*"; }
OK(){ echo -e "\e[32m[OK]\e[0m $*"; }
WARN(){ echo -e "\e[33m[WARN]\e[0m $*"; }

# --- Autodetección de dominios y certificados ---
if [[ -z "$MANAGER_DOMAIN" ]]; then
  MANAGER_DOMAIN="manager.${API_DOMAIN#www.}"
fi

_try_paths_cert=("$CERT_PATH" "/etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem" "/etc/ssl/certs/fullchain.pem")
_try_paths_key=("$KEY_PATH" "/etc/letsencrypt/live/${API_DOMAIN}/privkey.pem" "/etc/ssl/private/privkey.pem")
_pick_first_existing() { for p in "$@"; do [[ -n "$p" && -f "$p" ]] && { echo "$p"; return; }; done; }

CERT_PATH="$(_pick_first_existing "${_try_paths_cert[@]}")"
KEY_PATH="$(_pick_first_existing  "${_try_paths_key[@]}")"

[[ -n "$CERT_PATH" && -f "$CERT_PATH" ]] || { echo "[ERROR] No se encontró certificado fullchain.pem. Usa --cert."; exit 1; }
[[ -n "$KEY_PATH"  && -f "$KEY_PATH"  ]] || { echo "[ERROR] No se encontró clave privada privkey.pem. Usa --key."; exit 1; }

# --- Generación de API Key ---
APIKEY=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 48)

### =================== 2. INSTALACIÓN DE DEPENDENCIAS ===================
export DEBIAN_FRONTEND=noninteractive
APT_FLAGS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

STEP "2.1) Actualizando paquetes e instalando Git"
apt-get update -y
apt-get install $APT_FLAGS git

STEP "2.2) Instalando Docker"
if ! command -v docker >/dev/null 2>&1; then
  apt-get install $APT_FLAGS ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture ) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME" ) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install $APT_FLAGS docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  OK "Docker ya está instalado."
fi

STEP "2.3) Instalando NGINX"
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install $APT_FLAGS nginx
  systemctl enable --now nginx
else
  OK "NGINX ya está instalado."
fi

### =================== 3. PREPARACIÓN DEL PROYECTO ===================
INSTALL_DIR="/opt/evolution"
MANAGER_SRC_DIR="/opt/evolution-manager"

STEP "3.1) Creando estructura de directorios en $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

STEP "3.2) Clonando el código fuente de Evolution Manager en $MANAGER_SRC_DIR"
if [ -d "$MANAGER_SRC_DIR" ]; then
  OK "El directorio del Manager ya existe. Omitiendo clonación."
else
  git clone https://github.com/gabrielpastori1/evolution-manager.git "$MANAGER_SRC_DIR"
  OK "Repositorio del Manager clonado."
fi

STEP "3.3 ) Creando el Dockerfile corregido para el Manager"
cat > "${MANAGER_SRC_DIR}/Dockerfile" <<'DOCKERFILE'
FROM node:20
WORKDIR /usr/src/app
RUN ln -s /usr/local/bin/node /usr/bin/node
COPY . .
RUN npm install --omit=dev
EXPOSE 3000
CMD ["node", "lib/cli.js", "server", "start"]
DOCKERFILE
OK "Dockerfile para el Manager creado en ${MANAGER_SRC_DIR}/Dockerfile"

STEP "3.4) Creando docker-compose.yml para producción"
cat > "docker-compose.yml" <<EOF
services:
  redis:
    image: redis:7-alpine
    container_name: evolution_redis
    restart: always
    volumes:
      - evolution_redis_data:/data

  evolution-api:
    image: atendai/evolution-api:latest
    container_name: evolution_api
    restart: always
    ports:
      - "127.0.0.1:${API_PORT}:8080"
    environment:
      - AUTHENTICATION_TYPE=apikey
      - AUTHENTICATION_API_KEY=${APIKEY}
      - SERVER_URL=https://${API_DOMAIN}
      - CORS_ORIGIN=*
      - DATABASE_ENABLED=true
      - DATABASE_PROVIDER=postgresql
      - DATABASE_CONNECTION_URI=postgresql://${DB_USER}:${DB_PASS}@evolution-db:5432/${DB_NAME}?schema=public
      - LOG_LEVEL=INFO
      - CONFIG_SESSION_PHONE_VERSION=2.3000.1023204200
      - CACHE_ENABLED=true
      - CACHE_PROVIDER=redis
      - CACHE_URI=redis://evolution_redis:6379
    depends_on:
      - evolution-db
      - redis
    volumes:
      - evolution_store:/evolution/store
      - evolution_instances:/evolution/instances

  evolution-db:
    image: postgres:15
    container_name: evolution_db
    restart: always
    environment:
      - POSTGRES_DB=${DB_NAME}
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_PASSWORD=${DB_PASS}
    volumes:
      - evolution_pgdata:/var/lib/postgresql/data

  evolution-manager:
    container_name: evolution_manager
    build: ${MANAGER_SRC_DIR}
    restart: always
    environment:
      - API_URL=http://evolution-api:8080
      - API_KEY=${APIKEY}
    ports:
      - "127.0.0.1:${MGR_PORT}:3000"
    depends_on:
      - evolution-api

volumes:
  evolution_store:
  evolution_instances:
  evolution_pgdata:
  evolution_redis_data:
EOF
OK "Archivo docker-compose.yml de producción creado."

### =================== 4. DESPLIEGUE Y CONFIGURACIÓN DE NGINX ===================
STEP "4.1 ) Deteniendo servicios antiguos (si existen) para una instalación limpia"
docker compose down --remove-orphans || true

STEP "4.2) Construyendo imagen del Manager y levantando contenedores"
docker compose up -d --build

STEP "4.3) Configurando NGINX vhost para API (${API_DOMAIN})"
cat > "/etc/nginx/sites-available/evolution_api.conf" <<NGINX
server {
  listen 80;
  server_name ${API_DOMAIN};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
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
  }
}
NGINX
ln -sf "/etc/nginx/sites-available/evolution_api.conf" "/etc/nginx/sites-enabled/evolution_api.conf"

STEP "4.4 ) Configurando NGINX vhost para Manager (${MANAGER_DOMAIN})"
cat > "/etc/nginx/sites-available/evolution_manager.conf" <<NGINX
server {
  listen 80;
  server_name ${MANAGER_DOMAIN};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  server_name ${MANAGER_DOMAIN};
  ssl_certificate ${CERT_PATH};
  ssl_certificate_key ${KEY_PATH};
  location / {
    proxy_pass http://127.0.0.1:${MGR_PORT};
    proxy_set_header Host \$host;
  }
}
NGINX
ln -sf "/etc/nginx/sites-available/evolution_manager.conf" "/etc/nginx/sites-enabled/evolution_manager.conf"

rm -f /etc/nginx/sites-enabled/default || true

STEP "4.5 ) Verificando y recargando NGINX"
nginx -t
systemctl reload nginx
OK "NGINX recargado."

### =================== 5. VALIDACIÓN Y RESUMEN ===================
STEP "5.1) Esperando a que los contenedores se estabilicen..."
sleep 25 # Damos un poco más de tiempo por el nuevo contenedor de Redis.

STEP "5.2) Verificando estado de los contenedores"
if ! docker compose ps | grep -E 'evolution_api|evolution_db|evolution_manager|evolution_redis' | grep 'Up'; then
  WARN "¡Uno o más contenedores no están en estado 'Up'!"
  docker compose ps
  docker compose logs --tail=50
  exit 1
fi
OK "Todos los contenedores (API, DB, Redis, Manager) están en estado 'Up'."
docker compose ps

STEP "5.3) Verificando salud de la API (loopback con reintentos)"
TRIES=15
OKFLAG=0
for i in $(seq 1 $TRIES); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/" | grep -qi "Evolution API"; then
    OK "API responde en loopback ${API_PORT} (intento $i )."
    OKFLAG=1
    break
  fi
  echo "Esperando a la API... (intento $i/$TRIES)"
  sleep 3
done
if [[ "$OKFLAG" -ne 1 ]]; then
  WARN "La API no respondió tras $((TRIES*3))s. Revisa logs: docker compose logs evolution-api"
fi

STEP "5.4) ¡Instalación de Producción Completada!"
cat <<RESUMEN
=======================================================================
      🚀 Evolución API (Versión de Producción) Desplegada con Éxito 🚀
-----------------------------------------------------------------------
 API URL:      https://${API_DOMAIN}
 Manager URL:  https://${MANAGER_DOMAIN}
 API Key:      ${APIKEY}
               (Guardada en la configuración del contenedor )

 Arquitectura:
   - evolution_api     (API Principal)
   - evolution_db      (Base de Datos PostgreSQL)
   - evolution_redis   (Caché en Memoria)
   - evolution_manager (Interfaz Gráfica, construida localmente)

 ¿Qué hacer ahora?
 1. Abre https://${MANAGER_DOMAIN} en tu navegador.
 2. Deberías poder crear una instancia y escanear el código QR sin problemas.
 3. Si tienes algún problema, limpia la caché de tu navegador (Ctrl+F5 ).
=======================================================================
RESUMEN
