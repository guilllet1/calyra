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
fi

# =====================================================
# 1️⃣ Préparation du système
# =====================================================
echo "🧱 Préparation du serveur..."
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# =====================================================
# 2 Configuration du pare-feu
# =====================================================
echo "🛡️ Configuration du pare-feu UFW..."

# Vérifier si UFW est installé ; l'installer si nécessaire
if ! command -v ufw >/dev/null 2>&1; then
    apt update
    apt install -y ufw
else
    echo "UFW est déjà installé."
fi

# Vérifier si UFW est déjà activé et configuré comme souhaité
ufw_status=$(ufw status verbose 2>/dev/null)

# Fonction pour vérifier les politiques par défaut
check_defaults() {
    echo "$ufw_status" | grep -q "Default: deny (incoming), allow (outgoing)"
}

# Fonction pour vérifier la règle SSH (port 22/tcp allow from anywhere)
check_ssh_rule() {
    echo "$ufw_status" | grep -q "22/tcp *ALLOW IN *Anywhere"
}

# Fonction pour vérifier la règle IP spécifique (allow from 81.65.164.42)
check_ip_rule() {
    echo "$ufw_status" | grep -q "Anywhere *ALLOW IN *81.65.164.42"
}

# Vérification globale
if ufw status | grep -q "Status: active" && check_defaults && check_ssh_rule && check_ip_rule; then
    echo "🛡️ Le pare-feu UFW est déjà configuré comme souhaité. Configuration sautée."
    ufw status verbose  # Afficher le statut pour confirmation
else
    # Procéder à la configuration si pas déjà OK
    ufw --force reset  # Attention : cela efface les règles existantes, utilisez avec prudence !
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment "Allow SSH from anywhere"
    ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
    ufw --force enable
    ufw status verbose
fi

# =====================================================
# 2️⃣ Installation Docker CE
# =====================================================
echo "🐋 Installation de Docker CE..."

# Vérifier et supprimer les paquets existants seulement si nécessaire
if dpkg -l | grep -q docker; then
    apt remove -y docker docker-engine docker.io containerd runc || true
else
    echo "Aucun paquet Docker existant à supprimer."
fi

# Créer le répertoire des clés si nécessaire
if [ ! -d /etc/apt/keyrings ]; then
    mkdir -p /etc/apt/keyrings
else
    echo "Répertoire /etc/apt/keyrings existe déjà."
fi

# Ajouter la clé GPG seulement si elle n'existe pas
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
else
    echo "Clé GPG Docker existe déjà."
fi

# Ajouter le dépôt APT seulement si le fichier n'existe pas
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
else
    echo "Fichier de dépôt Docker existe déjà."
fi

# Mettre à jour APT (toujours safe, mais on peut vérifier si nécessaire)
apt update

# Installer les paquets seulement si Docker n'est pas installé
if ! command -v docker >/dev/null 2>&1; then
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "Paquets Docker déjà installés."
fi

# Activer le service seulement s'il n'est pas déjà enabled/active
if ! systemctl is-enabled --quiet docker; then
    systemctl enable --now docker
else
    echo "Service Docker déjà activé."
fi

# =====================================================
# 3️⃣ Arborescence
# =====================================================
echo "📂 Création de l’arborescence..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs}

cd /opt/calyra
echo "📂 Supprimer le répertoire de données corrompu ..."
rm -rf ./data/elasticsearch
mkdir -p ./data/elasticsearch
chown -R 1000:1000 ./data/elasticsearch
chmod -R 775 ./data/elasticsearch

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
echo "🔐 Vérification des certificats SSL pour appsmith.ddns.net..."
CERT_PATH="/opt/calyra/certs/live/appsmith.ddns.net"
FULLCHAIN="$CERT_PATH/fullchain.pem"
PRIVKEY="$CERT_PATH/privkey.pem"

if [[ -f "$FULLCHAIN" && -f "$PRIVKEY" ]]; then
  echo "✅ Certificats SSL déjà présents, aucune régénération nécessaire."
else
  echo "⚙️ Aucun certificat trouvé — génération avec Certbot..."

  # Assurer que les répertoires existent et ont les bonnes permissions
  mkdir -p /opt/calyra/nginx/html/.well-known/acme-challenge
  mkdir -p /opt/calyra/certs
  chown -R root:root /opt/calyra/certs  # Assurer des permissions sécurisées
  chmod 700 /opt/calyra/certs

  # Créer un fichier de configuration temporaire pour Nginx
  TEMP_CONF="/opt/calyra/nginx/conf.d/temp-certbot.conf"
  cat > "$TEMP_CONF" <<'CONF'
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

  # Temporairement ouvrir le port 80 dans UFW (si UFW est actif)
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "🛡️ Ouverture temporaire du port 80 pour la validation Certbot..."
    ufw allow 80/tcp comment "Temporary for Certbot"
    ufw reload
  fi

  # Supprimer le conteneur nginx-temp s'il existe déjà (pour éviter les conflits)
  docker rm -f nginx-temp >/dev/null 2>&1 || true

  # Lancer le conteneur Nginx temporaire
  docker run -d --name nginx-temp \
    -p 80:80 \
    -v "$TEMP_CONF:/etc/nginx/conf.d/default.conf:ro" \
    -v /opt/calyra/nginx/html:/usr/share/nginx/html:ro \
    nginx:latest || { echo "❌ Échec du lancement de Nginx temporaire."; exit 1; }

  # Attendre que Nginx soit prêt (optionnel, mais utile pour la robustesse)
  sleep 5

  # Lancer Certbot pour obtenir les certificats
  docker run -it --rm \
    -v /opt/calyra/certs:/etc/letsencrypt \
    -v /opt/calyra/nginx/html:/usr/share/nginx/html \
    certbot/certbot certonly --webroot \
    -w /usr/share/nginx/html \
    -d appsmith.ddns.net \
    --agree-tos --no-eff-email -m admin@appsmith.ddns.net || { echo "❌ Échec de la génération des certificats."; docker stop nginx-temp; docker rm nginx-temp; exit 1; }

  # Arrêter et supprimer le conteneur Nginx temporaire
  docker stop nginx-temp && docker rm nginx-temp

  # Supprimer le fichier de config temporaire
  rm -f "$TEMP_CONF"

  # Fermer le port 80 dans UFW si ouvert temporairement
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "🛡️ Fermeture du port 80 après validation Certbot..."
    ufw delete allow 80/tcp
    ufw reload
  fi

  # Vérifier que les certificats ont bien été générés
  if [[ -f "$FULLCHAIN" && -f "$PRIVKEY" ]]; then
    ls -l "$CERT_PATH/"
    echo "✅ Certificats SSL générés avec succès."
  else
    echo "❌ Les certificats n'ont pas été générés correctement."
    exit 1
  fi
fi

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

    ssl_certificate     /etc/ssl/private/live/appsmith.ddns.net/fullchain.pem;
    ssl_certificate_key /etc/ssl/private/live/appsmith.ddns.net/privkey.pem;

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

# === Initialisation MongoDB Replica Set ===
echo "🧠 Initialisation du replica set MongoDB..."
docker compose up -d mongodb
sleep 10
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval \
'rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongodb:27017" }] })' || true
sleep 5

# =====================================================
# 8 Démarrage de la stack
# =====================================================
echo "🚀 Démarrage de la stack Calyra..."
docker compose up -d

echo "✅ Installation terminée."
echo "🌐 Accès :"
echo "   - Appsmith : https://appsmith.ddns.net/"
echo "   - Camunda Operate : https://camunda.ddns.net/"
