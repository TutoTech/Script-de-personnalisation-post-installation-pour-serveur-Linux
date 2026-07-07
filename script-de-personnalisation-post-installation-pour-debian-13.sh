#!/bin/bash

################################################################################
# Script de configuration automatisée pour serveur Debian 13 (Trixie)
################################################################################
#
# Ce script configure un serveur Debian 13 minimal (sans interface graphique)
# avec les paramètres de base essentiels pour un environnement sécurisé.
#
# Fonctionnalités :
# - Coloration syntaxique du terminal root
# - Mise à jour complète du système
# - Configuration du clavier français
# - Modification du hostname
# - Configuration d'une IP fixe (systemd-networkd)
# - Création d'un utilisateur standard avec droits sudo
# - Sécurisation SSH (changement de port, désactivation accès root)
#
# Prérequis : Accès root (sudo)
# Compatible : Debian 13 (Trixie) serveur minimal
#
################################################################################

# Vérifier que le script est exécuté avec les privilèges administrateur
if [ "$(id -u)" -ne 0 ]; then
  echo "=========================================="
  echo "  ERREUR : PRIVILÈGES INSUFFISANTS"
  echo "=========================================="
  echo ""
  echo "Ce script doit être exécuté avec les privilèges administrateur."
  echo "Veuillez relancer le script avec la commande :"
  echo "  sudo $0"
  echo ""
  exit 1
fi

################################################################################
# FONCTION : Vérification des erreurs de commande
################################################################################
# Cette fonction vérifie le code de retour de la dernière commande exécutée.
# Si une erreur est détectée, elle propose de continuer ou d'arrêter le script.
################################################################################
check_command() {
  if [ $? -ne 0 ]; then
    echo ""
    echo "!!! ATTENTION : Une erreur s'est produite !!!"
    echo "La commande précédente a échoué."
    echo "Vérifiez les messages d'erreur ci-dessus pour plus de détails."
    echo ""
    read -p "Voulez-vous continuer malgré l'erreur ? (y/n) : " CONTINUE
    if [[ "$CONTINUE" != "y" ]]; then
      echo "Arrêt du script demandé par l'utilisateur."
      exit 1
    fi
    echo "Poursuite du script..."
    echo ""
  fi
}

################################################################################
# FONCTION : Afficher l'explication de la coloration syntaxique
################################################################################
# Cette fonction affiche une explication détaillée sur les avantages de la
# coloration syntaxique dans le terminal, particulièrement pour l'utilisateur root.
################################################################################
function afficher_explication() {
    clear
    echo "=========================================="
    echo "  EXPLICATION : COLORATION SYNTAXIQUE"
    echo "=========================================="
    echo ""
    echo "La coloration syntaxique améliore considérablement l'expérience"
    echo "d'utilisation du terminal en ajoutant des couleurs aux différents"
    echo "éléments affichés."
    echo ""
    echo "AVANTAGES PRINCIPAUX :"
    echo ""
    echo "1. PROMPT COLORÉ"
    echo "   - Le nom d'utilisateur apparaît en vert"
    echo "   - Le répertoire courant apparaît en bleu"
    echo "   - L'invite de commande ($) est clairement visible"
    echo "   → Vous savez toujours où vous êtes et sous quel utilisateur"
    echo ""
    echo "2. COMMANDE 'ls' COLORÉE"
    echo "   - Répertoires en bleu"
    echo "   - Fichiers exécutables en vert"
    echo "   - Archives en rouge"
    echo "   - Liens symboliques en cyan"
    echo "   → Identification instantanée du type de fichier"
    echo ""
    echo "3. COMMANDE 'grep' COLORÉE"
    echo "   - Les correspondances trouvées sont surlignées en rouge"
    echo "   → Repérage immédiat des résultats de recherche"
    echo ""
    echo "SÉCURITÉ :"
    echo "La coloration aide à prévenir les erreurs, notamment lors de"
    echo "l'utilisation du compte root (exemple : suppression accidentelle"
    echo "de fichiers dans le mauvais répertoire)."
    echo ""
    echo "=========================================="
    echo ""
}

