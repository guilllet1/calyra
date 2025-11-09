#!/bin/bash
set -e

echo "🚀 Installation complète de la stack Intranet (Camunda + Appsmith + PostgreSQL + Mongo + Redis + Elasticsearch + Nginx)"
sleep 2

# ===============================
# 1. Mises à jour et prérequis
# ===============================
echo "🧱 Mise à jour du système..."
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# ===============================
# 2. Sécurisation UFW
# ===============================
echo "🛡️ Configuration du pare-feu UFW..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment "Allow SSH"
sudo ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
sudo ufw allow 80/tcp comment "Allow HTTP"
sudo ufw allow 443/tcp comment "Allow HTTPS"
sudo ufw --force enable
sudo ufw status verbose

# ===============================
# 3. Installation de Docker CE
# ===============================
echo "🐋 Installation de Docker..."
apt remove -y docker docker-engine docker.io containerd runc || true
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# ===============================
# 4. Création de l’arborescence
# ===============================
echo "📂 Création des répertoires..."
mkdir -p /opt/intranet-stack/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,data/elasticsearch,nginx/conf.d,certs,certs/challenges}
cd /opt/intranet-stack

# ===============================
# 5. Clé MongoDB
# ===============================
echo "🔑 Génération de la clé MongoDB..."
openssl rand -base64 756 > ./data/mongo_key/mongodb-keyfile
chmod 400 ./data/mongo_key/mongodb-keyfile
chown 999:999 ./data/mongo_key/mongodb-keyfile

# ===============================
# 6. Permissions Elasticsearch
# ===============================
echo "🧠 Configuration des permissions Elasticsearch..."
rm -rf ./data/elasticsearch/*
mkdir -p ./data/elasticsearch
chown -R 1000:1000 ./data/elasticsearch
chmod -R 775 ./data/elasticsearch

# ===============================
# 7. Création du docker-compose.yml
# ===============================
echo "⚙️ Création du fichier docker-compose.yml..."
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
      - intranet_net

  redis:
    image: redis:7
    container_name: redis
    restart: always
    volumes:
      - ./data/redis:/data
    networks:
      - intranet_net

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
      - intranet_net

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.19.5
    container_name: elasticsearch
    restart: always
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - xpack.security.http.ssl.enabled=false
      - network.host=0.0.0.0
      - http.port=9200
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost:9200/_cluster/health || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 50
    networks:
      - intranet_net

  camunda:
    image: camunda/zeebe:8.8.0
    container_name: camunda
    restart: always
    depends_on:
      - postgres
      - elasticsearch
    environment:
      - ZEEBE_BROKER_CLUSTER_PARTITIONSCOUNT=1
      - ZEEBE_BROKER_CLUSTER_REPLICATIONFACTOR=1
      - ZEEBE_BROKER_CLUSTER_CLUSTERSIZE=1
      - ZEEBE_BROKER_GATEWAY_NETWORK_HOST=0.0.0.0
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_CLASSNAME=io.camunda.zeebe.exporter.ElasticsearchExporter
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_URL=http://elasticsearch:9200
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_BULK_DELAY=5
      - ZEEBE_BROKER_EXPORTERS_ELASTICSEARCH_ARGS_INDEX_PREFIX=zeebe-record
    networks:
      - intranet_net

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    restart: always
    depends_on:
      elasticsearch:
        condition: service_healthy
    environment:
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
      - SPRING_PROFILES_ACTIVE=dev
    entrypoint: >
      /bin/sh -c "
        echo 'Waiting for Elasticsearch...';
        until wget -q --spider http://elasticsearch:9200; do sleep 5; done;
        echo 'Elasticsearch ready, starting Operate...';
        exec /usr/local/operate/bin/operate;
      "
    networks:
      - intranet_net

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
      - intranet_net

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
      - ./certs/challenges:/etc/ssl/private/challenges
    ports:
      - "80:80"
      - "443:443"
    networks:
      - intranet_net

networks:
  intranet_net:
    driver: bridge
EOF

# ===============================
# 8. Démarrage initial Mongo + ReplicaSet
# ===============================
echo "🧠 Initialisation du Replica Set MongoDB..."
docker compose up -d mongodb
sleep 10
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval '
rs.initiate({
  _id: "rs0",
  members: [{ _id: 0, host: "mongodb:27017" }]
});
rs.status();
'

# ===============================
# 9. Lancement de la stack complète
# ===============================
echo "🚀 Démarrage complet de la stack..."
docker compose up -d
docker compose ps

echo "✅ Installation terminée !
🌐 Appsmith : https://appsmith.ddns.net
🌐 Camunda Operate : https://camunda.ddns.net
"
