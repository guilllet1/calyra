#!/bin/bash
set -e
clear
echo "🚀 Installation complète de Calyra Dev Stack (Camunda 8 + Appsmith + PostgreSQL + Elasticsearch + Nginx)"

# Fonction pour générer un mot de passe aléatoire si non défini
generate_password() {
  openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20
}

# =====================================================
# 🔧 Chargement du fichier de configuration (obligatoire)
# =====================================================

# Déterminer le chemin absolu du script et du fichier config associé
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Vérifier la présence du fichier config.env
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ Fichier de configuration manquant : $CONFIG_FILE"
  echo "👉 Créez un fichier config.env dans le même répertoire que ce script"
fi

# Charger les variables depuis config.env
echo "⚙️ Chargement de la configuration depuis : $CONFIG_FILE"
set -a
source "$CONFIG_FILE"
set +a

# Vérification des valeurs nécessaires
if [ -z "$POSTGRES_PASSWORD" ] || [ -z "$MONGODB_PASSWORD" ]; then
  echo "❌ Les variables POSTGRES_PASSWORD et/ou MONGODB_PASSWORD sont absentes dans $CONFIG_FILE"
  echo "👉 Exemple attendu :"
  echo "POSTGRES_PASSWORD=motdepassePostgres"
  echo "MONGODB_PASSWORD=motdepasseMongo"
  exit 1
fi

echo "🔑 Mots de passe chargés :"
echo "   - PostgreSQL : $POSTGRES_PASSWORD"
echo "   - MongoDB : $MONGODB_PASSWORD"



# =====================================================
# 0️⃣ Nettoyage si installation précédente détectée
# =====================================================
if [ -d "/opt/calyra" ]; then
  echo "🧹 Une installation existante de Calyra a été détectée."

  # Répertoires de données à préserver
  PG_VOLUME="/opt/calyra/data/postgres"
  MONGO_VOLUME="/opt/calyra/data/mongo"
  APPSMITH_STACKS="/opt/calyra/data/appsmith-stacks"
  APPSMITH_DATA="/opt/calyra/data/appsmith-data"

  # Vérification de l’existence des conteneurs
  PG_EXISTS=$(docker ps -a --format '{{.Names}}' | grep -c '^postgres$' || true)
  MONGO_EXISTS=$(docker ps -a --format '{{.Names}}' | grep -c '^mongodb$' || true)
  DB_PRESERVE=false

  # Détection des volumes de bases de données existants
  if [[ -d "$PG_VOLUME" || -d "$MONGO_VOLUME" || $PG_EXISTS -gt 0 || $MONGO_EXISTS -gt 0 ]]; then
    echo "🛑 Des bases de données PostgreSQL ou MongoDB ont été détectées."
    echo "   👉 Ces données seront préservées par défaut."
    DB_PRESERVE=true
  fi

  echo ""
  echo "Souhaitez-vous réinitialiser l’installation (hors bases et données Appsmith) ? (y/n)"
  read -r confirm

  if [[ $confirm =~ ^[Yy]$ ]]; then
    echo "🧼 Arrêt des services Docker..."
    docker compose -f /opt/calyra/docker-compose.yml down || true

    echo "🧽 Nettoyage des fichiers (en conservant bases & données Appsmith)..."
    find /opt/calyra/ -mindepth 1 -maxdepth 1 \
      -not -path '/opt/calyra/certs*' \
      -not -path "$PG_VOLUME" \
      -not -path "$MONGO_VOLUME" \
      -not -path "$APPSMITH_STACKS" \
      -not -path "$APPSMITH_DATA" \
      -exec rm -rf {} + 2>/dev/null || true

    echo "✅ Nettoyage terminé :"
    echo "   - Bases PostgreSQL et MongoDB préservées"
    echo "   - Volumes Appsmith persistants conservés"
  else
    echo "❌ Installation annulée."
    exit 0
  fi
fi


# =====================================================
# 3️⃣ Arborescence
# =====================================================
echo "📂 Création de l’arborescence..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,nginx/html,certs,live/appsmith.ddns.net}

cd /opt/calyra

# Permissions pour les volumes (adaptées aux images Docker)
mkdir -p ./data/elasticsearch
chown -R 1000:1000 ./data/elasticsearch  # Pour Elasticsearch
chmod -R 775 ./data/elasticsearch

mkdir -p ./data/postgres
chown -R 70:70 ./data/postgres  # UID pour postgres dans l'image PostgreSQL est souvent 70 ou 999, mais 70 est courant pour postgres:15

mkdir -p ./data/redis
chown -R 999:999 ./data/redis  # Pour Redis

mkdir -p ./data/mongo
chown -R 999:999 ./data/mongo  # Pour MongoDB