################################################################################
# FONCTION : Activer la coloration syntaxique pour root
################################################################################
# Cette fonction configure le fichier ~/.bashrc de root pour activer :
# - Un prompt coloré (utilisateur en vert, chemin en bleu)
# - La coloration des commandes ls et grep
# - La configuration de dircolors pour les types de fichiers
################################################################################
function activer_coloration() {
    echo "========================================"
    echo "  ACTIVATION DE LA COLORATION"
    echo "========================================"
    echo ""
    echo "Configuration du fichier ~/.bashrc de root..."

    # Vérification et création de ~/.bashrc si nécessaire
    if [ ! -f /root/.bashrc ]; then
        echo "→ Fichier .bashrc non trouvé pour root"
        echo "→ Création du fichier /root/.bashrc..."
        touch /root/.bashrc
        echo "✓ Fichier créé"
    else
        echo "✓ Fichier .bashrc existant trouvé"
    fi

    # Ajout de la variable force_color_prompt si absente
    if ! grep -q "force_color_prompt=yes" /root/.bashrc; then
        echo ""
        echo "→ Activation forcée du prompt coloré..."
        echo "force_color_prompt=yes" >> /root/.bashrc
        echo "✓ Variable force_color_prompt ajoutée"
    else
        echo "✓ Variable force_color_prompt déjà présente"
    fi

    # Configuration du prompt PS1 coloré si absent
    if ! grep -q "PS1='\\\[\\\033\[01;32m\\\]\\\\u@\\\\h:\\\[\\\033\[01;34m\\\]\\\\w\\\[\\\033\[00m\\\]\\\\\$ '" /root/.bashrc; then
        echo ""
        echo "→ Configuration du prompt coloré (PS1)..."
        cat << 'EOF' >> /root/.bashrc

# Configuration du prompt coloré pour root
# Vert pour user@host, Bleu pour le chemin
if [ "$force_color_prompt" = yes ]; then
    if [ -n "$TERM" ] && [[ "$TERM" =~ (xterm|vt100|linux) ]]; then
        PS1='\[\033[01;32m\]\u@\h:\[\033[01;34m\]\w\[\033[00m\]\$ '
    fi
fi
EOF
        echo "✓ Prompt PS1 configuré"
    else
        echo "✓ Prompt PS1 déjà configuré"
    fi

    # Ajout de la configuration de dircolors et des alias colorés
    if ! grep -q "eval \"\$(dircolors" /root/.bashrc; then
        echo ""
        echo "→ Configuration des alias colorés (ls, grep)..."
        cat << 'EOF' >> /root/.bashrc

# Activation de la coloration pour ls et grep
if [ -x /usr/bin/dircolors ]; then
    eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi
EOF
        echo "✓ Alias colorés ajoutés"
    else
        echo "✓ Alias colorés déjà présents"
    fi

    echo ""
    echo "========================================"
    echo "  ✓ COLORATION CONFIGURÉE"
    echo "========================================"
    echo ""
    echo "Pour appliquer les changements, vous devez :"
    echo "1. Quitter cette session root (tapez 'exit')"
    echo "2. Vous reconnecter en tant que root"
    echo "   OU"
    echo "3. Exécuter : source /root/.bashrc"
    echo ""
}

################################################################################
# ÉTAPE 1 : CONFIGURATION DE LA COLORATION SYNTAXIQUE
################################################################################
echo ""
echo "╔════════════════════════════════════════╗"
echo "║   CONFIGURATION SERVEUR DEBIAN 13      ║"
echo "║            (Trixie)                    ║"
echo "╚════════════════════════════════════════╝"
echo ""

# Boucle principale pour la coloration syntaxique
while true; do
    echo "=========================================="
    echo "  ÉTAPE 1/7 : COLORATION SYNTAXIQUE"
    echo "=========================================="
    echo ""
    echo "Souhaitez-vous activer la coloration syntaxique pour"
    echo "l'utilisateur root dans la console ?"
    echo ""
    echo "Cela améliorera la lisibilité du terminal en ajoutant"
    echo "des couleurs au prompt et aux commandes."
    echo ""
    echo "Choix disponibles :"
    echo "  1. oui           - Activer la coloration"
    echo "  2. non           - Continuer sans coloration"
    echo "  3. explication - Afficher plus de détails"
    echo ""
    echo -n "Votre choix : "
    read -r choix

    case $choix in
    oui | 1)
        echo ""
        activer_coloration
        break
        ;;
    non | 2)
        echo ""
        echo "→ Coloration syntaxique désactivée"
        echo "  Vous pourrez l'activer manuellement plus tard."
        echo ""
        break
        ;;
    explication | 3)
        afficher_explication
        echo -n "Appuyez sur Entrée pour revenir au menu..."
        read
        clear
        ;;
    *)
        echo ""
        echo "⚠ Choix invalide. Veuillez entrer '1', '2', ou '3'."
        echo ""
        sleep 2
        ;;
    esac
