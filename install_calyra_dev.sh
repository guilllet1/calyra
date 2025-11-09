#!/bin/bash
set -e

echo "🚀 Installation automatique de la stack Calyra (Camunda + Appsmith + PostgreSQL + Elasticsearch + Mongo + Redis + Nginx)"

# 1. Préparation
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# 2. Pare-feu UFW
echo "🛡️ Configuration du pare-feu UFW..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment "Allow SSH from anywhere"
sudo ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
sudo ufw enable
sudo ufw status verbose

# 3. Docker CE
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

# 4. Arborescence
echo "📂 Création des répertoires..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs,data/elasticsearch}
cd /opt/calyra

# 5. Correction des droits Elasticsearch
echo "🔧 Correction des droits pour Elasticsearch..."
chown -R 1000:1000 ./data/elasticsearch || true
chmod -R 755 ./data/elasticsearch || true
echo "✅ Droits Elasticsearch corrigés (UID 1000)"

# 6. Clonage ou mise à jour du dépôt Git
if [ ! -d ".git" ]; then
  echo "📥 Clonage du dépôt Git Calyra..."
  git clone https://github.com/guilllet1/calyra.git /opt/calyra
else
  echo "🔄 Mise à jour du dépôt existant..."
  git -C /opt/calyra pull
fi

# 7. Démarrage de la stack
echo "🚀 Démarrage de la stack Docker..."
docker compose down || true
docker compose up -d

# 8. Initialisation Mongo Replica Set
echo "🧠 Initialisation du Replica Set MongoDB..."
sleep 15
docker exec -it mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval '
rs.initiate({
  _id: "rs0",
  members: [{ _id: 0, host: "mongodb:27017" }]
})'

echo "✅ Installation terminée avec succès !"
docker ps

