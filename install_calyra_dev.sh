#!/bin/bash
set -e

echo "🚀 Installation automatique de la stack Calyra (Camunda + Appsmith + PostgreSQL + Elasticsearch + Mongo + Redis + Nginx)"

# 1. Mises à jour et dépendances
echo "📦 Mise à jour du système..."
apt update && apt upgrade -y
apt install -y curl wget vim git ufw ca-certificates lsb-release gnupg openssl jq

# 2. Pare-feu UFW
echo "🛡️ Configuration du pare-feu UFW..."

# Supprimer tout verrou éventuel
if [ -f /run/ufw.lock ]; then
  echo "🔓 Suppression du verrou UFW existant..."
  rm -f /run/ufw.lock
fi

# Réinitialiser et configurer les règles
{
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment "Allow SSH from anywhere"
  ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
  yes | ufw enable
  echo "✅ Pare-feu configuré avec succès."
} || {
  echo "⚠️ Erreur lors de la configuration UFW, tentative de déverrouillage..."
  rm -f /run/ufw.lock
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment "Allow SSH from anywhere"
  ufw allow from 81.65.164.42 comment "Allow everything from trusted IP"
  yes | ufw enable
  echo "✅ Pare-feu configuré après correction du verrou."
}

ufw status verbose

# 3. Installation Docker
echo "🐋 Installation de Docker CE..."
apt remove -y docker docker-engine docker.io containerd runc || true
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker --version && docker compose version

# 4. Arborescence
echo "📂 Création de l’arborescence..."
mkdir -p /opt/intranet-stack/{data/mongo,data/mongo_key,data/postgres,data/redis,data/appsmith-stacks,nginx/conf.d,certs}
cd /opt/intranet-stack

# 5. Génération clé Mongo
echo "🔑 Génération de la clé MongoDB..."
openssl rand -base64 756 > ./data/mongo_key/mongodb-keyfile
chmod 400 ./data/mongo_key/mongodb-keyfile
chown 999:999 ./data/mongo_key/mongodb-keyfile

echo "✅ Préparation terminée. Tu peux maintenant placer ton docker-compose.yml et lancer :"
echo "   docker compose up -d"