done

################################################################################
# ÉTAPE 2 : MISE À JOUR DU SYSTÈME
################################################################################
# Il est CRUCIAL de mettre à jour le système en premier pour :
# - Corriger les failles de sécurité connues
# - Obtenir les dernières versions des paquets
# - Éviter les bugs résolus dans les versions récentes
################################################################################
echo ""
echo "=========================================="
echo "  ÉTAPE 2/7 : MISE À JOUR DU SYSTÈME"
echo "=========================================="
echo ""
echo "Cette étape va :"
echo "  1. Mettre à jour la liste des paquets disponibles (apt update)"
echo "  2. Installer les mises à jour de sécurité et correctifs (apt upgrade)"
echo ""
echo "⏱ Cette opération peut prendre plusieurs minutes selon"
echo "   votre connexion Internet et l'état du système."
echo ""
echo "Démarrage de la mise à jour..."
echo ""

# Mise à jour de la liste des paquets
apt update
check_command

# Installation des mises à jour
apt upgrade -y
check_command

echo ""
echo "✓ Système mis à jour avec succès"
echo ""

################################################################################
# ÉTAPE 3 : CONFIGURATION DU CLAVIER FRANÇAIS
################################################################################
# Configure le clavier pour la disposition AZERTY française, ce qui est
# essentiel pour une saisie confortable si vous utilisez un clavier français.
# Cette configuration affecte :
# - La console (terminal en mode texte)
# - Le serveur X si installé ultérieurement
################################################################################
echo ""
echo "=========================================="
echo "  ÉTAPE 3/7 : CONFIGURATION DU CLAVIER"
echo "=========================================="
echo ""
echo "Configuration du clavier en disposition française (AZERTY)..."
echo ""
echo "→ Installation des paquets nécessaires..."

# Installation des paquets de configuration clavier
apt-get install -y console-setup keyboard-configuration
check_command

echo ""
echo "→ Chargement de la disposition française..."
# Charge immédiatement le keymap français
loadkeys fr

echo "→ Configuration permanente du clavier..."
# Modifie la configuration par défaut du clavier
sed -i 's/XKBLAYOUT=.*/XKBLAYOUT="fr"/' /etc/default/keyboard

echo "→ Reconfiguration du paquet keyboard-configuration..."
# Applique la configuration
dpkg-reconfigure -f noninteractive keyboard-configuration

echo "→ Application de la configuration..."
# Applique immédiatement les changements
setupcon

echo ""
echo "✓ CLAVIER CONFIGURÉ EN FRANÇAIS"
echo ""
echo "  Les touches sont maintenant mappées en disposition AZERTY."
echo "  Exemple : A et Q sont inversés par rapport à QWERTY"
echo ""

################################################################################
# ÉTAPE 4 : CONFIGURATION DU HOSTNAME
################################################################################
# Le hostname est le nom de votre machine sur le réseau.
# Il est affiché dans le prompt et utilisé pour identifier le serveur.
# Un bon hostname est court, descriptif et unique sur votre réseau.
# Exemples : srv-web, db-principale, backup01
################################################################################
echo ""
echo "=========================================="
echo "  ÉTAPE 4/7 : CONFIGURATION DU HOSTNAME"
echo "=========================================="
echo ""
echo "Le hostname est le nom d'identification de votre serveur."
echo "Il apparaîtra dans le prompt de commande et sur le réseau."
echo ""
echo "Hostname actuel : $(hostname)"
echo ""
echo "Règles pour le hostname :"
echo "  - Lettres minuscules (a-z) et chiffres (0-9)"
echo "  - Tirets (-) autorisés (mais pas au début/fin)"
echo "  - Maximum 63 caractères"
echo "  - Pas d'espaces ni de caractères spéciaux"
echo ""
echo "Exemples : serveur-web, db01, backup-srv"
echo ""
read -p "Entrez le nouveau hostname (ou Entrée pour garder l'actuel) : " NEW_HOSTNAME

if [[ -n "$NEW_HOSTNAME" ]]; then
  echo ""
  echo "→ Modification du hostname en : $NEW_HOSTNAME"
   
  # Change le hostname immédiatement
  hostnamectl set-hostname "$NEW_HOSTNAME"
  check_command
   
  echo "→ Mise à jour du fichier /etc/hosts..."
  # Met à jour le fichier /etc/hosts pour la résolution locale
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
   
  # Si aucune entrée 127.0.1.1 n'existe, on l'ajoute
  if ! grep -q "^127\.0\.1\.1" /etc/hosts; then
      echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
  fi
   
  echo ""
  echo "✓ Hostname configuré : $NEW_HOSTNAME"
  echo "  Le nouveau nom sera actif après reconnexion."
  echo ""
