#!/bin/bash
set -e
clear
echo "🚀 Installation complète de Calyra Dev Stack (Camunda 8 + Appsmith + PostgreSQL + Elasticsearch + Nginx)"

# =====================================================
# 0️⃣ Nettoyage si installation précédente détectée
# =====================================================
if [ -d "/opt/calyra" ]; then
  echo "🧹 Suppression d'une installation existante..."
  docker compose -f /opt/calyra/docker-compose.yml down || true
  rm -rf /opt/calyra
fi

# =====================================================
# 1️⃣ Préparation du système
# =====================================================
echo "🧱 Préparation du serveur..."
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# Pare-feu
echo "🛡️ Configuration du pare-feu UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "Allow SSH from anywhere"
ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
ufw --force enable
ufw status verbose

# =====================================================
# 2️⃣ Installation Docker CE
# =====================================================
echo "🐋 Installation de Docker CE..."
apt remove -y docker docker-engine docker.io containerd runc || true
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# =====================================================
# 3️⃣ Arborescence
# =====================================================
echo "📂 Création de l’arborescence..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs}

cd /opt/calyra

# =====================================================
# 4️ Génération clé MongoDB
# =====================================================
echo "🔑 Génération de la clé MongoDB..."
openssl rand -base64 756 > ./data/mongo_key/mongodb-keyfile
chmod 400 ./data/mongo_key/mongodb-keyfile
chown 999:999 ./data/mongo_key/mongodb-keyfile

# =====================================================
# 5 Génération des certificats
# =====================================================
echo "🔏 Génération des certificats Let's Encrypt..."
mkdir -p /opt/calyra/nginx/html/.well-known/acme-challenge
cat > /opt/calyra/nginx/conf.d/temp-certbot.conf <<'CONF'
server {
    listen 80;
    server_name appsmith.ddns.net;

    # Répertoire utilisé par Certbot pour le challenge
    root /usr/share/nginx/html;

    location /.well-known/acme-challenge/ {
        allow all;
    }

    # Réponse par défaut pour tout le reste
    location / {
        return 200 'Temporary Nginx running for Certbot validation\n';
        add_header Content-Type text/plain;
    }
}
CONF
docker run -d --name nginx-temp \
  -p 80:80 \
  -v /opt/calyra/nginx/conf.d/temp-certbot.conf:/etc/nginx/conf.d/default.conf:ro \
  -v /opt/calyra/nginx/html:/usr/share/nginx/html:ro \
  nginx:latest
docker run -it --rm \
  -v /opt/calyra/certs:/etc/letsencrypt \
  -v /opt/calyra/nginx/html:/usr/share/nginx/html \
  certbot/certbot certonly --webroot \
  -w /usr/share/nginx/html \
  -d appsmith.ddns.net \
  --agree-tos --no-eff-email -m admin@appsmith.ddns.net
docker run -it --rm \
  -v /opt/calyra/certs:/etc/letsencrypt \
  -v /opt/calyra/nginx/html:/usr/share/nginx/html \
  certbot/certbot certonly --webroot \
  -w /usr/share/nginx/html \
  -d camunda.ddns.net \
  --agree-tos --no-eff-email -m admin@camunda.ddns.net
docker stop nginx-temp && docker rm nginx-temp
ls -l /opt/calyra/certs/live/appsmith.ddns.net/
ls -l /opt/calyra/certs/live/camunda.ddns.net/

# =====================================================
# 6 docker-compose.yml
# =====================================================
echo "🧩 Création du docker-compose.yml..."

