#!/bin/bash
set -e

echo "🚀 Installation complète de la stack CALYRA (Camunda + Appsmith + PostgreSQL + Elasticsearch + Mongo + Redis + Nginx)"
sleep 2

# ========================
# 🧱 1. Préparation système
# ========================
echo "🧱 Mise à jour du système..."
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# ========================
# 🛡️ 2. Configuration du pare-feu UFW
# ========================
echo "🛡️ Configuration du pare-feu UFW..."

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment "Allow SSH from anywhere"
sudo ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
sudo ufw enable
sudo ufw status verbose

# ========================
# 🐋 3. Installation de Docker CE
# ========================
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
usermod -aG docker $SUDO_USER || true

# ========================
# 📂 4. Création de l’arborescence
# ========================
echo "📂 Création de l’arborescence dans /opt/calyra..."

mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs}
cd /opt/calyra

# ========================
# 🔑 5. Génération de la clé MongoDB
# ========================
echo "🔑 Génération de la clé MongoDB..."
openssl rand -base64 756 > ./data/mongo_key/mongodb-keyfile
chmod 400 ./data/mongo_key/mongodb-keyfile
chown 999:999 ./data/mongo_key/mongodb-keyfile

# ========================
# 🧠 6. Création du fichier docker-compose.yml
# ========================
echo "⚙️  Création du fichier docker-compose.yml..."

cat > /opt/calyra/docker-compose.yml <<'EOF'
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
      - xpack.security.enabled=false
      - network.host=0.0.0.0
      - network.publish_host=elasticsearch
      - http.port=9200
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fsSL http://localhost:9200/_cluster/health || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 50
    networks:
      - calyra_net

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    restart: always
    environment:
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
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
      - operate
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

# ========================
# 🧠 7. Initialisation MongoDB (replica set)
# ========================
echo "🧠 Initialisation de MongoDB..."
docker compose up -d mongodb
sleep 15
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval 'rs.initiate({_id:"rs0", members:[{_id:0, host:"mongodb:27017"}]})'

# ========================
# 🚀 8. Lancement de la stack
# ========================
echo "🚀 Lancement de la stack Calyra..."
docker compose up -d

echo "✅ Installation terminée !"
echo "🌐 Appsmith : https://appsmith.ddns.net"
echo "🌐 Camunda Operate : https://camunda.ddns.net"