else
  echo ""
  echo "→ Hostname inchangé : $(hostname)"
  echo ""
fi

################################################################################
# ÉTAPE 5 : CONFIGURATION RÉSEAU (IP FIXE)
################################################################################
# Cette étape configure une adresse IP fixe (statique) pour votre serveur.
# Utilise systemd-networkd, la méthode moderne recommandée pour Debian 13.
#
# Pourquoi une IP fixe ?
# - Nécessaire pour un serveur accessible depuis le réseau
# - Évite que l'IP change au redémarrage (contrairement au DHCP)
# - Permet de configurer des règles firewall et DNS stables
#
# systemd-networkd vs ifupdown :
# - systemd-networkd : moderne, intégré à systemd, recommandé pour serveurs
# - ifupdown : ancien système, toujours fonctionnel mais moins maintenu
################################################################################
echo ""
echo "=========================================="
echo "  ÉTAPE 5/7 : CONFIGURATION RÉSEAU"
echo "=========================================="
echo ""
echo "Configuration d'une adresse IP fixe (statique)."
echo ""
echo "Une IP fixe est recommandée pour un serveur car :"
echo "  - L'adresse ne change jamais (contrairement au DHCP)"
echo "  - Facilite l'accès distant et la configuration DNS"
echo "  - Permet des règles firewall stables"
echo ""
read -p "Souhaitez-vous configurer une IP fixe ? (y/n) : " CONFIGURE_IP

if [[ "$CONFIGURE_IP" == "y" ]]; then
  echo ""
  echo "→ Détection des interfaces réseau disponibles..."
  echo ""
  echo "Interfaces réseau détectées :"
  ip -o link show | awk -F': ' '{print "  - " $2}' | grep -v "lo"
  echo ""
  echo "Note : 'lo' (loopback) est l'interface locale, elle n'apparaît pas ici."
  echo ""
   
  read -p "Entrez le nom de l'interface réseau (ex: eth0, enp0s3, ens33) : " INTERFACE
  echo ""
   
  echo "Informations à fournir :"
  echo "  1. Adresse IP avec masque de sous-réseau en notation CIDR"
  echo "     Exemple : 192.168.1.100/24"
  echo "     /24 = masque 255.255.255.0 (réseau de 254 hôtes)"
  echo "     /16 = masque 255.255.0.0 (réseau de 65534 hôtes)"
  echo ""
  read -p "Entrez l'adresse IP fixe avec le masque (ex: 192.168.1.100/24) : " STATIC_IP
  echo ""
   
  echo "  2. Passerelle par défaut (gateway)"
  echo "     C'est généralement l'adresse IP de votre routeur/box"
  echo "     Exemple : 192.168.1.1 ou 192.168.0.254"
  echo ""
  read -p "Entrez l'adresse de la passerelle : " GATEWAY
  echo ""
   
  echo "  3. Serveurs DNS"
  echo "     Les serveurs DNS traduisent les noms de domaine en adresses IP"
  echo "     Exemples courants :"
  echo "       - Google : 8.8.8.8 et 8.8.4.4"
  echo "       - Cloudflare : 1.1.1.1 et 1.0.0.1"
  echo "       - Quad9 : 9.9.9.9 et 149.112.112.112"
  echo "       - Votre FAI : généralement fourni par votre box"
  echo ""
  read -p "Entrez le(s) serveur(s) DNS (séparés par des espaces) : " DNS_SERVERS

  # Vérification que toutes les informations sont fournies
  if [[ -z "$INTERFACE" || -z "$STATIC_IP" || -z "$GATEWAY" || -z "$DNS_SERVERS" ]]; then
    echo ""
    echo "⚠ ERREUR : Informations incomplètes"
    echo "La configuration réseau ne peut pas être effectuée."
    echo "Vous devrez la configurer manuellement après l'installation."
    echo ""
  else
    echo ""
    echo "=========================================="
    echo "  CONFIGURATION AVEC SYSTEMD-NETWORKD"
    echo "=========================================="
    echo ""
    echo "systemd-networkd est le gestionnaire réseau moderne de Debian 13."
    echo "Il remplace l'ancien système ifupdown."
    echo ""
     
    # Désactiver le service networking s'il est actif OU juste activé au boot
    # (ancien système ifupdown). On vérifie is-enabled en plus de is-active
    # car un service inactif mais toujours enabled démarrerait quand même au
    # prochain reboot et entrerait en conflit avec systemd-networkd.
    if systemctl is-active --quiet networking || systemctl is-enabled --quiet networking; then
      echo "→ Désactivation au démarrage de l'ancien service 'networking' (ifupdown)..."
      echo "  (arrêt différé au prochain redémarrage pour ne pas couper la connexion SSH actuelle)"
      # IMPORTANT : ne PAS utiliser --now ici. Ce service est probablement celui qui
      # a obtenu l'IP actuelle de la session en cours (via DHCP). Le stopper
      # immédiatement déclenche un "ifdown" qui flush cette IP et coupe la
      # connexion SSH en plein script (avant même que systemd-networkd ne soit
      # configuré), laissant le serveur sans réseau jusqu'au prochain accès console.
      systemctl disable networking
      check_command

      # Sauvegarde de l'ancien fichier de configuration
      if [ -f /etc/network/interfaces ]; then
        echo "→ Sauvegarde de /etc/network/interfaces..."
        mv /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d-%H%M%S)
        echo "  (sauvegardé avec horodatage)"
      fi
    fi
     
    echo ""
    echo "→ Activation de systemd-networkd..."
    # Active et démarre systemd-networkd
    systemctl enable systemd-networkd
    check_command
     
    echo "→ Création du répertoire de configuration..."
    # Crée le répertoire s'il n'existe pas
    mkdir -p /etc/systemd/network
     
    echo "→ Création du fichier de configuration pour $INTERFACE..."
    # Crée le fichier de configuration .network
    # Le préfixe "10-" définit la priorité (plus petit = prioritaire)
    cat <<EOF > /etc/systemd/network/10-${INTERFACE}.network