cat > docker-compose.yml <<'YAML'
services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: camunda
      POSTGRES_PASSWORD: camundapass
      POSTGRES_DB: camunda
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - calyra_net

  redis:
    image: redis:7
    container_name: redis
    restart: always
    volumes:
      - ./data/redis:/data
    networks:
      - calyra_net

  mongodb:
    image: mongo:6
    container_name: mongodb
    restart: always
    command: ["--replSet", "rs0", "--bind_ip_all", "--keyFile", "/data/key/mongodb-keyfile"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: appsmith
      MONGO_INITDB_ROOT_PASSWORD: appsmithpass
    volumes:
      - ./data/mongo:/data/db
      - ./data/mongo_key:/data/key
    networks:
      - calyra_net

  appsmith:
    image: appsmith/appsmith-ce
    container_name: appsmith
    restart: always
    depends_on:
      - redis
      - mongodb
    environment:
      - APPSMITH_REDIS_URL=redis://redis:6379
      - APPSMITH_MONGODB_URI=mongodb://appsmith:appsmithpass@mongodb:27017/appsmith?authSource=admin&replicaSet=rs0
      - APPSMITH_DISABLE_TELEMETRY=true
      - APPSMITH_MAIL_ENABLED=false
      - APPSMITH_CUSTOM_DOMAIN=https://appsmith.ddns.net
      - APPSMITH_ROOT_REDIRECT_URL=/
    volumes:
      - ./data/appsmith-stacks:/appsmith-stacks
    networks:
      - calyra_net

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.19.5
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - network.host=0.0.0.0
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    user: "1000:1000"
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fsSL http://localhost:9200/_cluster/health || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 50
    networks:
      - calyra_net

  camunda:
    image: camunda/zeebe:8.8.0
    container_name: camunda
    restart: always
    environment:
      - ZEEBE_BROKER_CLUSTER_PARTITIONSCOUNT=1
      - ZEEBE_BROKER_CLUSTER_REPLICATIONFACTOR=1
      - ZEEBE_BROKER_CLUSTER_CLUSTERSIZE=1
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_CLASSNAME=io.camunda.zeebe.exporter.ElasticsearchExporter
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_INDEX_PREFIX=zeebe-record
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_BULK_DELAY=5
      - ZEEBE_BROKER_GATEWAY_NETWORK_HOST=0.0.0.0
      - SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/camunda
      - SPRING_DATASOURCE_USERNAME=camunda
      - SPRING_DATASOURCE_PASSWORD=camundapass
    depends_on:
      - postgres
    networks:
      - calyra_net

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    depends_on:
      elasticsearch:
        condition: service_healthy
    environment:
      - CAMUNDA_OPERATE_ELASTICSEARCH_URL=http://elasticsearch:9200
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
    entrypoint: >
      /bin/sh -c "
        echo 'Waiting for Elasticsearch...';
        until wget -q --spider http://elasticsearch:9200; do
          sleep 5;
        done;
        echo 'Elasticsearch ready. Starting Operate...';
        exec /usr/local/operate/bin/operate;
      "
    networks:
      - calyra_net

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    depends_on:
      - appsmith
      - operate
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./certs:/etc/ssl/private
    ports:
      - "80:80"
      - "443:443"
    networks:
      - calyra_net

networks:
  calyra_net:
    driver: bridge
YAML

# =====================================================
# 7 Configuration Nginx
# =====================================================
echo "🌐 Configuration Nginx..."

cat > nginx/conf.d/appsmith.conf <<'CONF'
server {
    listen 80;
    server_name appsmith.ddns.net;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name appsmith.ddns.net;

    ssl_certificate     /etc/ssl/private/live/appsmith.ddns.net/fullchain.pem;
    ssl_certificate_key /etc/ssl/private/live/appsmith.ddns.net/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://appsmith:80/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
CONF

cat > nginx/conf.d/camunda.conf <<'CONF'
server {
    listen 80;
    server_name camunda.ddns.net;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name camunda.ddns.net;

    ssl_certificate     /etc/ssl/private/live/camunda.ddns.net/fullchain.pem;
    ssl_certificate_key /etc/ssl/private/live/camunda.ddns.net/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://operate:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
CONF

# =====================================================
# 8 Démarrage de la stack
# =====================================================
echo "🚀 Démarrage de la stack Calyra..."
docker compose up -d

echo "✅ Installation terminée."
echo "🌐 Accès :"
echo "   - Appsmith : https://appsmith.ddns.net/"
echo "   - Camunda Operate : https://camunda.ddns.net/"
