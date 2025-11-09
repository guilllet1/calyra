#!/bin/bash
set -e

echo "⚠️  Nettoyage de toute installation existante de Calyra..."

# Arrêter et supprimer containers + volumes + réseau existants
if [ -d "/opt/calyra" ]; then
  cd /opt/calyra || exit 1
  if [ -f "docker-compose.yml" ]; then
    docker compose down -v || true
  fi
  cd /opt
  rm -rf /opt/calyra
fi

# === 1. Préparation du serveur ===
echo "🧱 Préparation du serveur..."
apt update -y && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# === 2. Configuration pare-feu UFW (non-interactive) ===
echo "🛡️ Configuration du pare-feu UFW..."
yes | ufw reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "Allow SSH from anywhere"
ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
yes | ufw enable
ufw status verbose

# === 3. Installation Docker CE ===
echo "🐋 Installation de Docker CE..."
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

# === 4. Création arborescence Calyra ===
echo "📂 Création des dossiers..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs,data/elasticsearch}
cd /opt/calyra

# === 5. Génération clé MongoDB (auth + replica set) ===
echo "🔑 Génération de la clé MongoDB..."
openssl rand -base64 756 > ./data/mongo_key/mongodb-keyfile
chmod 400 ./data/mongo_key/mongodb-keyfile
chown 999:999 ./data/mongo_key/mongodb-keyfile

# === 6. Corriger les permissions Elasticsearch (UID 1000) ===
echo "🔧 Réglage des permissions Elasticsearch..."
chown -R 1000:1000 ./data/elasticsearch
chmod -R 775 ./data/elasticsearch

# === 7. Génération certificats SSL auto-signés si absents ===
echo "🔒 Vérification / génération certificats SSL..."
if [ ! -f "./certs/fullchain.pem" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout ./certs/privkey.pem \
    -out ./certs/fullchain.pem \
    -days 365 \
    -subj "/CN=*.ddns.net/O=CalYra Dev/C=FR"
fi

# === 8. Configuration Nginx ===
echo "🧩 Configuration Nginx..."
cat > ./nginx/conf.d/appsmith.conf <<'EOF'
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
        proxy_pass http://appsmith:80;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
EOF

cat > ./nginx/conf.d/camunda.conf <<'EOF'
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
        proxy_pass http://operate:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
EOF

# === 9. Création du docker-compose.yml ===
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
    user: "1000:1000"
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
      - xpack.security.enabled=false
      - network.host=0.0.0.0
      - http.port=9200
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:9200 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 50
    networks:
      - calyra_net

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    environment:
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
    depends_on:
      elasticsearch:
        condition: service_healthy
    networks:
      - calyra_net

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    depends_on:
      - appsmith
      - camunda
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./certs:/etc/ssl/private
      - ./certs/challenges:/etc/ssl/private/challenges
    ports:
      - "80:80"
      - "443:443"
    networks:
      - calyra_net

networks:
  calyra_net:
    driver: bridge
EOF

# === 10. Initialisation MongoDB ReplicaSet ===
echo "🧠 Initialisation du replica set MongoDB..."
docker compose up -d mongodb
sleep 15
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval '
rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongodb:27017" }] })
'
sleep 5
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval "rs.status()"

# === 11. Lancement complet de la stack ===
echo "🚀 Lancement de tous les services..."
docker compose up -d

echo "✅ Installation terminée avec succès !"
echo "🌐 Appsmith : https://appsmith.ddns.net"
echo "🌐 Camunda Operate : https://camunda.ddns.net"