# Configuration réseau pour l'interface $INTERFACE
# Générée automatiquement par le script de configuration Debian 13
# Date : $(date)

[Match]
# Nom de l'interface réseau à configurer
Name=${INTERFACE}

[Network]
# Adresse IP statique avec masque de sous-réseau
Address=${STATIC_IP}

# Passerelle par défaut (routeur)
Gateway=${GATEWAY}

# Serveur(s) DNS pour la résolution de noms
DNS=${DNS_SERVERS}

[Link]
# Indique que cette interface est requise pour considérer le système "en ligne"
RequiredForOnline=yes
EOF
    check_command
     
    echo ""
    echo "→ Configuration enregistrée pour $INTERFACE."
    echo "⚠  La nouvelle configuration IP sera appliquée au prochain redémarrage."
    echo "   (Cela évite de couper votre connexion SSH actuelle)"
     
    echo ""
    echo "✓ CONFIGURATION RÉSEAU ENREGISTRÉE"
    echo ""
    echo "Récapitulatif (actif au prochain reboot) :"
    echo "  Interface    : $INTERFACE"
    echo "  IP fixe      : $STATIC_IP"
    echo "  Passerelle   : $GATEWAY"
    echo "  DNS          : $DNS_SERVERS"
    echo ""
  fi
else
  echo ""
  echo "→ Configuration réseau ignorée"
  echo "  Le serveur utilisera DHCP ou sa configuration actuelle."
  echo ""
fi

################################################################################
# ÉTAPE 6 : CRÉATION D'UN UTILISATEUR STANDARD
################################################################################
# Crée un utilisateur non-root avec privilèges sudo.
# C'est une BONNE PRATIQUE DE SÉCURITÉ :
# - Évite d'utiliser root au quotidien (limitation des risques)
# - Permet de tracer qui fait quoi (logs sudo)
# - Nécessaire si vous désactivez l'accès SSH root
#
# Règles de nommage Debian :
# - Commence par une lettre minuscule
# - Contient uniquement : a-z, 0-9, - (tiret), _ (underscore)
# - PAS de points, espaces, majuscules ou caractères accentués
################################################################################

echo ""
echo "=========================================="
echo "  ÉTAPE 6/7 : UTILISATEUR STANDARD"
echo "=========================================="
echo ""
echo "Création d'un compte utilisateur standard avec privilèges sudo."
echo ""
echo "POURQUOI CRÉER UN UTILISATEUR STANDARD ?"
echo "  - Sécurité : évite d'utiliser root en permanence"
echo "  - Traçabilité : les actions sudo sont enregistrées"
echo "  - Obligatoire si vous désactivez l'accès SSH root"
echo ""
echo "RÈGLES DE NOMMAGE :"
echo "  ✓ Doit commencer par une lettre minuscule (a-z)"
echo "  ✓ Peut contenir : lettres minuscules, chiffres, - et _"
echo "  ✗ PAS de : points (.), majuscules, espaces, accents"
echo ""
echo "Exemples VALIDES    : admin, jdupont, user-web, srv_admin"
echo "Exemples INVALIDES  : Admin, j.dupont, user web, john.doe"
echo ""