# =====================================================
# 4️ Génération clé MongoDB
# =====================================================
echo "🔑 Génération de la clé MongoDB..."
KEYFILE="./data/mongo_key/mongodb-keyfile"
if [ ! -f "$KEYFILE" ]; then
  openssl rand -base64 756 > "$KEYFILE"
  chmod 400 "$KEYFILE"
  chown 999:999 "$KEYFILE"
else
  echo "🔑 Clé MongoDB existe déjà. Génération sautée."
fi

# =====================================================
# 5 Génération des certificats
# =====================================================
echo "🔏 Génération des certificats Let's Encrypt..."
echo "🔐 Vérification des certificats SSL pour appsmith.ddns.net et camunda.ddns.net..."
CERT_PATH="/opt/calyra/certs/live/appsmith.ddns.net"  # Utiliser un dossier commun, mais cert multi-domaines
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

  # Créer un fichier de configuration temporaire pour Nginx (ajuster pour multi-domaines si besoin)
  TEMP_CONF="/opt/calyra/nginx/conf.d/temp-certbot.conf"
  cat > "$TEMP_CONF" <<'CONF'
server {
    listen 80;
    server_name appsmith.ddns.net camunda.ddns.net;

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

  # Attendre que Nginx soit prêt
  sleep 5

  # Lancer Certbot pour obtenir les certificats (ajouter les deux domaines)
  docker run -it --rm \
    -v /opt/calyra/certs:/etc/letsencrypt \
    -v /opt/calyra/nginx/html:/usr/share/nginx/html \
    certbot/certbot certonly --webroot \
    -w /usr/share/nginx/html \
    -d appsmith.ddns.net -d camunda.ddns.net \
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
COMPOSE_FILE="docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  cat > "$COMPOSE_FILE" <<'YAML'
services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: calyrausername
      POSTGRES_PASSWORD: XXXXPostgreSQL
      POSTGRES_DB: calyra
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "calyrausername"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7
    container_name: redis
    restart: always
    volumes:
      - ./data/redis:/data
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongodb:
    image: mongo:6
    container_name: mongodb
    restart: always
    command: ["--replSet", "rs0", "--bind_ip_all", "--keyFile", "/data/key/mongodb-keyfile"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: mongousername
      MONGO_INITDB_ROOT_PASSWORD: XXXXMongoDB
    volumes:
      - ./data/mongo:/data/db
      - ./data/mongo_key:/data/key
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "mongosh -u mongousername -p XXXXMongoDB --authenticationDatabase admin --quiet --eval 'try { rs.status() } catch (e) { quit(1) }; quit(0)'"]
      interval: 10s
      timeout: 5s
      retries: 10  # Plus de retries pour donner du temps à l'init

  appsmith:
    image: appsmith/appsmith-ee:v1.90
    container_name: appsmith
    depends_on:
      redis:
        condition: service_healthy
      mongodb:
        condition: service_healthy
      postgres:
        condition: service_healthy
    environment:
      - APPSMITH_REDIS_URL=redis://redis:6379
      - APPSMITH_MONGODB_URI=mongodb://mongousername:XXXXMongoDB@mongodb:27017/appsmith?authSource=admin&replicaSet=rs0
      - APPSMITH_DISABLE_TELEMETRY=true
      - APPSMITH_MAIL_ENABLED=false
      - APPSMITH_CUSTOM_DOMAIN=https://appsmith.ddns.net
      - APPSMITH_ROOT_REDIRECT_URL=/
      - APPSMITH_LICENSE_KEY=37D050-462203-1D757A-07A569-F70C64-V3
      - APPSMITH_BACKEND_HOST=0.0.0.0
      - APPSMITH_AI_ENABLED=false
      - APPSMITH_POSTGRES_SSL_DISABLED=true
      - APPSMITH_INTERNAL_BACKEND_URL=http://localhost:8080
      - APPSMITH_RTS_POSTGRESQL_URL=postgresql://calyrausername:XXXXPostgreSQL@postgres:5432/calyra?sslmode=disable
    volumes:
      - ./data/appsmith-stacks:/appsmith-stacks
    ports:
      - "80:80"
      - "443:443"
    networks:
      - calyra_net
    healthcheck:
      disable: true

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.19.5
    container_name: elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - network.host=0.0.0.0
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    ulimits:
      memlock:
        soft: -1
        hard: -1
    ports:
      - "9200:9200"
    user: "1000:1000"
    volumes:
      - ./data/elasticsearch:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fs http://localhost:9200/_cluster/health || exit 1"]
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
      - SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/calyra
      - SPRING_DATASOURCE_USERNAME=calyrausername
      - SPRING_DATASOURCE_PASSWORD=XXXXPostgreSQL
    depends_on:
      postgres:
        condition: service_healthy
      elasticsearch:
        condition: service_healthy
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "timeout 3 bash -c '</dev/tcp/localhost/26500' && echo OK || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 30
      start_period: 60s

  operate:
    image: camunda/operate:8.8.0
    container_name: operate
    depends_on:
      elasticsearch:
        condition: service_healthy
      camunda:
        condition: service_healthy
    environment:
      - CAMUNDA_OPERATE_ELASTICSEARCH_URL=http://elasticsearch:9200
      - CAMUNDA_OPERATE_ZEEBE_GATEWAYADDRESS=camunda:26500
      - CAMUNDA_DATA_SECONDARY_STORAGE_ELASTICSEARCH_URL=http://elasticsearch:9200
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD", "wget", "--spider", "localhost:8080"]
      interval: 20s
      timeout: 10s
      retries: 30
      start_period: 120s

  adminer:
    image: adminer
    container_name: adminer
    restart: always
    depends_on:
      - postgres
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8080 || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 10

  nginx:
    image: nginx:latest
    container_name: nginx
    restart: always
    depends_on:
      appsmith:
        condition: service_healthy
      operate:
        condition: service_healthy
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./certs:/etc/ssl/private
    ports:
      - "80:80"
      - "443:443"
    networks:
      - calyra_net
    healthcheck:
      test: ["CMD-SHELL", "curl -k -f https://localhost || curl -f http://localhost || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 20
      start_period: 30s

networks:
  calyra_net:
    driver: bridge

YAML
else
  echo "🧩 docker-compose.yml existe déjà. Création sautée."
fi

# Remplacer les mots de passe dans docker-compose.yml
sed -i "s/XXXXPostgreSQL/$POSTGRES_PASSWORD/g" "$COMPOSE_FILE"
sed -i "s/XXXXMongoDB/$MONGODB_PASSWORD/g" "$COMPOSE_FILE"

# =====================================================
# 7 Configuration Nginx
# =====================================================
echo "🌐 Configuration Nginx..."

APPSMITH_CONF="nginx/conf.d/appsmith.conf"
if [ ! -f "$APPSMITH_CONF" ]; then
  cat > "$APPSMITH_CONF" <<'CONF'
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
else
  echo "🌐 appsmith.conf existe déjà."
fi

CAMUNDA_CONF="nginx/conf.d/camunda.conf"
if [ ! -f "$CAMUNDA_CONF" ]; then
  cat > "$CAMUNDA_CONF" <<'CONF'
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
else
  echo "🌐 camunda.conf existe déjà."
fi

ADMINER_CONF="nginx/conf.d/adminer.conf"
if [ ! -f "$ADMINER_CONF" ]; then
  cat > "$ADMINER_CONF" <<'CONF'
server {
    listen 80;
    server_name adminera.ddns.net;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name adminera.ddns.net;

    ssl_certificate     /etc/ssl/private/live/appsmith.ddns.net/fullchain.pem;
    ssl_certificate_key /etc/ssl/private/live/appsmith.ddns.net/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://adminer:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
CONF
else
  echo "🌐 adminer.conf existe déjà."
fi

# === Initialisation MongoDB Replica Set ===
echo "⏳ Attente de MongoDB pour devenir responsive..."
docker compose up -d mongodb
retries=0
until docker exec mongodb mongosh --quiet --eval "db.adminCommand('ping')" > /dev/null 2>&1; do
  retries=$((retries+1))
  if [ $retries -ge 20 ]; then
    echo "❌ MongoDB ne répond pas après 20 tentatives. Vérifiez les logs avec 'docker logs mongodb'."
    exit 1
  fi
  sleep 5
done
echo "✅ MongoDB est accessible."

docker exec mongodb mongosh -u mongousername -p "$MONGODB_PASSWORD" --authenticationDatabase admin --quiet --eval '
try {
  const status = rs.status();
  print("✅ ReplicaSet déjà initialisé (" + status.set + ")");
} catch (e) {
  print("⚙️ Initialisation du ReplicaSet...");
  rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongodb:27017" }] });
}
'
echo "🧩 Initialisation de mongousername..."
docker exec -it mongodb mongosh -u mongousername -p "$MONGODB_PASSWORD" --authenticationDatabase admin --quiet --eval 'db.getSiblingDB("admin").grantRolesToUser("mongousername", [{ role: "readWrite", db: "appsmith" }])'

sleep 5


# =====================================================
# 8 Démarrage de la stack
# =====================================================
echo "🚀 Démarrage de la stack Calyra..."
docker compose up -d --wait  # --wait pour attendre que tous les services soient healthy

echo "✅ Installation terminée."
echo "🌐 Accès :"
echo "   - Appsmith : https://appsmith.ddns.net/"
echo "   - Camunda Operate : https://camunda.ddns.net/"
echo "   - Adminer : https://adminera.ddns.net/"
