#!/bin/bash
set -e

# ==========================================================
# 🚀 Installation complète de la stack Calyra (Camunda 8.8 + Appsmith + PostgreSQL + Elasticsearch + Nginx)
# ==========================================================

echo "🧱 Préparation du serveur..."
apt update -y && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# === Pare-feu ===
echo "🛡️ Configuration du pare-feu UFW..."
yes | sudo ufw reset > /dev/null 2>&1 || true
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment "Allow SSH from anywhere"
sudo ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
yes | sudo ufw enable > /dev/null 2>&1 || true
sudo ufw status verbose || true

# === Docker ===
echo "🐋 Installation de Docker..."
apt remove -y docker docker-engine docker.io containerd runc || true
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# === Arborescence ===
echo "📂 Création de l’arborescence..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs}
cd /opt/calyra

# === Clé MongoDB ===
echo "🔑 Génération de la clé MongoDB..."
openssl rand -base64 756 > ./data/mongo_key/mongodb-keyfile
chmod 400 ./data/mongo_key/mongodb-keyfile
chown 999:999 ./data/mongo_key/mongodb-keyfile

# === docker-compose.yml ===
echo "⚙️ Création du docker-compose.yml..."
cat > docker-compose.yml <<'EOF'
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

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.19.5
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - network.host=0.0.0.0
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    user: "0:0"
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost:9200/_cluster/health || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 10
    networks:
      - calyra_net

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    depends_on:
      elasticsearch:
        condition: service_healthy
    environment:
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
    entrypoint: >
      /bin/sh -c "
        echo 'Waiting for Elasticsearch...';
        until wget -q --spider http://elasticsearch:9200; do
          sleep 5;
        done;
        echo 'Elasticsearch ready, cleaning lock files...';
        rm -f /usr/share/elasticsearch/data/node.lock || true;
        echo 'Starting Operate...';
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
      - camunda
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
EOF

# === NGINX Configuration ===
echo "🌐 Configuration Nginx..."
cat > ./nginx/conf.d/appsmith.conf <<'NGINX_APPSMITH'
server {
    listen 80;
    server_name appsmith.ddns.net;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name appsmith.ddns.net;

    ssl_certificate     /etc/ssl/private/fullchain.pem;
    ssl_certificate_key /etc/ssl/private/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://appsmith:80/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_APPSMITH

cat > ./nginx/conf.d/camunda.conf <<'NGINX_CAMUNDA'
server {
    listen 80;
    server_name camunda.ddns.net;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name camunda.ddns.net;

    ssl_certificate     /etc/ssl/private/fullchain.pem;
    ssl_certificate_key /etc/ssl/private/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://operate:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_CAMUNDA

# === Initialisation MongoDB Replica Set ===
echo "🧠 Initialisation du replica set MongoDB..."
docker compose up -d mongodb
sleep 10
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval \
'rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongodb:27017" }] })' || true
sleep 5

# === Lancement Stack ===
echo "🚀 Lancement complet de la stack..."
docker compose up -d

echo "✅ Installation terminée avec succès !"
echo "🌐 Appsmith : https://appsmith.ddns.net"
echo "🌐 Camunda Operate : https://camunda.ddns.net"
echo "ℹ️ Vérifiez les conteneurs avec : docker ps"