# Boucle principale pour la saisie du nom d'utilisateur
while true; do
  read -p "Nom de l'utilisateur (laissez vide pour ignorer) : " STANDARD_USER

  # Si l'utilisateur laisse vide, on sort de la boucle (skip)
  if [[ -z "$STANDARD_USER" ]]; then
    echo "Aucun utilisateur standard ne sera créé."
    break
  fi

  # 1. Validation du format (Regex)
  if [[ ! "$STANDARD_USER" =~ ^[a-z][-a-z0-9_]*$ ]]; then
    echo ""
    echo "⚠ ERREUR : Le format du nom '$STANDARD_USER' est invalide."
    echo "  (Le système refuse les points, majuscules ou caractères spéciaux)"
    
    # Génération de suggestion
    # On remplace les points et espaces par des tirets, et on met tout en minuscule
    SUGGESTION=$(echo "$STANDARD_USER" | tr '[:upper:]' '[:lower:]' | tr '.' '-' | tr ' ' '-')
    
    # Si la suggestion commence par un chiffre ou un tiret (invalide), on préfixe avec 'u'
    if [[ "$SUGGESTION" =~ ^[-0-9] ]]; then
        SUGGESTION="u$SUGGESTION"
    fi

    echo "  Suggestion : essayez '$SUGGESTION'"
    echo ""
    # On continue la boucle (re-demande le nom)
    continue
  fi

  # 2. Validation de l'existence (Est-ce que l'user existe déjà ?)
  if id "$STANDARD_USER" &>/dev/null; then
    echo ""
    echo "⚠ ERREUR : L'utilisateur '$STANDARD_USER' existe déjà sur ce système."
    echo "  Veuillez choisir un autre nom."
    echo ""
    continue
  fi

  # SI ON ARRIVE ICI : Le nom est valide et l'utilisateur n'existe pas.
  # On procède à la création.
  echo ""
  echo ">>> Création de l'utilisateur : $STANDARD_USER"
  
  # Installation de sudo si manquant (sécurité)
  if ! command -v sudo &> /dev/null; then
      echo "Installation du paquet sudo..."
      apt-get update && apt-get install -y sudo
  fi

  # Création de l'utilisateur
  adduser "$STANDARD_USER"
  
  # Vérification du succès de adduser
  if [ $? -eq 0 ]; then
      echo ">>> Ajout de $STANDARD_USER au groupe sudo..."
      usermod -aG sudo "$STANDARD_USER"
      check_command
      
      echo ""
      echo "✅ SUCCÈS : Utilisateur $STANDARD_USER créé et ajouté aux administrateurs."
      
      # --- NOUVELLE FONCTIONNALITÉ : COLORATION SYNTAXIQUE USER ---
      # Propose d'activer la coloration dans le .bashrc de l'utilisateur
      echo ""
      read -p "Voulez-vous activer la coloration syntaxique pour $STANDARD_USER ? (y/n) : " COLOR_USER_CHOICE
      
      if [[ "$COLOR_USER_CHOICE" == "y" ]]; then
        USER_BASHRC="/home/$STANDARD_USER/.bashrc"
        if [ -f "$USER_BASHRC" ]; then
          echo "→ Activation de la coloration dans $USER_BASHRC..."
          
          # Décommenter force_color_prompt=yes pour avoir le prompt couleur
          sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' "$USER_BASHRC"
          
          # Décommenter les alias ls/grep s'ils sont présents (standard Debian)
          sed -i 's/^#alias ls/alias ls/' "$USER_BASHRC"
          sed -i 's/^#alias grep/alias grep/' "$USER_BASHRC"
          
          echo "✓ Prompt et alias colorés activés pour $STANDARD_USER"
        else
          echo "⚠ Fichier .bashrc non trouvé, impossible d'activer la coloration."
        fi
      fi
      # -----------------------------------------------------------

      # IMPORTANT : On sort de la boucle car tout est fini
      break
  else
      echo ""
      echo "❌ ERREUR CRITIQUE : La commande adduser a échoué."
      read -p "Voulez-vous réessayer avec un autre nom ? (y/n) : " RETRY
      if [[ "$RETRY" != "y" ]]; then
          break
      fi
  fi

