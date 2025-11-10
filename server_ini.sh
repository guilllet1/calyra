#!/bin/bash
set -e
clear
echo "🚀 SERVEUR INITIALISATION"
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

if command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    echo "🐋 Docker est déjà installé et en cours d'exécution. Installation sautée."
else
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

    # Mettre à jour APT
    apt update

    # Installer les paquets
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Activer le service
    systemctl enable --now docker
fi
