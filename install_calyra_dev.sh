#!/bin/bash
set -e

echo "🚀 Installation automatique de la stack Calyra (Camunda + Appsmith + PostgreSQL + Elasticsearch + Mongo + Redis + Nginx)"

# 1️⃣ Préparation du serveur
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# 2️⃣ Configuration pare-feu UFW (sans confirmation)
echo "🛡️ Configuration du pare-feu UFW..."

# Forcer le reset sans interaction ni rupture SSH
yes | sudo ufw reset > /dev/null 2>&1 || true

sudo ufw --force default deny incoming
sudo ufw --force default allow outgoing
sudo ufw --force allow 22/tcp comment "Allow SSH from anywhere"
sudo ufw --force allow from 81.65.164.42 comment "Allow everything from trusted IP"
yes | sudo ufw enable > /dev/null 2>&1 || true

echo "✅ Pare-feu configuré :"
sudo ufw status verbose || true

# 3️⃣ Installation Docker CE
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

# 4️⃣ Création de l’arborescence /opt/calyra
echo "📂 Création des répertoires..."
mkdir -p /opt/calyra/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs,data/elasticsearch}
cd /opt/calyra

# 5️⃣ Correction des droits pour Elasticsearch
echo "🔧 Correction des droits pour Elasticsearch..."
chown -R 1000:1000 ./data/elasticsearch || true
chmod -R 755 ./data/elasticsearch || true
echo "✅ Droits Elasticsearch corrigés (UID 1000)"

# 6️⃣ Clonage ou mise à jour du dépôt Git
if [ ! -d ".git" ]; then
  echo "📥 Clonage du dépôt Git Calyra..."
  git clone https://github.com/guilllet1/calyra.git /opt/calyra
else
  echo "🔄 Mise à jour du dépôt existant..."
  git -C /opt/calyra pull
fi

# 7️⃣ Démarrage de la stack
echo "🚀 Démarrage de la stack Docker..."
docker compose down || true
docker compose up -d

# 8️⃣ Initialisation Mongo Replica Set
echo "🧠 Initialisation du Replica Set MongoDB..."
sleep 15
docker exec -i mongodb mongosh -u appsmith -p appsmithpass --authenticationDatabase admin --eval '
rs.initiate({
  _id: "rs0",
  members: [{ _id: 0, host: "mongodb:27017" }]
})' || true

echo "✅ Installation terminée avec succès !"
docker ps