done

echo ""
echo "Fin de l'étape utilisateur."

################################################################################
# ÉTAPE 7 : SÉCURISATION SSH
################################################################################
# Sécurisation du service SSH (Secure Shell) :
# - Vérification et installation si nécessaire
# - Changement du port par défaut (22) pour éviter les scans automatiques
# - Désactivation (ou configuration) de la connexion root
################################################################################

echo ""
echo "=========================================="
echo "  ÉTAPE 7/7 : SÉCURISATION SSH"
echo "=========================================="
echo ""
echo "Configuration du service SSH pour l'accès à distance."
echo ""

# 1. Vérification de l'installation de SSH
echo "→ Vérification de l'installation du service SSH..."
SKIP_SSH_CONFIG="false"

if dpkg -s openssh-server &> /dev/null; then
    echo "✅ Le service SSH (openssh-server) est DÉJÀ INSTALLÉ."
    echo "   Vous pouvez vous connecter via : ssh utilisateur@$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)"
else
    echo "❌ Le service SSH n'est PAS installé."
    echo "   Sans SSH, vous ne pourrez pas gérer ce serveur à distance."
    echo ""
    read -p "Voulez-vous installer le serveur SSH maintenant ? (y/n) : " INSTALL_SSH

    if [[ "$INSTALL_SSH" == "y" ]]; then
        echo "Installation de openssh-server..."
        apt-get update && apt-get install -y openssh-server
        check_command
        echo "✓ SSH installé avec succès."
    else
        echo "⚠ Installation ignorée."
        echo "   La configuration SSH sera passée."
        SKIP_SSH_CONFIG="true"
    fi
fi

# Si SSH est installé ou vient de l'être, on continue la configuration
if [[ "$SKIP_SSH_CONFIG" == "false" ]]; then
    echo ""
    echo "POURQUOI SÉCURISER SSH ?"
    echo "  - Le port 22 est scanné en permanence par des bots"
    echo "  - L'utilisateur 'root' est la cible n°1 des attaques"
    echo ""
    echo "CHANGEMENTS PROPOSÉS :"
    echo "  1. Changer le port d'écoute (ex: 2222, 54321...)"
    echo "  2. Configurer la connexion root (Désactivée ou Autorisée)"
    echo ""
    read -p "Entrez le nouveau port SSH (par défaut 22, recommandé : 1024-65535) : " SSH_PORT

    # Valeur par défaut si vide
    if [[ -z "$SSH_PORT" ]]; then
      SSH_PORT=22
    fi

    # Validation du port (doit être un nombre entre 1 et 65535)
    if [[ "$SSH_PORT" =~ ^[0-9]+$ && $SSH_PORT -ge 1 && $SSH_PORT -le 65535 ]]; then
      
      echo ""
      echo "→ Configuration du port SSH sur $SSH_PORT..."
      # Modifier le port SSH dans la config
      sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
      
      # Menu pour la gestion du login ROOT
      echo ""
      echo "--- CONFIGURATION DE L'ACCÈS ROOT (root login) ---"
      echo "1. DÉSACTIVER la connexion root (Recommandé pour la sécurité)"
      echo "2. AUTORISER la connexion root (⚠ DANGEREUX ⚠ - Lab uniquement)"
      echo "3. Ne rien modifier (Garder la config actuelle)"
      echo ""
      read -p "Votre choix (1/2/3) : " ROOT_LOGIN_CHOICE

      case $ROOT_LOGIN_CHOICE in
        1)
            # Désactiver root
            sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
            echo "✓ Accès root SSH : DÉSACTIVÉ."
            ;;
        2)
            # Activer root avec avertissement
            echo ""
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "⚠ ATTENTION : VOUS AVEZ CHOISI D'AUTORISER LE LOGIN ROOT ⚠"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "Cette configuration est TRÈS DANGEREUSE."
            echo "Elle ne doit être utilisée QUE dans un contexte de LABORATOIRE"
            echo "sur un serveur NON EXPOSÉ sur Internet."
            echo "Les robots scannent et attaquent le compte root en permanence."
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo ""
            read -p "Confirmez-vous ce choix dangereux ? (y/n) : " CONFIRM_DANGER
            if [[ "$CONFIRM_DANGER" == "y" ]]; then
                sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config
                echo "⚠ Accès root SSH : AUTORISÉ (Soyez prudent)."
            else
                echo "→ Annulé. Aucune modification sur l'accès root."
            fi
            ;;
        *)
            echo "→ Aucune modification sur l'accès root."
            ;;
      esac
      
      echo "→ Redémarrage du service SSH..."
      systemctl restart ssh
      check_command
      
      echo ""
      echo "✓ CONFIGURATION SSH APPLIQUÉE"
      
      if [[ "$SSH_PORT" != "22" ]]; then
        echo ""
        echo "!!! IMPORTANT !!!"
        echo "Le port SSH a été changé pour $SSH_PORT"
        echo "Pour vous reconnecter, utilisez : ssh -p $SSH_PORT user@server"
        echo ""
      fi
    else
      echo ""
      echo "❌ ERREUR : Port SSH invalide. Configuration SSH ignorée."
      echo ""
    fi
else
    echo "→ Configuration SSH sautée."
fi

################################################################################
# RÉCAPITULATIF FINAL ET RECOMMANDATIONS
################################################################################
echo ""
echo "=========================================="
echo "      CONFIGURATION TERMINÉE"
echo "=========================================="
echo ""
echo "Récapitulatif des changements :"
echo "  ✓ Système mis à jour (Debian 13 Trixie)"
echo "  ✓ Clavier configuré en français (AZERTY)"

if [[ -n "$NEW_HOSTNAME" ]]; then
  echo "  ✓ Hostname : $NEW_HOSTNAME"
fi

if [[ "$CONFIGURE_IP" == "y" && -n "$INTERFACE" ]]; then
  echo "  ✓ IP fixe configurée : $STATIC_IP ($INTERFACE)"
  echo "    (À appliquer : redémarrage requis)"
fi

if [[ -n "$STANDARD_USER" ]]; then
  echo "  ✓ Utilisateur créé : $STANDARD_USER (avec sudo)"
fi

if [[ "$SKIP_SSH_CONFIG" == "false" ]]; then
    echo "  ✓ Port SSH : $SSH_PORT"
    # Vérification simple pour le récapitulatif
    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
        echo "  ✓ Accès root SSH : DÉSACTIVÉ (Sécurisé)"
    elif grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
        echo "  ⚠ Accès root SSH : AUTORISÉ (DANGEREUX)"
    else
        echo "  - Accès root SSH : Non modifié"
    fi
else
    echo "  - SSH : Non installé ou non configuré"
fi

echo ""
echo "=========================================="
echo "         COMMANDES DE VÉRIFICATION"
echo "=========================================="
echo "Après le redémarrage, lancez ces commandes :"
echo ""
if [[ "$CONFIGURE_IP" == "y" ]]; then
  echo "1. Vérifier l'IP : ip addr show $INTERFACE"
  echo "   (Vous devriez voir $STATIC_IP)"
fi
echo "2. Vérifier SSH  : ss -tnlp | grep ssh"
echo "   (Vous devriez voir le port $SSH_PORT)"
if [[ -n "$STANDARD_USER" ]]; then
  echo "3. Tester l'accès : ssh -p $SSH_PORT $STANDARD_USER@<IP>"
fi
echo ""
echo "=========================================="
echo ""

# Proposition de redémarrage
echo "Merci d'avoir utilisé ce script fourni par :"
echo "
 ⡷⣸ ⠄ ⢀⣀ ⢀⡀ ⡇ ⢀⣀ ⢀⣀   ⣏⡱ ⡎⢱ ⡏⢱ ⣎⣱ ⡇ ⡷⣸ ⣏⡉
 ⠇⠹ ⠇ ⠣⠤ ⠣⠜ ⠣ ⠣⠼ ⠭⠕   ⠧⠜ ⠣⠜ ⠧⠜ ⠇⠸ ⠇ ⠇⠹ ⠧⠤

LinkedIn : https://www.linkedin.com/in/bodaine
"
echo ""
read -p "Voulez-vous redémarrer le système maintenant ? (y/n) : " REBOOT_NOW

if [[ "$REBOOT_NOW" == "y" ]]; then
  echo ""
  echo "Redémarrage en cours..."
  reboot
else
  echo ""
  echo "N'oubliez pas de redémarrer manuellement avec la commande 'reboot'"
  echo "pour appliquer tous les changements système. Sinon vous pouvez redémarrer"
  echo "uniquement le service réseau avec 'sudo systemctl restart systemd-networkd'"
  echo "pour appliquer votre changement d'IP (⚠ si vous êtes connecté en SSH "
  echo "le terminal va se figer et vous devrez vous reconnecter sur la nouvelle IP)"
  echo ""
fi

exit 0
