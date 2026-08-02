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
# - Configuration d'une IP fixe (ifupdown, systemd-networkd ou NetworkManager)
# - Création d'un utilisateur standard avec droits sudo
# - Sécurisation SSH (changement de port, désactivation accès root)
# - Authentification par clé SSH : génération d'une paire de clés (machine
#   cliente) et/ou dépôt d'une clé publique dans authorized_keys (serveur)
#
# SÉCURITÉ DU CHANGEMENT D'ADRESSE IP
# -----------------------------------
# Le changement d'IP est l'opération la plus risquée d'un post-installation :
# une erreur de saisie peut rendre le serveur totalement injoignable. Ce script
# applique donc quatre garde-fous :
#
#   1. Il n'écrit RIEN tant que la configuration n'a pas été validée à chaud,
#      via une adresse IP ajoutée en SECONDAIRE (l'adresse DHCP actuelle reste
#      active, la session SSH en cours n'est jamais coupée).
#   2. La validation teste la passerelle, la résolution DNS, puis la
#      connectivité sur trois domaines successifs (example.org, debian.org,
#      cloudflare.com). En cas d'échec des trois, le retour au DHCP est proposé.
#   3. La bascule réelle n'a lieu qu'à la TOUTE FIN du script, une fois toutes
#      les autres étapes terminées, et elle est exécutée de manière détachée
#      (systemd-run) pour qu'une coupure SSH ne l'interrompe pas à mi-chemin.
#   4. Un retour automatique au DHCP est armé avant la bascule : sans
#      confirmation explicite (« sudo ip-fixe-confirmer ») dans le délai
#      imparti, le serveur restaure tout seul sa configuration précédente.
#      Un garde-fou équivalent surveille le premier redémarrage.
#
# SÉCURITÉ DU DURCISSEMENT SSH
# ----------------------------
# Couper l'authentification par mot de passe alors que la clé publique n'est
# pas réellement exploitable est l'autre façon classique de se verrouiller
# dehors. Le même principe s'applique donc : la désactivation n'est proposée
# qu'après une preuve (test de connexion par clé) ou une confirmation
# explicite, et un retour automatique est armé — sans « sudo ssh-cles-confirmer »
# dans le délai imparti, le mot de passe est réactivé tout seul.
#
# Prérequis : Accès root (sudo)
# Compatible : Debian 13 (Trixie) serveur minimal
#
################################################################################

################################################################################
# OPTIONS D'EXÉCUTION DU SHELL
################################################################################
# -u             : toute variable non initialisée provoque une erreur. Cela
#                  évite les commandes lancées avec un paramètre vide (par
#                  exemple « ip addr show » sans nom d'interface, qui renvoyait
#                  auparavant l'adresse de loopback).
# -o pipefail    : le code retour d'un pipeline est celui de la première
#                  commande en échec, et non celui de la dernière.
#
# « set -e » n'est volontairement PAS utilisé : le script est interactif et doit
# pouvoir continuer après l'échec d'une étape non critique. C'est le rôle de la
# fonction run_cmd, qui demande explicitement quoi faire.
################################################################################
set -uo pipefail

# Verrouille le tri et les messages des commandes analysées (ip, awk...) pour
# que l'analyse de leur sortie ne dépende pas de la locale de la machine.
export LC_ALL=C

################################################################################
# MODE « CHARGEMENT SEUL »
################################################################################
# En définissant PERSONNALISATION_SOURCE_ONLY=1, le fichier peut être sourcé
# pour ne charger que ses fonctions, sans rien exécuter. C'est ce que fait la
# suite de tests (tests/test-fonctions.sh), qui vérifie les validateurs et le
# calcul d'adresses sans jamais toucher au système.
################################################################################

################################################################################
# VÉRIFICATION DES PRIVILÈGES
################################################################################
if [ -z "${PERSONNALISATION_SOURCE_ONLY:-}" ] && [ "$(id -u)" -ne 0 ]; then
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
# VARIABLES GLOBALES
################################################################################
# Toutes les variables partagées entre étapes sont initialisées ici : avec
# « set -u », une variable jamais affectée ferait planter le script si une étape
# est ignorée par l'utilisateur.
################################################################################

# --- Saisies utilisateur -------------------------------------------------------
NEW_HOSTNAME=""
CONFIGURE_IP="n"
INTERFACE=""
STATIC_IP=""            # notation CIDR, ex. 192.168.0.10/24
STATIC_IP_BARE=""       # adresse seule, ex. 192.168.0.10
GATEWAY=""
DNS_SERVERS=""
STANDARD_USER=""
SSH_PORT=""
SSH_ROLE=""              # serveur | client | deux | aucun

# --- Drapeaux d'état réels (utilisés par le récapitulatif final) ---------------
# Ils ne valent 1 que si l'action a RÉELLEMENT abouti : le récapitulatif ne doit
# jamais annoncer un succès qui n'a pas eu lieu.
COLORATION_DONE=0
UPDATE_DONE=0
KEYBOARD_DONE=0
HOSTNAME_DONE=0
NET_CONFIGURED=0
NET_PENDING_APPLY=0
NET_APPLY_MODE=""       # "now" | "reboot"
USER_CREATED=0
SKIP_SSH_CONFIG="false"
SSH_PORT_APPLIED=0
SCRIPT_ERRORS=0

# --- Authentification par clé (étape 8) ----------------------------------------
KEY_GENERATED=0
KEY_PATH=""             # chemin de la clé PRIVÉE générée
KEY_PUB_PATH=""         # chemin de la clé publique correspondante
KEY_OWNER=""            # compte propriétaire de la paire
KEY_HAS_PASSPHRASE=0
AUTHKEY_ADDED=0
AUTHKEY_USER=""
AUTHKEY_COUNT=0
KEY_LOGIN_TESTED=0      # 1 uniquement si une connexion par clé a RÉELLEMENT abouti
PASSWORD_AUTH_DISABLED=0
SSH_AUTH_ROLLBACK_ARMED=0
SSH_AUTH_ROLLBACK_DELAY=10

# --- Contexte réseau détecté ---------------------------------------------------
NET_STACK=""            # ifupdown | networkd | networkmanager
NET_NM_CONNECTION=""
NET_IFUPDOWN_FILE=""
NET_GENERATED_FILES=""
DHCPCD_NOHOOK_ADDED=0
DNS_METHOD=""           # resolved | resolvconf | resolvconf-file

# --- Emplacements de travail ---------------------------------------------------
STATE_DIR="/var/lib/personnalisation-debian13"
BACKUP_MANIFEST="$STATE_DIR/backups.list"
# Manifeste SÉPARÉ pour les seuls fichiers réseau : le retour arrière ne doit
# restaurer QUE le réseau, surtout pas /root/.bashrc, /etc/hosts ou sshd_config
# qui ont pu être modifiés par les autres étapes.
NET_BACKUP_MANIFEST="$STATE_DIR/network-backups.list"
NET_BACKUP_MODE=0
ROLLBACK_STATE="$STATE_DIR/rollback.env"
CONFIRMED_FLAG="$STATE_DIR/confirmed"
RUNTIME_CONFIRMED_FLAG="/run/personnalisation-debian13.confirmed"
# État et drapeau propres au durcissement SSH : ils sont volontairement
# SÉPARÉS de ceux du réseau, pour qu'une confirmation d'IP ne désarme pas le
# retour arrière SSH (et réciproquement).
SSH_AUTH_STATE="$STATE_DIR/ssh-auth.env"
SSH_AUTH_CONFIRMED_FLAG="$STATE_DIR/ssh-auth-confirmed"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"

# --- Divers --------------------------------------------------------------------
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
ASK_VALUE=""            # valeur renvoyée par ask_input (évite les sous-shells)
NET_TEST_DOMAINS=("example.org" "debian.org" "cloudflare.com")

################################################################################
# SECTION A — FONCTIONS UTILITAIRES GÉNÉRALES
################################################################################

################################################################################
# FONCTION : Affichage & Système de Couleurs par Étape
################################################################################
# Uniformise la présentation. Chaque étape possède sa propre couleur thématique
# pour permettre à l'utilisateur d'identifier instantanément l'avancement.
################################################################################
if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
  C_RESET="\e[0m"
  C_BOLD="\e[1m"
  C_DIM="\e[2m"

  # Couleurs statutaires
  C_OK="\e[1;32m"        # Vert brillant
  C_INFO="\e[1;36m"      # Cyan brillant
  C_WARN="\e[1;33m"      # Jaune / Ambre
  C_ERR="\e[1;31m"       # Rouge brillant

  # Couleurs distinctes par étape (8 étapes + Intro + Bilan)
  COLOR_INTRO="\e[1;38;5;39m"    # Bleu Roi / Cyan Vif
  COLOR_STEP1="\e[1;38;5;51m"    # Cyan Fluo / Turquoise (Étape 1 : Coloration)
  COLOR_STEP2="\e[1;38;5;75m"    # Bleu Ciel / Steel Blue (Étape 2 : Mises à jour)
  COLOR_STEP3="\e[1;38;5;82m"    # Vert Émeraude (Étape 3 : Clavier)
  COLOR_STEP4="\e[1;38;5;214m"   # Jaune Ambre / Gold (Étape 4 : Hostname)
  COLOR_STEP5="\e[1;38;5;171m"   # Violet / Magenta Vif (Étape 5 : Réseau IP)
  COLOR_STEP6="\e[1;38;5;45m"    # Bleu Lagon / Teal (Étape 6 : Utilisateur)
  COLOR_STEP7="\e[1;38;5;208m"   # Orange Brillant (Étape 7 : Sécurisation SSH)
  COLOR_STEP8="\e[1;38;5;141m"   # Mauve / Violet Pastel (Étape 8 : Clés SSH)
  COLOR_SUMMARY="\e[1;38;5;220m" # Or / Jaune Soleil (Récapitulatif & Bilan)
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_OK=""
  C_INFO=""
  C_WARN=""
  C_ERR=""
  COLOR_INTRO=""
  COLOR_STEP1=""
  COLOR_STEP2=""
  COLOR_STEP3=""
  COLOR_STEP4=""
  COLOR_STEP5=""
  COLOR_STEP6=""
  COLOR_STEP7=""
  COLOR_STEP8=""
  COLOR_SUMMARY=""
fi

CURRENT_STEP_COLOR="${COLOR_INTRO}"

log()       { printf '%s\n' "$*"; }
log_info()  { printf "${C_INFO}→${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
log_ok()    { printf "${C_OK}✓${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }
log_warn()  { printf "${C_WARN}⚠ %s${C_RESET}\n" "$*" >&2; }
log_err()   { printf "${C_ERR}❌ %s${C_RESET}\n" "$*" >&2; }

# shellcheck disable=SC2001
banner() {
  local title="$*"
  local color="${CURRENT_STEP_COLOR}"

  if [[ "$title" =~ ÉTAPE[[:space:]]+([1-8])/8 ]]; then
    local num="${BASH_REMATCH[1]}"
    case "$num" in
      1) color="${COLOR_STEP1}" ;;
      2) color="${COLOR_STEP2}" ;;
      3) color="${COLOR_STEP3}" ;;
      4) color="${COLOR_STEP4}" ;;
      5) color="${COLOR_STEP5}" ;;
      6) color="${COLOR_STEP6}" ;;
      7) color="${COLOR_STEP7}" ;;
      8) color="${COLOR_STEP8}" ;;
    esac
    CURRENT_STEP_COLOR="$color"
  elif [[ "$title" == *"TERMINÉE"* || "$title" == *"BILAN"* || "$title" == *"COMMANDES DE VÉRIFICATION"* ]]; then
    color="${COLOR_SUMMARY}"
    CURRENT_STEP_COLOR="$color"
  fi

  local clean_title
  clean_title="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$title")"
  local len=${#clean_title}
  local width=$((len + 6))
  (( width < 50 )) && width=50

  local line=""
  for ((i=0; i<width-2; i++)); do line="${line}─"; done

  local padding_total=$((width - 2 - len))
  local pad_left=$((padding_total / 2))
  local pad_right=$((padding_total - pad_left))

  local spaces_left="" spaces_right=""
  for ((i=0; i<pad_left; i++)); do spaces_left="${spaces_left} "; done
  for ((i=0; i<pad_right; i++)); do spaces_right="${spaces_right} "; done

  echo ""
  echo -e "${color}╭${line}╮${C_RESET}"
  echo -e "${color}│${spaces_left}${C_BOLD}${title}${C_RESET}${color}${spaces_right}│${C_RESET}"
  echo -e "${color}╰${line}╯${C_RESET}"
  echo ""
}

################################################################################
# FONCTION : Exécution contrôlée d'une commande
################################################################################
# run_cmd "<libellé affiché>" commande arg1 arg2...
#
# Exécute la commande, affiche un résultat clair, et déclenche le traitement
# d'erreur interactif en cas d'échec.
#
# Cette fonction remplace l'ancienne « check_command », qui lisait $? APRÈS
# coup : le moindre « echo » intercalé entre la commande et l'appel lui faisait
# contrôler le mauvais code retour, et un échec passait alors inaperçu.
#
# Renvoie le code retour réel de la commande.
################################################################################
run_cmd() {
  local label="$1"
  shift
  log_info "$label"

  # Le code retour est capturé explicitement : après un « if commande ; then »
  # dont la condition échoue, bash remet $? à 0, ce qui ferait passer un échec
  # pour un succès auprès de l'appelant.
  local rc=0
  "$@" || rc=$?

  if (( rc == 0 )); then
    return 0
  fi

  SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
  echo ""
  log_err "Échec : $label (code $rc)"
  echo "  Commande : $*"
  echo ""
  if ! ask_yes_no "Voulez-vous continuer malgré cette erreur ?" "n"; then
    echo "Arrêt du script demandé par l'utilisateur."
    exit 1
  fi
  echo ""
  return "$rc"
}

################################################################################
# FONCTION : Question fermée oui/non
################################################################################
# ask_yes_no "<question>" [defaut]
#
# Accepte indifféremment o, oui, y, yes, 1 (oui) et n, non, no, 0 (non), en
# majuscules comme en minuscules. L'ancienne version n'acceptait que « y » en
# minuscule, ce qui était incohérent avec une interface entièrement française :
# un utilisateur répondant « oui » se voyait silencieusement appliquer « non ».
#
# Si l'entrée standard est fermée (script lancé sans terminal), la valeur par
# défaut est utilisée au lieu de boucler indéfiniment.
#
# Renvoie 0 pour oui, 1 pour non.
################################################################################
ask_yes_no() {
  local question="${1:-Confirmez-vous ?}"
  local default="${2:-}"
  local hint reply prompt_str

  case "${default,,}" in
    y|yes|o|oui|1) hint="${C_BOLD}[O/n]${C_RESET}" ;;
    n|no|non|0)    hint="${C_BOLD}[o/N]${C_RESET}" ;;
    *)             hint="${C_BOLD}[o/n]${C_RESET}" ;;
  esac

  prompt_str="$(echo -e "${CURRENT_STEP_COLOR}?${C_RESET} ${question} ${hint} : ")"

  while true; do
    if ! read -r -p "$prompt_str" reply; then
      echo "" >&2
      log_warn "Entrée standard indisponible : réponse « ${default:-non} » utilisée."
      reply="${default:-non}"
    fi
    reply="${reply,,}"
    [[ -z "$reply" ]] && reply="${default,,}"
    case "$reply" in
      y|yes|o|oui|1) return 0 ;;
      n|no|non|0)    return 1 ;;
      *) log_warn "Réponse non comprise. Tapez « o » (oui) ou « n » (non)." ;;
    esac
  done
}

################################################################################
# FONCTION : Saisie contrôlée
################################################################################
# ask_input "<invite>" "<valeur par défaut>" "<validateur>" "<vide autorisé>"
#
# Reboucle tant que la saisie n'est pas valide. Le résultat est placé dans la
# variable globale ASK_VALUE (et non renvoyé par écho) afin d'éviter tout
# problème de sous-shell et de capture de messages.
#
# Le validateur est le nom d'une fonction qui reçoit la valeur et renvoie 0 si
# elle est acceptable ; c'est à elle d'expliquer le refus.
################################################################################
ask_input() {
  local prompt="${1:-Valeur}"
  local default="${2:-}"
  local validator="${3:-}"
  local allow_empty="${4:-no}"
  local value shown

  while true; do
    if [[ -n "$default" ]]; then
      shown="$(echo -e "${CURRENT_STEP_COLOR}?${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET} : ")"
    else
      shown="$(echo -e "${CURRENT_STEP_COLOR}?${C_RESET} ${prompt} : ")"
    fi

    if ! read -r -p "$shown" value; then
      echo "" >&2
      log_warn "Entrée standard indisponible : valeur par défaut utilisée."
      value="$default"
    fi

    [[ -z "$value" ]] && value="$default"

    if [[ -z "$value" ]]; then
      if [[ "$allow_empty" == "yes" ]]; then
        ASK_VALUE=""
        return 0
      fi
      log_warn "Une valeur est requise."
      continue
    fi

    if [[ -n "$validator" ]] && ! "$validator" "$value"; then
      continue
    fi

    ASK_VALUE="$value"
    return 0
  done
}

################################################################################
# FONCTION : Sauvegarde et restauration de fichiers de configuration
################################################################################
# backup_file crée une COPIE horodatée (cp -a, jamais mv : l'original doit
# rester en place) et enregistre le couple original/sauvegarde dans un manifeste
# exploité par le mécanisme de retour arrière.
#
# Les liens symboliques sont préservés tels quels (cp -a implique -d).
################################################################################
backup_file() {
  local src="${1:-}"
  local dst

  [[ -n "$src" ]] || return 1
  if [[ ! -e "$src" && ! -L "$src" ]]; then
    return 0   # rien à sauvegarder, ce n'est pas une erreur
  fi

  dst="${src}.bak.${RUN_STAMP}"
  if ! cp -a "$src" "$dst" 2>/dev/null; then
    log_err "Impossible de sauvegarder $src"
    return 1
  fi

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\t%s\n' "$src" "$dst" >> "$BACKUP_MANIFEST"
  # Les fichiers sauvegardés pendant l'étape réseau sont en outre listés à part :
  # ce sont les SEULS que le retour arrière automatique restaurera.
  if (( NET_BACKUP_MODE )); then
    printf '%s\t%s\n' "$src" "$dst" >> "$NET_BACKUP_MANIFEST"
  fi
  log_ok "Sauvegarde : $dst"
  return 0
}

# Sauvegarde UNE SEULE FOIS par exécution. Le nom de la sauvegarde contient
# l'horodatage du lancement (et non celui de l'appel) : rappeler backup_file sur
# un fichier déjà sauvegardé écraserait la copie d'origine par la version déjà
# modifiée, et le retour arrière ne restaurerait plus l'état initial. C'est le
# cas des fichiers sshd, touchés à l'étape 7 puis de nouveau à l'étape 8.
backup_file_once() {
  local src="${1:-}"
  [[ -n "$src" ]] || return 1
  [[ -e "${src}.bak.${RUN_STAMP}" ]] && return 0
  backup_file "$src"
}

restore_file() {
  local src="${1:-}" dst="${2:-}"
  [[ -n "$src" && -n "$dst" ]] || return 1
  [[ -e "$dst" || -L "$dst" ]] || return 1
  rm -f "$src" 2>/dev/null || true
  cp -a "$dst" "$src"
}

################################################################################
# FONCTION : Écriture d'un bloc délimité et idempotent
################################################################################
# write_marked_block <fichier> <marqueur début> <marqueur fin> < contenu
#
# Remplace le bloc précédemment écrit par le script (repéré par ses marqueurs)
# au lieu de l'empiler. L'ancienne version testait la présence du bloc avec un
# motif grep qui ne correspondait jamais au texte réellement écrit : chaque
# exécution du script dupliquait la configuration du prompt dans /root/.bashrc.
#
# Le retrait de l'ancien bloc se fait par NUMÉROS DE LIGNE, et uniquement si les
# DEUX marqueurs sont présents et dans le bon ordre. Un découpage « à l'état »
# (on ignore tout après le marqueur de début jusqu'au marqueur de fin) tronquerait
# tout le reste du fichier si l'utilisateur avait supprimé le marqueur de fin en
# éditant son .bashrc à la main. Dans ce cas on préfère ne rien retirer et
# prévenir : mieux vaut un bloc en double qu'un fichier amputé.
################################################################################
write_marked_block() {
  local file="${1:-}" begin="${2:-}" end="${3:-}"
  local content tmp n_begin n_end

  content="$(cat)"
  [[ -n "$file" ]] || return 1
  [[ -e "$file" ]] || touch "$file"

  n_begin="$(grep -nF -m1 -- "$begin" "$file" 2>/dev/null | cut -d: -f1)"
  n_end="$(grep -nF -m1 -- "$end" "$file" 2>/dev/null | cut -d: -f1)"

  if [[ -n "$n_begin" && -n "$n_end" ]] && (( n_end > n_begin )); then
    tmp="$(mktemp)"
    awk -v s="$n_begin" -v e="$n_end" 'NR < s || NR > e' "$file" > "$tmp" && cat "$tmp" > "$file"
    rm -f "$tmp"
  elif [[ -n "$n_begin" || -n "$n_end" ]]; then
    log_warn "Bloc géré incomplet dans $file (marqueur de début ou de fin manquant)."
    echo "  Par sécurité, rien n'est supprimé : un nouveau bloc est ajouté à la suite." >&2
    echo "  Vous pouvez retirer l'ancien à la main si nécessaire." >&2
  fi

  {
    printf '\n%s\n' "$begin"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
  } >> "$file"
}

################################################################################
# FONCTION : Gestion des paquets
################################################################################
# apt en mode strictement non interactif : sans ces variables d'environnement,
# une question de conffile ou la fenêtre « needrestart » peut bloquer le script
# en plein milieu, voire lui voler son entrée standard.
# apt-get est préféré à apt : l'interface de ce dernier n'est pas garantie
# stable pour les scripts (apt l'annonce lui-même à chaque exécution).
################################################################################
apt_run() {
  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a \
  UCF_FORCE_CONFOLD=1 \
  apt-get -y \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confdef \
    "$@"
}

install_pkgs() {
  apt_run install "$@"
}

################################################################################
# FONCTION : Installation à la demande d'un outil
################################################################################
# need_cmd <binaire> [paquet]
# Renvoie 0 si le binaire est disponible (éventuellement après installation).
################################################################################
need_cmd() {
  local bin="${1:-}" pkg="${2:-${1:-}}"
  [[ -n "$bin" ]] || return 1
  command -v "$bin" >/dev/null 2>&1 && return 0
  log_info "Installation de « $pkg » (fournit « $bin »)..."
  install_pkgs "$pkg" >/dev/null 2>&1 || true
  command -v "$bin" >/dev/null 2>&1
}

################################################################################
# FONCTION : Détection du système
################################################################################
# Le script est écrit pour Debian 13. Sur une autre distribution, la plupart des
# commandes (apt, setupcon, ifupdown, ssh.socket...) se comportent différemment
# ou n'existent pas : mieux vaut prévenir tout de suite que d'échouer au milieu.
################################################################################
os_release_get() {
  local key="${1:-}"
  [[ -r /etc/os-release ]] || return 1
  awk -F= -v k="$key" '$1 == k { gsub(/^"|"$/, "", $2); print $2; exit }' /etc/os-release
}

detect_os() {
  OS_ID="$(os_release_get ID || true)"
  OS_VERSION_ID="$(os_release_get VERSION_ID || true)"
  OS_CODENAME="$(os_release_get VERSION_CODENAME || true)"

  if [[ "$OS_ID" != "debian" ]]; then
    banner "SYSTÈME NON RECONNU"
    log_warn "Ce script cible Debian 13 (Trixie)."
    echo "  Système détecté : ${OS_ID:-inconnu} ${OS_VERSION_ID:-} ${OS_CODENAME:-}"
    echo ""
    echo "  Sur une autre distribution, plusieurs étapes échoueront (gestion des"
    echo "  paquets, clavier console, configuration réseau, activation SSH par"
    echo "  socket...)."
    echo ""
    if ! ask_yes_no "Continuer quand même (déconseillé) ?" "n"; then
      echo "Arrêt du script."
      exit 1
    fi
    return 0
  fi

  if [[ "$OS_VERSION_ID" != "13" ]]; then
    log_warn "Debian détectée en version « ${OS_VERSION_ID:-inconnue} » (${OS_CODENAME:-?}), or ce script cible Debian 13."
    echo "  Les étapes réseau et SSH tiennent compte de spécificités propres à"
    echo "  Trixie (activation de SSH par socket, dépréciation de « netmask »,"
    echo "  absence de systemd-resolved par défaut)."
    echo ""
    if ! ask_yes_no "Continuer quand même ?" "n"; then
      echo "Arrêt du script."
      exit 1
    fi
  else
    log_ok "Système détecté : Debian $OS_VERSION_ID (${OS_CODENAME:-trixie})"
  fi
}

################################################################################
# SECTION B — VALIDATEURS
################################################################################
# Fonctions pures (aucun effet de bord) réutilisables par ask_input. Chacune
# explique elle-même pourquoi la valeur est refusée, sur la sortie d'erreur pour
# ne jamais polluer une éventuelle capture.
################################################################################

is_ipv4() {
  local ip="${1:-}" octet
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    # Un zéro en tête (« 010 ») est ambigu : certaines bibliothèques
    # l'interprètent en octal. On le refuse.
    [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}

is_ipaddr() {
  # IPv4 ou IPv6 (validation IPv6 volontairement permissive : le script ne
  # configure pas d'IPv6 statique, il se contente de ne pas rejeter un
  # résolveur IPv6 saisi par l'utilisateur).
  local ip="${1:-}"
  is_ipv4 "$ip" && return 0
  [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]] && return 0
  return 1
}

ip_to_int() {
  local a b c d IFS=.
  read -r a b c d <<< "${1:-0.0.0.0}"
  printf '%u' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

int_to_ip() {
  local n="${1:-0}"
  printf '%d.%d.%d.%d' \
    "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" \
    "$(( (n >> 8) & 255 ))"  "$(( n & 255 ))"
}

prefix_to_mask_int() {
  local p="${1:-0}"
  if (( p <= 0 )); then
    printf '%u' 0
  else
    printf '%u' "$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))"
  fi
}

prefix_to_netmask() {
  int_to_ip "$(prefix_to_mask_int "${1:-0}")"
}

net_addr()   { printf '%s' "$(int_to_ip "$(( $(ip_to_int "$1") & $(prefix_to_mask_int "$2") ))")"; }
bcast_addr() { printf '%s' "$(int_to_ip "$(( ($(ip_to_int "$1") | (0xFFFFFFFF ^ $(prefix_to_mask_int "$2"))) & 0xFFFFFFFF ))")"; }

ip_in_subnet() {
  # ip_in_subnet <ip> <ip_reseau> <prefixe>
  local a b mask
  mask="$(prefix_to_mask_int "${3:-0}")"
  a=$(( $(ip_to_int "${1:-0.0.0.0}") & mask ))
  b=$(( $(ip_to_int "${2:-0.0.0.0}") & mask ))
  [[ "$a" == "$b" ]]
}

# --- Validateurs interactifs ---------------------------------------------------

v_iface() {
  local iface="${1:-}"
  if [[ ! "$iface" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_warn "« $iface » n'est pas un nom d'interface valide."
    return 1
  fi
  if [[ ! -e "/sys/class/net/$iface" ]]; then
    log_warn "L'interface « $iface » n'existe pas sur ce système."
    echo "  Interfaces disponibles : $(list_interfaces | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

v_cidr() {
  local cidr="${1:-}" ip prefix

  if [[ "$cidr" != */* ]]; then
    log_warn "Il manque le masque : indiquez l'adresse en notation CIDR, par exemple 192.168.1.100/24."
    return 1
  fi

  ip="${cidr%%/*}"
  prefix="${cidr##*/}"

  if ! is_ipv4 "$ip"; then
    log_warn "« $ip » n'est pas une adresse IPv4 valide."
    return 1
  fi
  if [[ ! "$prefix" =~ ^[0-9]{1,2}$ ]] || (( prefix < 1 || prefix > 32 )); then
    log_warn "Le préfixe « /$prefix » est invalide (attendu entre /1 et /32)."
    return 1
  fi
  if (( prefix <= 30 )); then
    if [[ "$ip" == "$(net_addr "$ip" "$prefix")" ]]; then
      log_warn "$ip est l'adresse RÉSEAU du sous-réseau /$prefix : elle ne peut pas être attribuée à une machine."
      return 1
    fi
    if [[ "$ip" == "$(bcast_addr "$ip" "$prefix")" ]]; then
      log_warn "$ip est l'adresse de DIFFUSION (broadcast) du sous-réseau /$prefix : elle ne peut pas être attribuée à une machine."
      return 1
    fi
  fi
  return 0
}

v_gateway() {
  local gw="${1:-}" ip prefix

  if ! is_ipv4 "$gw"; then
    log_warn "« $gw » n'est pas une adresse IPv4 valide."
    return 1
  fi

  ip="${STATIC_IP%%/*}"
  prefix="${STATIC_IP##*/}"

  if [[ "$gw" == "$ip" ]]; then
    log_warn "La passerelle ne peut pas être identique à l'adresse du serveur ($ip)."
    return 1
  fi

  if [[ -n "$ip" && -n "$prefix" ]] && ! ip_in_subnet "$gw" "$ip" "$prefix"; then
    log_warn "La passerelle $gw n'appartient pas au sous-réseau $(net_addr "$ip" "$prefix")/$prefix."
    echo "  C'est presque toujours une erreur de saisie : sans route vers la" >&2
    echo "  passerelle, le serveur n'aura aucun accès extérieur." >&2
    echo "" >&2
    if ask_yes_no "  Conserver quand même cette passerelle (configuration « onlink » particulière) ?" "n"; then
      return 0
    fi
    return 1
  fi
  return 0
}

v_dns_list() {
  local list="${1:-}" srv count=0
  for srv in $list; do
    if ! is_ipaddr "$srv"; then
      log_warn "« $srv » n'est pas une adresse de serveur DNS valide."
      return 1
    fi
    count=$((count + 1))
  done
  if (( count == 0 )); then
    log_warn "Indiquez au moins un serveur DNS."
    return 1
  fi
  if (( count > 3 )); then
    log_warn "La bibliothèque C de Linux n'utilise que les 3 premiers serveurs DNS de /etc/resolv.conf ; les suivants seront ignorés."
  fi
  return 0
}

v_hostname() {
  local name="${1:-}"
  if (( ${#name} > 63 )); then
    log_warn "Le hostname ne doit pas dépasser 63 caractères."
    return 1
  fi
  if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    log_warn "« $name » est invalide : minuscules, chiffres et tirets uniquement, sans tiret en début ni en fin."
    local suggestion
    suggestion="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -e 's/-\+/-/g' -e 's/^-//' -e 's/-$//')"
    [[ -n "$suggestion" ]] && echo "  Suggestion : $suggestion" >&2
    return 1
  fi
  return 0
}

# Validation de PLAGE uniquement : utilisable aussi pour le port d'un serveur
# DISTANT, où les vérifications locales (port déjà occupé ici) n'ont aucun sens.
v_port() {
  local port="${1:-}"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    log_warn "« $port » n'est pas un port valide (1-65535)."
    return 1
  fi
  return 0
}

v_ssh_port() {
  local port="${1:-}"
  v_port "$port" || return 1
  if (( port != 22 )) && (( port < 1024 )); then
    log_warn "Le port $port est réservé aux services système et peut entrer en conflit."
    ask_yes_no "  L'utiliser quand même ?" "n" || return 1
  fi
  if [[ "$port" != "22" ]] && command -v ss >/dev/null 2>&1 &&
     ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
    log_warn "Le port $port est DÉJÀ utilisé par un autre service sur cette machine."
    return 1
  fi
  return 0
}

################################################################################
# SECTION C — DÉTECTION ET OUTILLAGE RÉSEAU
################################################################################

################################################################################
# FONCTION : Liste des interfaces réseau physiques
################################################################################
# L'ancienne version filtrait la loopback avec « grep -v lo », ce qui écartait
# aussi toute interface dont le nom CONTIENT « lo », et laissait les suffixes
# « @if12 » des interfaces virtuelles. On filtre ici sur le nom exact.
################################################################################
list_interfaces() {
  ip -o link show 2>/dev/null | awk -F': ' '{ split($2, a, "@"); if (a[1] != "lo") print a[1] }'
}

################################################################################
# FONCTION : Adresse IPv4 réellement portée par une interface
################################################################################
# Sans argument, renvoie l'adresse de l'interface qui porte la route par défaut.
# La loopback est toujours exclue : l'ancienne version pouvait proposer à
# l'utilisateur de se connecter en SSH sur 127.0.0.1.
################################################################################
current_ipv4() {
  local iface="${1:-}" addr
  if [[ -z "$iface" ]]; then
    iface="$(default_iface)"
  fi
  if [[ -n "$iface" ]]; then
    addr="$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"
  fi
  if [[ -z "${addr:-}" ]]; then
    addr="$(ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')"
  fi
  printf '%s' "${addr:-}"
}

default_iface() {
  ip -o -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }'
}

current_cidr() {
  local iface="${1:-}"
  [[ -n "$iface" ]] || return 0
  ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{ print $4; exit }'
}

current_gateway() {
  local iface="${1:-}"
  if [[ -n "$iface" ]]; then
    ip -o -4 route show default dev "$iface" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i+1); exit } }'
  else
    ip -o -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i+1); exit } }'
  fi
}

current_dns() {
  local servers=""
  if command -v resolvectl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    servers="$(resolvectl dns 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | sort -u | tr '\n' ' ')"
  fi
  if [[ -z "${servers// /}" && -r /etc/resolv.conf ]]; then
    servers="$(awk '$1 == "nameserver" && $2 !~ /^127\./ { print $2 }' /etc/resolv.conf | sort -u | tr '\n' ' ')"
  fi
  printf '%s' "$(printf '%s' "$servers" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//')"
}

################################################################################
# FONCTION : Détection de la pile réseau réellement active
################################################################################
# Debian 13 installe par défaut ifupdown (/etc/network/interfaces) sur une
# installation serveur minimale, et NetworkManager sur une installation de
# bureau. systemd-networkd est fourni avec systemd mais n'est PAS activé.
#
# L'ancienne version imposait une migration vers systemd-networkd : elle
# désactivait « networking.service » et déplaçait /etc/network/interfaces. Une
# simple faute de frappe sur le nom de l'interface laissait alors la machine
# sans aucune configuration réseau au redémarrage suivant.
#
# On écrit désormais dans la pile déjà en place. Aucune migration, donc aucun
# risque de se retrouver entre deux gestionnaires.
################################################################################
detect_net_stack() {
  local iface="${1:-}" state

  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    state="$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$iface" '$1 == d { print $2; exit }')"
    if [[ -n "$state" && "$state" != "unmanaged" ]]; then
      printf 'networkmanager'
      return 0
    fi
  fi

  if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    printf 'networkd'
    return 0
  fi

  if systemctl is-active --quiet networking 2>/dev/null || systemctl is-enabled --quiet networking 2>/dev/null; then
    printf 'ifupdown'
    return 0
  fi

  if [[ -f /etc/network/interfaces ]]; then
    printf 'ifupdown'
    return 0
  fi

  printf 'networkd'
}

net_stack_label() {
  case "${1:-}" in
    ifupdown)       printf 'ifupdown (/etc/network/interfaces)' ;;
    networkd)       printf 'systemd-networkd' ;;
    networkmanager) printf 'NetworkManager' ;;
    *)              printf 'inconnue' ;;
  esac
}

################################################################################
# FONCTION : L'adresse visée est-elle déjà occupée sur le réseau ?
################################################################################
# Attribuer une IP déjà utilisée provoque un conflit d'adresses : les deux
# machines deviennent instables et le diagnostic est pénible. On teste donc
# AVANT d'écrire quoi que ce soit.
#
# arping -D (mode « duplicate address detection ») est la méthode fiable ; à
# défaut on retombe sur un simple ping, moins sûr mais toujours mieux que rien.
#
# Renvoie 0 si l'adresse semble occupée, 1 sinon.
################################################################################
addr_in_use() {
  local iface="${1:-}" ip="${2:-}"

  # Adresse déjà portée par cette machine : ce n'est pas un conflit.
  if ip -o -4 addr show dev "$iface" 2>/dev/null | grep -qE "inet ${ip//./\\.}/"; then
    return 1
  fi

  if command -v arping >/dev/null 2>&1; then
    # arping -D renvoie 0 si l'adresse est LIBRE, 1 si une réponse est reçue.
    if arping -D -q -c 2 -w 3 -I "$iface" "$ip" >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi

  if ping -4 -c 1 -W 1 -n "$ip" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

################################################################################
# FONCTION : Construction d'un fichier resolv.conf candidat
################################################################################
build_resolv_conf() {
  local dest="${1:-}" servers="${2:-}" srv count=0

  {
    echo "# Généré par le script de personnalisation Debian 13"
    echo "# Date : $(date)"
    # Les directives search/domain existantes sont conservées : elles
    # proviennent souvent du domaine local et leur perte casse la résolution
    # des noms courts.
    if [[ -r /etc/resolv.conf ]]; then
      awk '$1 == "search" || $1 == "domain" { print }' /etc/resolv.conf
    fi
    for srv in $servers; do
      count=$((count + 1))
      (( count > 3 )) && break
      echo "nameserver $srv"
    done
    # timeout court + 2 tentatives : sans cela, un résolveur injoignable fige
    # chaque résolution pendant 5 secondes.
    echo "options timeout:2 attempts:2"
  } > "$dest"
}

################################################################################
# FONCTION : Sondes de connectivité exécutées dans un espace de noms isolé
################################################################################
# Pour tester des serveurs DNS qui ne sont pas encore ceux du système, il faut
# que /etc/resolv.conf pointe temporairement sur eux. Plutôt que d'écraser le
# fichier réel — et de risquer de le laisser cassé si le script est interrompu —
# on monte le fichier candidat PAR-DESSUS /etc/resolv.conf dans un espace de
# noms de montage privé (unshare -m). Le système réel n'est jamais modifié :
# à la fin de la commande, le montage disparaît avec l'espace de noms.
#
# unshare fait partie de util-linux, présent sur toute installation Debian.
################################################################################
probe_in_ns() {
  # probe_in_ns <resolv.conf candidat> <commande...>
  local resolv="${1:-}"
  shift
  # Les apostrophes simples sont volontaires : le petit script doit être
  # interprété par le bash lancé dans l'espace de noms, pas par celui-ci.
  # shellcheck disable=SC2016
  unshare -m --propagation private -- \
    bash -c 'f="$1"; shift; mount --bind "$f" /etc/resolv.conf 2>/dev/null || exit 90; "$@"' \
    _ "$resolv" "$@"
}

probe_dns() {
  # Résolution pure : prouve que les serveurs DNS répondent, même si l'ICMP est
  # filtré en sortie.
  probe_in_ns "${1:-}" getent ahostsv4 "${2:-}" >/dev/null 2>&1
}

probe_ping_domain() {
  # Connectivité de bout en bout depuis la NOUVELLE adresse source.
  probe_in_ns "${1:-}" ping -4 -c 1 -W 3 -I "${2:-}" -n "${3:-}" >/dev/null 2>&1
}

################################################################################
# FONCTION : Nettoyage du test à chaud
################################################################################
# Appelée à chaque sortie de network_preflight, y compris sur Ctrl+C : l'adresse
# secondaire et la route temporaire ne doivent JAMAIS survivre au test.
################################################################################
PF_IFACE=""
PF_CIDR=""
PF_ADDR_ADDED=0
PF_ROUTE_ADDED=""
PF_RESOLV_TMP=""

preflight_cleanup() {
  if [[ -n "$PF_ROUTE_ADDED" ]]; then
    # shellcheck disable=SC2086
    ip route del $PF_ROUTE_ADDED >/dev/null 2>&1 || true
    PF_ROUTE_ADDED=""
  fi
  if (( PF_ADDR_ADDED )); then
    ip addr del "$PF_CIDR" dev "$PF_IFACE" >/dev/null 2>&1 || true
    PF_ADDR_ADDED=0
  fi
  if [[ -n "$PF_RESOLV_TMP" ]]; then
    rm -f "$PF_RESOLV_TMP"
    PF_RESOLV_TMP=""
  fi
}

################################################################################
# FONCTION : Validation à chaud, sans couper la connexion en cours
################################################################################
# C'est le cœur du dispositif de sécurité.
#
# L'adresse cible est ajoutée en SECONDAIRE sur l'interface : Linux accepte
# plusieurs adresses IPv4 sur une même carte. L'adresse obtenue en DHCP — celle
# qui porte la session SSH courante — reste donc parfaitement active. Aucune
# coupure n'est possible pendant le test.
#
# Sont vérifiés, dans l'ordre :
#   1. la joignabilité de la passerelle depuis la nouvelle adresse ;
#   2. la résolution DNS avec les serveurs demandés ;
#   3. la connectivité réelle vers example.org, puis debian.org, puis
#      cloudflare.com (arrêt au premier succès).
#
# Renvoie 0 si la configuration est utilisable, 1 sinon.
################################################################################
network_preflight() {
  local iface="${1:-}" cidr="${2:-}" gw="${3:-}" dns="${4:-}"
  local ip="${cidr%%/*}" prefix="${cidr##*/}"
  local cur_cidr cur_ip cur_prefix
  local dns_ok=0 ping_ok=0 gw_ok=0 rc=0
  local domain reached=""

  PF_IFACE="$iface"
  PF_CIDR="$cidr"
  PF_ADDR_ADDED=0
  PF_ROUTE_ADDED=""
  PF_RESOLV_TMP=""
  # Ctrl+C pendant le test ne doit jamais laisser l'adresse secondaire en place.
  trap 'preflight_cleanup' EXIT
  trap 'preflight_cleanup; trap - EXIT INT TERM; exit 130' INT TERM

  banner "VÉRIFICATION À CHAUD DE LA CONFIGURATION"
  echo "L'adresse $ip va être ajoutée TEMPORAIREMENT en second sur $iface."
  echo "L'adresse actuelle reste active : votre session SSH ne sera pas coupée."
  echo ""

  # --- 1. Ajout de l'adresse secondaire ---------------------------------------
  if ip -o -4 addr show dev "$iface" 2>/dev/null | grep -qE "inet ${ip//./\\.}/"; then
    log_info "L'adresse $ip est déjà configurée sur $iface, test direct."
  else
    if ! ip addr add "$cidr" dev "$iface" 2>/dev/null; then
      log_err "Impossible d'ajouter $cidr sur $iface (adresse ou masque refusés par le noyau)."
      preflight_cleanup
      trap - EXIT INT TERM
      return 1
    fi
    PF_ADDR_ADDED=1
    log_ok "Adresse secondaire $cidr ajoutée sur $iface (temporaire)."
  fi

  # Si la nouvelle adresse est dans un autre sous-réseau que l'actuelle, aucune
  # route ne permet d'atteindre la passerelle depuis elle : on en ajoute une
  # temporaire, avec une métrique élevée pour ne pas perturber le trafic en cours.
  cur_cidr="$(current_cidr "$iface")"
  cur_ip="${cur_cidr%%/*}"
  cur_prefix="${cur_cidr##*/}"
  if [[ -n "$cur_ip" && -n "$cur_prefix" ]] && ! ip_in_subnet "$ip" "$cur_ip" "$cur_prefix"; then
    if ip route add "$gw" dev "$iface" src "$ip" metric 9000 >/dev/null 2>&1; then
      PF_ROUTE_ADDED="$gw dev $iface src $ip metric 9000"
      log_info "Route temporaire ajoutée vers la passerelle $gw (sous-réseau différent de l'actuel)."
    fi
  fi

  # --- 2. Joignabilité de la passerelle ---------------------------------------
  log_info "Test 1/3 — joignabilité de la passerelle $gw depuis $ip..."
  if ping -4 -c 2 -W 2 -I "$ip" -n "$gw" >/dev/null 2>&1; then
    gw_ok=1
    log_ok "Passerelle $gw joignable."
  else
    log_warn "Passerelle $gw injoignable depuis $ip."
    echo "  Causes possibles : mauvaise adresse de passerelle, mauvais masque," >&2
    echo "  ou passerelle qui ne répond pas au ping (certains routeurs le bloquent)." >&2
  fi

  # --- 3. Résolution DNS -------------------------------------------------------
  PF_RESOLV_TMP="$(mktemp /tmp/resolv.candidat.XXXXXX)"
  build_resolv_conf "$PF_RESOLV_TMP" "$dns"
  chmod 644 "$PF_RESOLV_TMP"

  echo ""
  log_info "Test 2/3 — résolution DNS avec : $dns"
  for domain in "${NET_TEST_DOMAINS[@]}"; do
    if probe_dns "$PF_RESOLV_TMP" "$domain"; then
      dns_ok=1
      log_ok "Résolution de $domain réussie."
      break
    fi
    log_warn "Échec de la résolution de $domain."
  done
  if (( ! dns_ok )); then
    log_err "Aucun des serveurs DNS indiqués ne répond."
  fi

  # --- 4. Connectivité de bout en bout ----------------------------------------
  echo ""
  log_info "Test 3/3 — connectivité depuis $ip (ping successif de ${NET_TEST_DOMAINS[*]})..."
  for domain in "${NET_TEST_DOMAINS[@]}"; do
    printf '   … %s : ' "$domain"
    if probe_ping_domain "$PF_RESOLV_TMP" "$ip" "$domain"; then
      echo "OK"
      ping_ok=1
      reached="$domain"
      break
    fi
    echo "pas de réponse"
  done

  # --- 5. Nettoyage ------------------------------------------------------------
  preflight_cleanup
  trap - EXIT INT TERM

  # --- 6. Synthèse -------------------------------------------------------------
  echo ""
  echo "------------------------------------------"
  echo "  RÉSULTAT DE LA VÉRIFICATION"
  echo "------------------------------------------"
  if (( gw_ok ));   then echo "  Passerelle $gw      : joignable"; else echo "  Passerelle $gw      : INJOIGNABLE"; fi
  if (( dns_ok ));  then echo "  Résolution DNS        : fonctionnelle"; else echo "  Résolution DNS        : EN ÉCHEC"; fi
  if (( ping_ok )); then echo "  Connectivité Internet : OK (via $reached)"; else echo "  Connectivité Internet : AUCUNE RÉPONSE"; fi
  echo "------------------------------------------"
  echo ""

  if (( dns_ok && ping_ok )); then
    log_ok "La configuration proposée est fonctionnelle."
    return 0
  fi

  # Distinguer « DNS cassé » de « ICMP filtré » évite un faux diagnostic : de
  # nombreux réseaux d'entreprise bloquent le ping sortant tout en laissant
  # passer le reste du trafic.
  if (( dns_ok && ! ping_ok )); then
    log_warn "Le DNS fonctionne mais aucun ping n'aboutit."
    echo "  C'est le comportement attendu si l'ICMP est filtré en sortie sur"
    echo "  votre réseau. La résolution de noms, elle, est bien opérationnelle."
    echo ""
    if ask_yes_no "Considérer la configuration comme valide ?" "o"; then
      return 0
    fi
  fi

  rc=1
  return "$rc"
}

################################################################################
# SECTION D — ÉCRITURE DE LA CONFIGURATION RÉSEAU
################################################################################

################################################################################
# FONCTION : Configuration statique pour ifupdown
################################################################################
# Points d'attention propres à Debian 13 :
#  - « netmask » et « broadcast » sont DÉPRÉCIÉS dans l'ifupdown de Trixie ;
#    la forme recommandée est la notation CIDR directement dans « address ».
#  - « dns-nameservers » n'a AUCUN effet si le paquet resolvconf n'est pas
#    installé (c'est un greffon fourni par ce paquet, pas une option d'ifupdown).
#    La ligne est écrite pour rester cohérente, mais la résolution DNS est
#    configurée séparément par configure_dns().
################################################################################
write_ifupdown_config() {
  local iface="${1:-}" cidr="${2:-}" gw="${3:-}" dns="${4:-}"
  local target tmp

  # Si /etc/network/interfaces inclut le répertoire interfaces.d, on y dépose un
  # fichier dédié : le fichier principal reste intact et la désinstallation est
  # triviale.
  if [[ -d /etc/network/interfaces.d ]] && grep -qE '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces 2>/dev/null; then
    target="/etc/network/interfaces.d/10-${iface}"
  else
    target="/etc/network/interfaces"
  fi

  backup_file "$target" || return 1

  if [[ "$target" == "/etc/network/interfaces" ]]; then
    # Retrait des strophes existantes de CETTE interface uniquement : lo et les
    # autres interfaces ne doivent pas être touchées. Une ligne « auto eth0 eth1 »
    # n'est pas supprimée : seule la mention de notre interface en est retirée.
    tmp="$(mktemp)"
    awk -v ifc="$iface" '
      function est_debut_strophe(l) {
        return (l ~ /^[[:space:]]*(auto|allow-[a-z]+|iface|mapping|source|source-directory|no-auto-down|no-scripts)([[:space:]]|$)/)
      }
      BEGIN { skip = 0 }
      {
        if (est_debut_strophe($0)) {
          skip = 0
          if ($1 == "iface" && $2 == ifc) { skip = 1; next }
          if ($1 ~ /^(auto|allow-[a-z]+)$/) {
            reste = $1; n = 0
            for (i = 2; i <= NF; i++) if ($i != ifc) { reste = reste " " $i; n++ }
            if (n == 0) next
            print reste
            next
          }
        }
        if (!skip) print
      }
    ' "$target" > "$tmp" && cat "$tmp" > "$target"
    rm -f "$tmp"

    {
      echo ""
      echo "# --- Interface $iface : adresse IP fixe ---"
      echo "# Générée par le script de personnalisation Debian 13 le $(date)"
      echo "auto ${iface}"
      echo "iface ${iface} inet static"
      echo "    address ${cidr}"
      echo "    gateway ${gw}"
      echo "    # dns-nameservers n'est pris en compte que si le paquet resolvconf"
      echo "    # est installé. La résolution DNS de ce serveur est configurée"
      echo "    # directement (voir /etc/resolv.conf)."
      echo "    dns-nameservers ${dns}"
    } >> "$target"
  else
    {
      echo "# Interface $iface : adresse IP fixe"
      echo "# Générée par le script de personnalisation Debian 13 le $(date)"
      echo "auto ${iface}"
      echo "iface ${iface} inet static"
      echo "    address ${cidr}"
      echo "    gateway ${gw}"
      echo "    dns-nameservers ${dns}"
    } > "$target"
    NET_GENERATED_FILES="$NET_GENERATED_FILES $target"
  fi

  NET_IFUPDOWN_FILE="$target"
  log_ok "Configuration écrite dans $target"

  # Une exécution d'une ancienne version de ce script a pu désactiver le service.
  if ! systemctl is-enabled --quiet networking 2>/dev/null; then
    log_info "Réactivation du service « networking » au démarrage..."
    systemctl enable networking >/dev/null 2>&1 || log_warn "Impossible de réactiver networking.service"
  fi
  return 0
}

################################################################################
# FONCTION : Configuration statique pour systemd-networkd
################################################################################
# Rappel important : la directive DNS= d'un fichier .network n'est lue que par
# systemd-resolved. Sur une Debian 13 minimale, ce paquet n'est PAS installé :
# la ligne est donc inopérante à elle seule. Elle est conservée pour le cas où
# systemd-resolved serait activé plus tard, mais la résolution est réellement
# assurée par configure_dns().
################################################################################
write_networkd_config() {
  local iface="${1:-}" cidr="${2:-}" gw="${3:-}" dns="${4:-}"
  local target="/etc/systemd/network/10-${iface}.network"

  mkdir -p /etc/systemd/network
  backup_file "$target"

  cat > "$target" <<EOF
# Configuration réseau pour l'interface $iface
# Générée automatiquement par le script de personnalisation Debian 13
# Date : $(date)

[Match]
# Nom de l'interface réseau à configurer
Name=${iface}

[Network]
# Adresse IP statique en notation CIDR
Address=${cidr}

# Passerelle par défaut (routeur)
Gateway=${gw}

# Serveur(s) DNS. ATTENTION : cette directive n'est exploitée que si
# systemd-resolved est installé et actif. La résolution DNS de ce serveur est
# également configurée dans /etc/resolv.conf pour fonctionner sans lui.
$(for s in $dns; do echo "DNS=${s}"; done)

[Link]
# L'interface est requise pour considérer le système comme « en ligne »
RequiredForOnline=yes
EOF

  NET_GENERATED_FILES="$NET_GENERATED_FILES $target"
  log_ok "Configuration écrite dans $target"

  if ! systemctl is-enabled --quiet systemd-networkd 2>/dev/null; then
    systemctl enable systemd-networkd >/dev/null 2>&1 || log_warn "Impossible d'activer systemd-networkd au démarrage"
  fi
  return 0
}

################################################################################
# FONCTION : Configuration statique pour NetworkManager
################################################################################
write_nm_config() {
  local iface="${1:-}" cidr="${2:-}" gw="${3:-}" dns="${4:-}"
  local con

  con="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$iface" '$2 == d { print $1; exit }')"
  if [[ -z "$con" ]]; then
    con="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$iface" '$2 == d { print $1; exit }')"
  fi
  if [[ -z "$con" ]]; then
    log_err "Aucun profil NetworkManager ne correspond à l'interface $iface."
    return 1
  fi

  NET_NM_CONNECTION="$con"
  log_info "Profil NetworkManager visé : « $con »"

  if ! nmcli connection modify "$con" \
        ipv4.addresses "$cidr" \
        ipv4.gateway "$gw" \
        ipv4.dns "${dns// /,}" \
        ipv4.ignore-auto-dns yes \
        ipv4.method manual; then
    log_err "Échec de la modification du profil NetworkManager « $con »."
    return 1
  fi

  log_ok "Profil « $con » configuré en IP fixe (non appliqué pour l'instant)."
  return 0
}

################################################################################
# FONCTION : Configuration de la résolution DNS
################################################################################
# C'EST LE POINT QUI CASSAIT LA RÉSOLUTION DE NOMS.
#
# Il n'existe pas UNE façon de configurer le DNS sur Debian : cela dépend de ce
# qui est installé. On applique donc, par ordre de priorité :
#
#  1. systemd-resolved actif  → fichier de surcharge dans resolved.conf.d et
#     /etc/resolv.conf pointé sur le résolveur local (127.0.0.53).
#  2. resolvconf / openresolv → c'est lui qui génère /etc/resolv.conf ; on lui
#     fournit les serveurs et on le laisse faire.
#  3. Aucun des deux (CAS PAR DÉFAUT SUR DEBIAN 13) → /etc/resolv.conf est un
#     fichier ordinaire, écrit par l'installateur. L'écrire directement est la
#     méthode supportée. On empêche en outre dhcpcd de l'écraser.
#
# La version précédente du script se contentait d'écrire « DNS= » dans un
# fichier .network, directive que seul systemd-resolved sait lire : sans lui,
# la résolution de noms cessait purement et simplement de fonctionner.
################################################################################
configure_dns() {
  local dns="${1:-}" srv

  banner "CONFIGURATION DE LA RÉSOLUTION DNS"

  # --- Cas 1 : systemd-resolved ------------------------------------------------
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    DNS_METHOD="resolved"
    log_info "systemd-resolved est actif : configuration via resolved.conf.d."
    mkdir -p /etc/systemd/resolved.conf.d
    backup_file /etc/systemd/resolved.conf.d/90-personnalisation.conf
    {
      echo "# Généré par le script de personnalisation Debian 13 le $(date)"
      echo "[Resolve]"
      printf 'DNS=%s\n' "$dns"
      echo "FallbackDNS=9.9.9.9 1.1.1.1"
    } > /etc/systemd/resolved.conf.d/90-personnalisation.conf
    NET_GENERATED_FILES="$NET_GENERATED_FILES /etc/systemd/resolved.conf.d/90-personnalisation.conf"

    # /etc/resolv.conf doit pointer sur le résolveur local, sinon les réglages
    # ci-dessus ne sont jamais consultés par les applications.
    if [[ "$(readlink -f /etc/resolv.conf 2>/dev/null)" != /run/systemd/resolve/* ]]; then
      backup_file /etc/resolv.conf
      ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
      log_ok "/etc/resolv.conf redirigé vers le résolveur systemd (127.0.0.53)."
    fi

    run_cmd "Redémarrage de systemd-resolved..." systemctl restart systemd-resolved
    log_ok "DNS configuré : $dns (via systemd-resolved)"
    return 0
  fi

  # --- Cas 2 : resolvconf / openresolv -----------------------------------------
  if command -v resolvconf >/dev/null 2>&1; then
    DNS_METHOD="resolvconf"
    log_info "resolvconf est installé : il générera /etc/resolv.conf."
    backup_file /etc/resolvconf/resolv.conf.d/head 2>/dev/null || true
    if [[ -d /etc/resolvconf/resolv.conf.d ]]; then
      {
        echo "# Généré par le script de personnalisation Debian 13"
        for srv in $dns; do echo "nameserver $srv"; done
      } > /etc/resolvconf/resolv.conf.d/head
      NET_GENERATED_FILES="$NET_GENERATED_FILES /etc/resolvconf/resolv.conf.d/head"
    fi
    resolvconf -u >/dev/null 2>&1 || log_warn "resolvconf -u a échoué ; /etc/resolv.conf sera régénéré au prochain ifup."
    log_ok "DNS configuré : $dns (via resolvconf)"
    return 0
  fi

  # --- Cas 3 : /etc/resolv.conf en clair (défaut Debian 13) --------------------
  DNS_METHOD="resolvconf-file"
  log_info "Ni systemd-resolved ni resolvconf : /etc/resolv.conf est un fichier ordinaire."
  echo "  C'est la situation normale d'une installation Debian 13 minimale :"
  echo "  l'installateur écrit ce fichier directement, et l'éditer est la"
  echo "  méthode supportée."
  echo ""

  if [[ -L /etc/resolv.conf ]]; then
    log_warn "/etc/resolv.conf est un lien symbolique vers $(readlink /etc/resolv.conf)."
    echo "  Il sera remplacé par un fichier ordinaire contenant vos serveurs DNS."
    echo ""
  fi

  backup_file /etc/resolv.conf
  rm -f /etc/resolv.conf
  build_resolv_conf /etc/resolv.conf "$dns"
  chmod 644 /etc/resolv.conf
  log_ok "DNS configuré : $dns (dans /etc/resolv.conf)"

  # dhcpcd est le client DHCP par défaut de Debian 13 (il a remplacé
  # isc-dhcp-client, abandonné en amont). Son greffon « resolv.conf » réécrit
  # /etc/resolv.conf à chaque bail et le vide quand un bail est abandonné :
  # c'est l'autre moitié de la panne de résolution constatée après un passage en
  # IP fixe. On le neutralise — et le retour arrière retire cette ligne.
  if [[ -f /etc/dhcpcd.conf ]] && ! grep -qE '^[[:space:]]*nohook[[:space:]]+resolv\.conf' /etc/dhcpcd.conf; then
    backup_file /etc/dhcpcd.conf
    {
      echo ""
      echo "# Ajouté par le script de personnalisation Debian 13 le $(date)"
      echo "# Empêche dhcpcd d'écraser /etc/resolv.conf, désormais géré manuellement."
      echo "nohook resolv.conf"
    } >> /etc/dhcpcd.conf
    DHCPCD_NOHOOK_ADDED=1
    log_ok "dhcpcd configuré pour ne plus écraser /etc/resolv.conf."
  fi
  return 0
}

################################################################################
# SECTION E — BASCULE DIFFÉRÉE ET RETOUR ARRIÈRE AUTOMATIQUE
################################################################################

################################################################################
# FONCTION : Installation des outils de bascule et de retour arrière
################################################################################
# Quatre commandes sont installées dans /usr/local/sbin :
#
#   ip-fixe-appliquer  applique réellement la nouvelle configuration ;
#   ip-fixe-rollback   restaure l'état antérieur (retour au DHCP) ;
#   ip-fixe-confirmer  valide définitivement et désarme tous les garde-fous ;
#   ip-fixe-watchdog   vérifie la connectivité au premier démarrage.
#
# Elles sont exécutées par systemd, donc totalement détachées de la session SSH.
# C'est indispensable : si « ifdown » coupait la connexion alors que le script
# tourne encore dans le shell distant, celui-ci recevrait SIGHUP et « ifup » ne
# serait jamais exécuté — le serveur resterait hors ligne.
################################################################################
install_network_tools() {
  mkdir -p "$STATE_DIR"

  # Un drapeau de confirmation laissé par une exécution PRÉCÉDENTE désarmerait
  # immédiatement les garde-fous de la bascule qui commence. On repart de zéro.
  rm -f "$CONFIRMED_FLAG" "$RUNTIME_CONFIRMED_FLAG"

  # --- État persistant partagé par tous les outils -----------------------------
  cat > "$ROLLBACK_STATE" <<EOF
# État de la bascule IP fixe — généré le $(date)
NET_STACK='${NET_STACK}'
NET_IFACE='${INTERFACE}'
NET_CIDR='${STATIC_IP}'
NET_IP='${STATIC_IP_BARE}'
NET_GATEWAY='${GATEWAY}'
NET_DNS='${DNS_SERVERS}'
NET_NM_CONNECTION='${NET_NM_CONNECTION}'
NET_IFUPDOWN_FILE='${NET_IFUPDOWN_FILE}'
NET_GENERATED_FILES='${NET_GENERATED_FILES}'
DHCPCD_NOHOOK_ADDED='${DHCPCD_NOHOOK_ADDED}'
DNS_METHOD='${DNS_METHOD}'
BACKUP_MANIFEST='${NET_BACKUP_MANIFEST}'
CONFIRMED_FLAG='${CONFIRMED_FLAG}'
RUNTIME_CONFIRMED_FLAG='${RUNTIME_CONFIRMED_FLAG}'
TEST_DOMAINS='${NET_TEST_DOMAINS[*]}'
EOF
  chmod 600 "$ROLLBACK_STATE"

  # --- Bibliothèque commune ----------------------------------------------------
  cat > /usr/local/sbin/ip-fixe-commun <<'COMMON'
#!/bin/bash
# Fonctions partagées par les outils de bascule IP fixe.
# Généré par le script de personnalisation Debian 13.
set -u
STATE_FILE="/var/lib/personnalisation-debian13/rollback.env"

charger_etat() {
  [ -r "$STATE_FILE" ] || { echo "État introuvable : $STATE_FILE" >&2; return 1; }
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

est_confirme() {
  [ -e "${CONFIRMED_FLAG:-/var/lib/personnalisation-debian13/confirmed}" ] && return 0
  [ -e "${RUNTIME_CONFIRMED_FLAG:-/run/personnalisation-debian13.confirmed}" ] && return 0
  return 1
}

journal() { logger -t ip-fixe "$*" 2>/dev/null; echo "$*"; }

# Applique la configuration réseau en vigueur dans les fichiers, quelle que soit
# la pile utilisée. Utilisé aussi bien pour la bascule que pour le retour.
appliquer_pile() {
  case "${NET_STACK:-}" in
    ifupdown)
      systemctl enable networking >/dev/null 2>&1
      ifdown --force "$NET_IFACE" >/dev/null 2>&1
      # Un client DHCP encore actif reprendrait la main sur l'interface. Sur
      # Debian 13 c'est dhcpcd (isc-dhcp-client/dhclient a été abandonné en
      # amont), mais une machine mise à niveau depuis Bookworm peut encore
      # utiliser dhclient : on relâche proprement le bail avec l'outil présent,
      # sans supposer qu'un binaire donné existe.
      if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -k "$NET_IFACE" >/dev/null 2>&1
      fi
      if command -v dhclient >/dev/null 2>&1; then
        dhclient -r "$NET_IFACE" >/dev/null 2>&1
      fi
      pkill -f "dhcpcd.*${NET_IFACE}" >/dev/null 2>&1
      ip addr flush dev "$NET_IFACE" >/dev/null 2>&1
      ifup "$NET_IFACE"
      ;;
    networkd)
      systemctl enable systemd-networkd >/dev/null 2>&1
      systemctl restart systemd-networkd
      networkctl reload >/dev/null 2>&1
      networkctl reconfigure "$NET_IFACE" >/dev/null 2>&1
      ;;
    networkmanager)
      nmcli connection up "$NET_NM_CONNECTION"
      ;;
    *)
      journal "Pile réseau inconnue : ${NET_STACK:-vide}"
      return 1
      ;;
  esac
}

# Teste la connectivité : passerelle, puis résolution de noms.
tester_connectivite() {
  local d ok=1
  ping -4 -c 2 -W 2 -n "${NET_GATEWAY:-}" >/dev/null 2>&1 || ok=0
  for d in ${TEST_DOMAINS:-example.org}; do
    if getent ahostsv4 "$d" >/dev/null 2>&1; then
      return 0
    fi
  done
  [ "$ok" = "1" ] && return 0
  return 1
}
COMMON
  chmod 755 /usr/local/sbin/ip-fixe-commun

  # --- Application de la nouvelle configuration --------------------------------
  cat > /usr/local/sbin/ip-fixe-appliquer <<'APPLY'
#!/bin/bash
# Applique la configuration IP fixe préparée par le script de personnalisation.
# Exécuté par systemd (donc détaché de toute session SSH).
set -u
. /usr/local/sbin/ip-fixe-commun
charger_etat || exit 1
journal "Application de la configuration IP fixe ${NET_CIDR} sur ${NET_IFACE} (pile ${NET_STACK})"
appliquer_pile
rc=$?
sleep 3
if tester_connectivite; then
  journal "Nouvelle configuration active et fonctionnelle."
else
  journal "ATTENTION : la nouvelle configuration ne répond pas. Le retour automatique interviendra à l'échéance prévue."
fi
exit "$rc"
APPLY
  chmod 755 /usr/local/sbin/ip-fixe-appliquer

  # --- Retour arrière -----------------------------------------------------------
  cat > /usr/local/sbin/ip-fixe-rollback <<'ROLLBACK'
#!/bin/bash
# Restaure la configuration réseau antérieure (retour au DHCP) si le changement
# d'adresse IP n'a pas été confirmé.
set -u
. /usr/local/sbin/ip-fixe-commun
charger_etat || exit 1

if est_confirme; then
  journal "Changement d'IP déjà confirmé : aucun retour arrière."
  exit 0
fi

journal "AUCUNE CONFIRMATION REÇUE — restauration de la configuration réseau précédente."

# 1. Suppression des fichiers créés par le script.
for f in ${NET_GENERATED_FILES:-}; do
  [ -n "$f" ] && rm -f "$f"
done

# 2. Restauration des sauvegardes (l'état d'origine, donc le DHCP).
if [ -r "${BACKUP_MANIFEST:-}" ]; then
  while IFS=$'\t' read -r orig sauvegarde; do
    [ -n "${orig:-}" ] || continue
    [ -e "${sauvegarde:-}" ] || [ -L "${sauvegarde:-}" ] || continue
    rm -f "$orig"
    cp -a "$sauvegarde" "$orig"
    journal "Restauré : $orig"
  done < "$BACKUP_MANIFEST"
fi

# 3. dhcpcd doit à nouveau pouvoir gérer /etc/resolv.conf.
if [ "${DHCPCD_NOHOOK_ADDED:-0}" = "1" ] && [ -f /etc/dhcpcd.conf ]; then
  sed -i '/^[[:space:]]*nohook[[:space:]]\+resolv\.conf[[:space:]]*$/d' /etc/dhcpcd.conf
fi

# 4. Rechargement des démons concernés puis réapplication.
systemctl daemon-reload >/dev/null 2>&1
if [ "${NET_STACK:-}" = "networkmanager" ] && [ -n "${NET_NM_CONNECTION:-}" ]; then
  nmcli connection modify "$NET_NM_CONNECTION" ipv4.method auto \
        ipv4.addresses "" ipv4.gateway "" ipv4.dns "" ipv4.ignore-auto-dns no >/dev/null 2>&1
fi
appliquer_pile

# 5. Désarmement des garde-fous : le retour a eu lieu, il ne doit pas se répéter.
systemctl disable ip-fixe-watchdog.service >/dev/null 2>&1
rm -f /etc/systemd/system/ip-fixe-watchdog.service
systemctl daemon-reload >/dev/null 2>&1

sleep 3
if tester_connectivite; then
  journal "Retour au DHCP effectué, le réseau répond de nouveau."
else
  journal "Retour au DHCP effectué mais le réseau ne répond toujours pas : une intervention console est nécessaire."
fi
exit 0
ROLLBACK
  chmod 755 /usr/local/sbin/ip-fixe-rollback

  # --- Confirmation --------------------------------------------------------------
  cat > /usr/local/sbin/ip-fixe-confirmer <<'CONFIRM'
#!/bin/bash
# Confirme définitivement le changement d'adresse IP et désarme tous les
# mécanismes de retour automatique.
set -u
. /usr/local/sbin/ip-fixe-commun
charger_etat || exit 1

mkdir -p "$(dirname "${CONFIRMED_FLAG}")"
touch "${CONFIRMED_FLAG}"
touch "${RUNTIME_CONFIRMED_FLAG}"

systemctl stop ip-fixe-rollback.timer >/dev/null 2>&1
systemctl stop ip-fixe-rollback.service >/dev/null 2>&1
systemctl reset-failed ip-fixe-rollback.timer ip-fixe-rollback.service >/dev/null 2>&1
systemctl disable ip-fixe-watchdog.service >/dev/null 2>&1
rm -f /etc/systemd/system/ip-fixe-watchdog.service
systemctl daemon-reload >/dev/null 2>&1

echo "✓ Changement d'adresse IP confirmé."
echo "  Adresse   : ${NET_CIDR}"
echo "  Interface : ${NET_IFACE}"
echo "  Le retour automatique au DHCP est désactivé."
journal "Changement d'IP confirmé par l'administrateur."
exit 0
CONFIRM
  chmod 755 /usr/local/sbin/ip-fixe-confirmer

  # --- Garde-fou au démarrage -----------------------------------------------------
  cat > /usr/local/sbin/ip-fixe-watchdog <<'WATCHDOG'
#!/bin/bash
# Vérifie la connectivité au premier démarrage suivant un changement d'IP.
# En cas d'échec, restaure automatiquement la configuration précédente.
set -u
. /usr/local/sbin/ip-fixe-commun
charger_etat || exit 0

if est_confirme; then
  systemctl disable ip-fixe-watchdog.service >/dev/null 2>&1
  rm -f /etc/systemd/system/ip-fixe-watchdog.service
  systemctl daemon-reload >/dev/null 2>&1
  exit 0
fi

# Laisser au réseau le temps de s'établir complètement.
n=0
while [ "$n" -lt 6 ]; do
  if tester_connectivite; then
    # Le garde-fou protège LE PREMIER DÉMARRAGE suivant le changement : sa
    # mission est terminée, il se retire. Il ne marque surtout PAS le changement
    # comme confirmé : seule la commande ip-fixe-confirmer, lancée par
    # l'administrateur, a ce pouvoir. Se désarmer n'est pas confirmer.
    # Le laisser en place indéfiniment serait dangereux : une panne réseau sans
    # rapport, des mois plus tard, ferait revenir le serveur au DHCP tout seul.
    journal "Démarrage avec l'IP fixe : réseau fonctionnel. Garde-fou de démarrage retiré (le changement reste à confirmer avec « ip-fixe-confirmer »)."
    systemctl disable ip-fixe-watchdog.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ip-fixe-watchdog.service
    systemctl daemon-reload >/dev/null 2>&1
    exit 0
  fi
  n=$((n + 1))
  sleep 10
done

journal "Démarrage avec l'IP fixe : aucune connectivité après 60 s, retour à la configuration précédente."
/usr/local/sbin/ip-fixe-rollback
exit 0
WATCHDOG
  chmod 755 /usr/local/sbin/ip-fixe-watchdog

  cat > /etc/systemd/system/ip-fixe-watchdog.service <<'UNIT'
[Unit]
Description=Garde-fou IP fixe (retour automatique au DHCP si le réseau ne répond pas)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ip-fixe-watchdog
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable ip-fixe-watchdog.service >/dev/null 2>&1
  log_ok "Garde-fou de démarrage installé (retour automatique au DHCP si le réseau ne répond pas)."
  return 0
}

################################################################################
# SECTION F — FONCTIONS D'INTERFACE (étape 1)
################################################################################

################################################################################
# FONCTION : Afficher l'explication de la coloration syntaxique
################################################################################
afficher_explication() {
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
    echo "   - L'invite de commande (\$) est clairement visible"
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
# Le bloc injecté dans /root/.bashrc est encadré par des marqueurs uniques : une
# nouvelle exécution du script REMPLACE ce bloc au lieu de l'ajouter une seconde
# fois. L'ancienne version testait la présence du prompt avec un motif grep qui
# ne correspondait jamais au texte réellement écrit, si bien que chaque
# exécution empilait un nouveau bloc dans le fichier.
################################################################################
BASHRC_MARK_BEGIN="# >>> personnalisation-debian13 (coloration) >>>"
BASHRC_MARK_END="# <<< personnalisation-debian13 (coloration) <<<"

activer_coloration() {
    echo "========================================"
    echo "  ACTIVATION DE LA COLORATION"
    echo "========================================"
    echo ""
    echo "Configuration du fichier ~/.bashrc de root..."

    if [ ! -f /root/.bashrc ]; then
        log_info "Fichier .bashrc non trouvé pour root, création..."
        touch /root/.bashrc
        log_ok "Fichier créé"
    else
        log_ok "Fichier .bashrc existant trouvé"
        backup_file /root/.bashrc
    fi

    write_marked_block /root/.bashrc "$BASHRC_MARK_BEGIN" "$BASHRC_MARK_END" <<'EOF'
# Bloc géré automatiquement : il est remplacé, jamais dupliqué, à chaque
# exécution du script de personnalisation.

# Force le prompt coloré même quand le terminal n'est pas détecté comme tel.
force_color_prompt=yes

# Prompt coloré pour root : vert pour user@host, bleu pour le chemin.
if [ "$force_color_prompt" = yes ]; then
    if [ -n "$TERM" ] && [[ "$TERM" =~ (xterm|vt100|linux|screen|tmux) ]]; then
        PS1='\[\033[01;32m\]\u@\h:\[\033[01;34m\]\w\[\033[00m\]\$ '
    fi
fi

# Coloration de ls et grep.
if [ -x /usr/bin/dircolors ]; then
    eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi
EOF

    COLORATION_DONE=1

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
# SECTION G — FONCTIONS SSH
################################################################################

################################################################################
# FONCTION : Positionner une directive dans un fichier sshd_config
################################################################################
# Remplace la directive si elle existe (commentée ou non), l'AJOUTE sinon.
# L'ancienne version se contentait d'un « sed » de substitution : sur une
# configuration où la directive était absente (images cloud, configurations
# durcies), rien n'était modifié alors que le script annonçait un succès.
################################################################################
set_sshd_directive() {
  local file="${1:-}" key="${2:-}" value="${3:-}"
  [[ -n "$file" && -n "$key" ]] || return 1
  if [[ ! -e "$file" ]]; then
    printf '# Généré par le script de personnalisation Debian 13 le %s\n' "$(date)" > "$file"
    chmod 644 "$file"
  fi

  if grep -qiE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$file"; then
    # La valeur est passée à sed via un fichier de script pour éviter toute
    # interprétation des caractères spéciaux qu'elle pourrait contenir.
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "$file"
  else
    printf '%s %s\n' "$key" "$value" >> "$file"
  fi
}

################################################################################
# FONCTION : SSH est-il démarré par activation de socket ?
################################################################################
# CHANGEMENT MAJEUR DE DEBIAN 13 : sur une installation neuve, sshd est démarré
# par « ssh.socket » et non par « ssh.service ». C'est alors la socket qui
# choisit le port d'écoute : la directive « Port » de sshd_config est purement
# et simplement IGNORÉE.
#
# L'ancienne version modifiait « Port » puis redémarrait ssh.service, et
# affichait « configuration appliquée » — alors que le serveur continuait
# d'écouter sur le port 22.
################################################################################
ssh_socket_active() {
  systemctl is-enabled --quiet ssh.socket 2>/dev/null && return 0
  systemctl is-active --quiet ssh.socket 2>/dev/null && return 0
  systemctl show ssh.service -p TriggeredBy --value 2>/dev/null | grep -q 'ssh\.socket' && return 0
  return 1
}

################################################################################
# FONCTION : Fichier de configuration sshd à utiliser
################################################################################
# Debian place « Include /etc/ssh/sshd_config.d/*.conf » EN TÊTE de
# sshd_config. Or sshd retient la PREMIÈRE valeur rencontrée pour chaque
# directive : les fichiers du répertoire d'inclusion l'emportent donc sur le
# fichier principal. Y écrire est la méthode propre — et cela évite qu'une
# directive posée dans le fichier principal reste sans effet parce qu'une image
# cloud a déposé la sienne dans le répertoire.
################################################################################
sshd_target_file() {
  if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    mkdir -p /etc/ssh/sshd_config.d
    printf '/etc/ssh/sshd_config.d/99-personnalisation.conf'
  else
    printf '/etc/ssh/sshd_config'
  fi
}

################################################################################
# SECTION H — AUTHENTIFICATION PAR CLÉ SSH
################################################################################
# Deux faces du même mécanisme :
#   - côté CLIENT  : générer une paire de clés (privée gardée sur la machine,
#                    publique déposée sur les serveurs) ;
#   - côté SERVEUR : inscrire une clé publique dans ~/.ssh/authorized_keys.
#
# Les validateurs sont volontairement PURS : ils n'appellent ni ssh-keygen, ni
# le réseau, ni le système. La suite de tests peut ainsi les éprouver sur
# n'importe quelle machine, y compris sans OpenSSH installé.
################################################################################

################################################################################
# FONCTION : Reconnaissance d'une clé publique OpenSSH
################################################################################
# « ssh-dss » (DSA) est volontairement ABSENT de la liste : OpenSSH le refuse
# par défaut depuis la version 7.0 et l'a retiré en 9.8. L'accepter donnerait
# une clé installée mais définitivement inutilisable — le pire des cas, puisque
# l'utilisateur croirait son accès en place.
################################################################################
SSH_PUBKEY_TYPES='ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com'

ssh_pubkey_type() { printf '%s' "${1:-}" | awk '{ print $1 }'; }
ssh_pubkey_body() { printf '%s' "${1:-}" | awk '{ print $2 }'; }

################################################################################
# FONCTION : Début attendu du base64 pour un type de clé donné
################################################################################
# Le contenu binaire d'une clé publique OpenSSH commence toujours par la
# longueur du nom de l'algorithme (4 octets) suivie du nom lui-même. Son
# encodage base64 est donc entièrement prévisible : « ssh-ed25519 » commence
# forcément par « AAAAC3NzaC1lZDI1NTE5 ».
#
# Ce contrôle croisé écarte les lignes dont l'entête a été bricolée à la main
# (type recopié devant le corps d'une autre clé), que la seule vérification du
# format ne repérerait pas.
#
# Seuls les caractères issus de groupes de 3 octets COMPLETS sont stables : les
# suivants dépendent déjà des octets de la clé elle-même.
################################################################################
ssh_pubkey_b64_prefix() {
  local type="${1:-}" n b64 groupes
  [[ -n "$type" ]] || return 1
  command -v base64 >/dev/null 2>&1 || return 1
  n=${#type}
  (( n > 0 && n < 256 )) || return 1
  b64="$(printf '%b%s' "\\0000\\0000\\0000\\0$(printf '%03o' "$n")" "$type" | base64 2>/dev/null | tr -d '\n')" || return 1
  [[ -n "$b64" ]] || return 1
  # Nombre de groupes de 3 octets complets, puis 4 caractères base64 par groupe.
  groupes=$(( (4 + n) / 3 ))
  printf '%s' "${b64:0:$(( groupes * 4 ))}"
}

is_ssh_pubkey() {
  local line="${1:-}" type body prefix

  type="$(ssh_pubkey_type "$line")"
  body="$(ssh_pubkey_body "$line")"
  [[ -n "$type" && -n "$body" ]] || return 1

  # Une ligne d'authorized_keys peut débuter par des options
  # (« command="…",no-pty ssh-ed25519 AAAA… »). Ce script n'en pose pas et n'en
  # accepte pas : une option mal recopiée est un risque de sécurité muet.
  [[ "$type" =~ ^(${SSH_PUBKEY_TYPES})$ ]] || return 1

  # Corps en base64 « standard », suffisamment long : un copier-coller tronqué
  # au milieu de la clé est ainsi écarté.
  [[ "$body" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || return 1
  (( ${#body} >= 32 )) || return 1

  # Si base64 n'est pas disponible, on s'en tient aux contrôles ci-dessus.
  prefix="$(ssh_pubkey_b64_prefix "$type")" || return 0
  [[ -n "$prefix" ]] || return 0
  [[ "${body:0:${#prefix}}" == "$prefix" ]] || return 1
  return 0
}

################################################################################
# FONCTION : Validateur de clé publique (pour ask_input)
################################################################################
v_pubkey() {
  local line="${1:-}" type

  if [[ "$line" == *"PRIVATE KEY"* || "$line" == *"BEGIN OPENSSH"* ]]; then
    log_err "C'est une clé PRIVÉE — ne la diffusez jamais, et changez-la si elle a circulé."
    echo "  Le fichier attendu est celui qui se termine par « .pub »." >&2
    return 1
  fi

  type="$(ssh_pubkey_type "$line")"

  if [[ "$type" == "ssh-dss" ]]; then
    log_warn "Les clés DSA (ssh-dss) sont refusées par OpenSSH depuis la version 7."
    echo "  Générez une clé ed25519 à la place." >&2
    return 1
  fi

  if [[ "$line" == /* || "$line" == ~* ]]; then
    log_warn "Vous avez saisi un CHEMIN, pas une clé."
    echo "  Utilisez l'option « lire depuis un fichier », ou collez le contenu" >&2
    echo "  de la clé publique (une seule ligne, commençant par le type)." >&2
    return 1
  fi

  if ! is_ssh_pubkey "$line"; then
    log_warn "Ceci n'est pas une clé publique OpenSSH exploitable."
    echo "  Attendu : « <type> <base64> [commentaire] », par exemple" >&2
    echo "    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... jean@portable" >&2
    echo "  Types acceptés : ed25519, rsa, ecdsa, et leurs variantes FIDO2 (sk-)." >&2
    return 1
  fi
  return 0
}

################################################################################
# FONCTIONS : Validateurs de saisie liés aux clés
################################################################################
v_key_name() {
  local name="${1:-}"
  if [[ "$name" == */* ]]; then
    log_warn "Indiquez seulement le NOM du fichier, sans « / » : l'emplacement est demandé à part."
    return 1
  fi
  if (( ${#name} > 64 )); then
    log_warn "Le nom du fichier ne doit pas dépasser 64 caractères."
    return 1
  fi
  if [[ "$name" == *.pub ]]; then
    log_warn "« .pub » désigne la clé PUBLIQUE : donnez le nom de base, le fichier .pub sera créé tout seul."
    return 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    log_warn "« $name » est invalide : lettres, chiffres, « . », « - » et « _ », en commençant par une lettre ou un chiffre."
    return 1
  fi
  return 0
}

v_abs_dir() {
  local dir="${1:-}"
  if [[ "$dir" != /* ]]; then
    log_warn "Indiquez un chemin ABSOLU, commençant par « / » (exemple : /home/jean/.ssh)."
    return 1
  fi
  if [[ "$dir" =~ (^|/)\.\.(/|$) ]]; then
    log_warn "Le chemin ne doit pas contenir « .. »."
    return 1
  fi
  if [[ "$dir" =~ [[:space:]] ]]; then
    log_warn "Évitez les espaces dans un chemin de clé SSH : plusieurs outils les gèrent mal."
    return 1
  fi
  if [[ -e "$dir" && ! -d "$dir" ]]; then
    log_warn "« $dir » existe déjà et n'est pas un répertoire."
    return 1
  fi
  return 0
}

# Format d'un nom de compte UNIX, sans vérifier son existence : utilisé pour le
# compte d'un serveur DISTANT, que cette machine ne connaît pas.
v_user_name() {
  local user="${1:-}"
  if (( ${#user} > 32 )) || [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; then
    log_warn "« $user » n'est pas un nom d'utilisateur valide."
    return 1
  fi
  return 0
}

# Comptes susceptibles d'ouvrir une session : root et les comptes humains.
ssh_login_users() {
  getent passwd 2>/dev/null |
    awk -F: '($3 == 0 || ($3 >= 1000 && $3 < 65000)) { print $1 }'
}

v_ssh_user() {
  local user="${1:-}"
  v_user_name "$user" || return 1
  if ! getent passwd "$user" >/dev/null 2>&1; then
    log_warn "Le compte « $user » n'existe pas sur cette machine."
    echo "  Comptes disponibles : $(ssh_login_users | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

v_ssh_host() {
  local host="${1:-}"
  is_ipaddr "$host" && return 0
  if (( ${#host} <= 253 )) && [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    return 0
  fi
  log_warn "« $host » n'est ni un nom d'hôte ni une adresse IP valide."
  return 1
}

v_ssh_alias() {
  local name="${1:-}"
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    log_warn "L'alias doit être un mot simple, sans espace (exemple : monserveur)."
    return 1
  fi
  return 0
}

################################################################################
# FONCTION : La clé est-elle déjà présente dans un authorized_keys ?
################################################################################
# La comparaison porte sur le CORPS de la clé, jamais sur la ligne entière : le
# commentaire final varie d'une machine à l'autre, et comparer les lignes
# créerait des doublons pour une seule et même clé.
################################################################################
authkeys_contains() {
  local file="${1:-}" line="${2:-}" body
  [[ -f "$file" ]] || return 1
  body="$(ssh_pubkey_body "$line")"
  [[ -n "$body" ]] || return 1
  awk -v b="$body" '
    /^[[:space:]]*#/ { next }
    { for (i = 1; i <= NF; i++) if ($i == b) { found = 1; exit } }
    END { exit !found }
  ' "$file"
}

################################################################################
# FONCTION : Garantir un saut de ligne final
################################################################################
# Un authorized_keys dont la dernière ligne n'est pas terminée par un saut de
# ligne colle la clé suivante à la précédente : les DEUX deviennent invalides,
# et l'utilisateur perd un accès qui fonctionnait.
#
# Astuce : la substitution de commande retire les sauts de ligne finaux. Si le
# résultat est vide, c'est que le dernier octet en était un.
################################################################################
ensure_trailing_newline() {
  local file="${1:-}"
  [[ -n "$file" ]] || return 1
  [[ -s "$file" ]] || return 0
  if [[ -n "$(tail -c 1 "$file" 2>/dev/null)" ]]; then
    printf '\n' >> "$file"
  fi
  return 0
}

################################################################################
# FONCTIONS : Renseignements sur un compte
################################################################################
# Le répertoire personnel est lu dans la base des comptes, jamais déduit de
# « /home/<user> » : celui de root est /root, et un compte peut avoir un home
# ailleurs.
################################################################################
ssh_user_home() {
  local home
  home="$(getent passwd "${1:-}" 2>/dev/null | cut -d: -f6)"
  [[ -n "$home" ]] || return 1
  printf '%s' "$home"
}

ssh_user_group() {
  local group
  group="$(id -gn "${1:-}" 2>/dev/null)" || return 1
  printf '%s' "$group"
}

ssh_user_shell() {
  getent passwd "${1:-}" 2>/dev/null | cut -d: -f7
}

################################################################################
# FONCTION : Valeur RÉELLEMENT appliquée d'une directive sshd
################################################################################
# « sshd -T » donne la configuration effective, tous fichiers inclus. C'est le
# seul moyen fiable de vérifier qu'une directive a bien pris : sshd retient la
# PREMIÈRE valeur rencontrée, et un fichier déposé par une image cloud dans
# /etc/ssh/sshd_config.d/ peut très bien l'emporter sur la nôtre.
################################################################################
sshd_effective() {
  local key="${1:-}" bin out
  [[ -n "$key" ]] || return 1
  bin="$(command -v sshd || echo /usr/sbin/sshd)"
  [[ -x "$bin" ]] || return 1
  # Un bloc « Match » peut exiger un contexte de connexion : on le fournit en
  # deuxième tentative plutôt que d'abandonner.
  out="$("$bin" -T 2>/dev/null)" ||
    out="$("$bin" -T -C "user=root,host=localhost,addr=127.0.0.1" 2>/dev/null)" ||
    return 1
  printf '%s\n' "$out" | awk -v k="${key,,}" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'
}

################################################################################
# FONCTION : Quel fichier impose une directive ?
################################################################################
# Sert à expliquer pourquoi une directive posée par le script reste sans effet.
################################################################################
sshd_directive_sources() {
  local key="${1:-}"
  [[ -n "$key" ]] || return 1
  grep -rliE "^[[:space:]]*${key}[[:space:]]" \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sort
}

################################################################################
# FONCTION : Prise en compte d'une nouvelle configuration sshd
################################################################################
# En activation par socket, sshd n'est pas un service résident : chaque
# connexion démarre un processus neuf qui relit la configuration. Il n'y a donc
# rien à recharger — et « systemctl reload ssh » échouerait, le service n'étant
# pas actif.
################################################################################
ssh_reload_config() {
  local bin
  bin="$(command -v sshd || echo /usr/sbin/sshd)"
  "$bin" -t 2>/dev/null || return 1

  if systemctl is-active --quiet ssh.service 2>/dev/null; then
    systemctl reload ssh.service >/dev/null 2>&1 && return 0
    systemctl restart ssh.service >/dev/null 2>&1 && return 0
    return 1
  fi

  # ssh.service inactif : il n'y a rien à recharger, et surtout rien à
  # DÉMARRER. En activation par socket, c'est ssh.socket qui tient le port ;
  # lancer ssh.service ici le lui disputerait. Et sans activation par socket,
  # un service arrêté signifie qu'aucun sshd ne tourne : la nouvelle
  # configuration sera lue à son prochain démarrage.
  return 0
}

################################################################################
# FONCTION : Port SSH réellement en écoute
################################################################################
ssh_listen_port() {
  local port="" listen

  if (( SSH_PORT_APPLIED )) && [[ -n "$SSH_PORT" ]]; then
    printf '%s' "$SSH_PORT"
    return 0
  fi
  if ssh_socket_active; then
    listen="$(systemctl show ssh.socket --property=Listen --value 2>/dev/null | head -n1)"
    port="$(printf '%s' "$listen" | sed -n -E 's/.*:([0-9]+).*/\1/p')"
  fi
  [[ -n "$port" ]] || port="$(sshd_effective port 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [[ "$port" =~ ^[0-9]+$ ]] || port="22"
  printf '%s' "$port"
}

################################################################################
# FONCTION : Adresse à afficher dans les exemples de reconnexion
################################################################################
# current_ipv4 renvoie une chaîne vide (et non un code d'erreur) quand aucune
# adresse n'est trouvée : un « || echo <ip> » ne se déclencherait donc jamais.
# On garantit ici qu'un exemple de commande n'est jamais tronqué.
################################################################################
adresse_affichable() {
  local addr="${STATIC_IP_BARE:-}"
  [[ -n "$addr" ]] || addr="$(current_ipv4 "${INTERFACE:-}")"
  [[ -n "$addr" ]] || addr="<ip-du-serveur>"
  printf '%s' "$addr"
}

################################################################################
# FONCTION : Empreinte d'une clé
################################################################################
ssh_fingerprint_file() {
  local file="${1:-}"
  command -v ssh-keygen >/dev/null 2>&1 || return 1
  ssh-keygen -l -f "$file" 2>/dev/null
}

ssh_fingerprint_line() {
  local line="${1:-}" tmp out=""
  command -v ssh-keygen >/dev/null 2>&1 || return 1
  tmp="$(mktemp)" || return 1
  printf '%s\n' "$line" > "$tmp"
  out="$(ssh-keygen -l -f "$tmp" 2>/dev/null)" || out=""
  rm -f "$tmp"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

################################################################################
# FONCTION : Exécution sous l'identité d'un utilisateur
################################################################################
# Le terminal est conservé : ssh-keygen doit pouvoir demander la phrase de
# passe, et ssh-copy-id le mot de passe distant. Générer directement sous le
# bon compte évite en outre toute erreur de propriétaire.
################################################################################
ssh_run_as() {
  local user="${1:-}"
  shift
  [[ -n "$user" && $# -gt 0 ]] || return 1
  if [[ "$user" == "root" ]] || ! command -v runuser >/dev/null 2>&1; then
    "$@"
    return $?
  fi
  runuser -u "$user" -- "$@"
}

################################################################################
# FONCTION : Répertoire personnel présent et attribué
################################################################################
# Un compte système, ou un compte créé avec --no-create-home, n'a pas forcément
# de répertoire personnel : sans lui, aucun ~/.ssh n'est possible.
################################################################################
ensure_home_dir() {
  local user="${1:-}" home="${2:-}" group
  [[ -n "$user" && -n "$home" ]] || return 1
  [[ -d "$home" ]] && return 0
  group="$(ssh_user_group "$user")" || group="$user"

  if ! mkdir -p "$home"; then
    log_err "Création de $home impossible."
    return 1
  fi
  chown "$user:$group" "$home" 2>/dev/null || log_warn "Impossible de donner $home au compte $user."
  chmod 750 "$home" 2>/dev/null || true
  log_ok "Répertoire personnel créé : $home"
  return 0
}

################################################################################
# FONCTION : Répertoire .ssh aux bons droits
################################################################################
ensure_ssh_dir() {
  local user="${1:-}" dir="${2:-}" group
  [[ -n "$user" && -n "$dir" ]] || return 1
  group="$(ssh_user_group "$user")" || group="$user"

  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p "$dir"; then
      log_err "Impossible de créer le répertoire $dir"
      return 1
    fi
    log_ok "Répertoire créé : $dir"
  fi
  chmod 700 "$dir" || log_warn "Impossible d'appliquer les droits 700 sur $dir."
  chown "$user:$group" "$dir" 2>/dev/null || log_warn "Impossible de donner $dir au compte $user."
  return 0
}

################################################################################
# FONCTION : Contrôle des droits exigés par sshd (StrictModes)
################################################################################
# Avec StrictModes (actif par défaut), sshd IGNORE authorized_keys si le
# répertoire personnel ou .ssh est accessible en écriture au groupe ou à tous.
# Aucun message n'apparaît côté client : c'est la première cause de « ma clé ne
# marche pas » alors que tout semble correct.
################################################################################
check_strict_modes() {
  local path perms
  for path in "$@"; do
    [[ -d "$path" ]] || continue
    perms="$(stat -c '%a' "$path" 2>/dev/null)" || continue
    [[ "$perms" =~ ^[0-7]+$ ]] || continue
    if (( 8#$perms & 8#22 )); then
      echo ""
      log_warn "« $path » est accessible en écriture au groupe ou à tous (droits $perms)."
      echo "  Dans ce cas, sshd ignore purement et simplement la clé : la connexion"
      echo "  échouerait sans explication côté client."
      if ask_yes_no "  Corriger maintenant (chmod go-w $path) ?" "o"; then
        if chmod go-w "$path"; then
          log_ok "Droits corrigés : $path est maintenant en $(stat -c '%a' "$path" 2>/dev/null)."
        else
          log_err "Correction impossible sur $path."
        fi
      fi
    fi
  done
  return 0
}

################################################################################
# FONCTION : Outils de retour arrière du durcissement SSH
################################################################################
# Même principe que pour l'IP fixe : couper l'authentification par mot de passe
# alors que la clé n'est pas réellement exploitable verrouille l'utilisateur
# dehors. Deux commandes sont installées :
#
#   ssh-cles-rollback   réactive le mot de passe si rien n'a été confirmé ;
#   ssh-cles-confirmer  valide le durcissement et désarme la minuterie.
#
# L'état est SÉPARÉ de celui du réseau : confirmer l'IP fixe ne doit pas
# désarmer le garde-fou SSH, et réciproquement.
################################################################################
install_ssh_auth_tools() {
  local target="${1:-}"
  [[ -n "$target" ]] || return 1

  mkdir -p "$STATE_DIR" || return 1
  # Un drapeau laissé par une exécution précédente désarmerait immédiatement le
  # garde-fou qui commence.
  rm -f "$SSH_AUTH_CONFIRMED_FLAG"

  cat > "$SSH_AUTH_STATE" <<EOF
# État du durcissement SSH — généré le $(date)
SSHD_TARGET='${target}'
SSHD_TARGET_BACKUP='${target}.bak.${RUN_STAMP}'
SSHD_MAIN_BACKUP='/etc/ssh/sshd_config.bak.${RUN_STAMP}'
CONFIRMED_FLAG='${SSH_AUTH_CONFIRMED_FLAG}'
EOF
  chmod 600 "$SSH_AUTH_STATE"

  cat > /usr/local/sbin/ssh-cles-rollback <<'ROLLBACK'
#!/bin/bash
# Réactive l'authentification par mot de passe tant que le durcissement n'a pas
# été confirmé. Généré par le script de personnalisation Debian 13.
set -u
STATE_FILE="/var/lib/personnalisation-debian13/ssh-auth.env"

journal() { logger -t ssh-cles "$*" 2>/dev/null; echo "$*"; }

[ -r "$STATE_FILE" ] || { journal "État introuvable : $STATE_FILE"; exit 1; }
# shellcheck disable=SC1090
. "$STATE_FILE"

if [ -e "${CONFIRMED_FLAG:-/var/lib/personnalisation-debian13/ssh-auth-confirmed}" ]; then
  journal "Durcissement confirmé : aucun retour arrière."
  exit 0
fi

# Même logique que set_sshd_directive, réécrite ici : cet outil doit rester
# autonome, il survit au script qui l'a installé.
poser_directive() {
  file="$1"; key="$2"; value="$3"
  if [ ! -e "$file" ]; then
    printf '%s %s\n' "$key" "$value" > "$file"
    chmod 644 "$file"
    return 0
  fi
  if grep -qiE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$file"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "$file"
  else
    printf '%s %s\n' "$key" "$value" >> "$file"
  fi
}

journal "Durcissement SSH non confirmé : réactivation de l'authentification par mot de passe."
poser_directive "$SSHD_TARGET" PasswordAuthentication yes
poser_directive "$SSHD_TARGET" KbdInteractiveAuthentication yes

SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if ! "$SSHD_BIN" -t 2>/dev/null; then
  journal "Configuration invalide après réécriture : restauration de la sauvegarde."
  [ -e "${SSHD_TARGET_BACKUP:-}" ] && cp -a "$SSHD_TARGET_BACKUP" "$SSHD_TARGET"
  [ -e "${SSHD_MAIN_BACKUP:-}" ] && cp -a "$SSHD_MAIN_BACKUP" /etc/ssh/sshd_config
fi

if systemctl is-active --quiet ssh.service 2>/dev/null; then
  systemctl reload ssh.service >/dev/null 2>&1 || systemctl restart ssh.service >/dev/null 2>&1
fi

if "$SSHD_BIN" -T 2>/dev/null | grep -qi '^passwordauthentication yes'; then
  journal "Le mot de passe est de nouveau accepté."
else
  journal "ATTENTION : le mot de passe n'a PAS pu être réactivé. Un accès console est nécessaire."
fi
exit 0
ROLLBACK
  chmod 755 /usr/local/sbin/ssh-cles-rollback

  cat > /usr/local/sbin/ssh-cles-confirmer <<'CONFIRM'
#!/bin/bash
# Valide le durcissement SSH et désarme le retour automatique.
# Généré par le script de personnalisation Debian 13.
set -u
STATE_FILE="/var/lib/personnalisation-debian13/ssh-auth.env"
FLAG="/var/lib/personnalisation-debian13/ssh-auth-confirmed"

if [ -r "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  FLAG="${CONFIRMED_FLAG:-$FLAG}"
fi

mkdir -p "$(dirname "$FLAG")"
: > "$FLAG"
systemctl stop ssh-cles-rollback.timer >/dev/null 2>&1
systemctl reset-failed ssh-cles-rollback.timer ssh-cles-rollback.service >/dev/null 2>&1
logger -t ssh-cles "Durcissement SSH confirmé par l'administrateur." 2>/dev/null

echo "✓ Durcissement confirmé : l'authentification par mot de passe reste désactivée."
echo "  Pour la réactiver plus tard : sudo ssh-cles-rollback"
exit 0
CONFIRM
  chmod 755 /usr/local/sbin/ssh-cles-confirmer

  return 0
}

################################################################################
# FONCTION : Explication de l'authentification par clé
################################################################################
afficher_explication_cles() {
  clear
  echo "=========================================="
  echo "  EXPLICATION : L'AUTHENTIFICATION PAR CLÉ"
  echo "=========================================="
  echo ""
  echo "Une paire de clés, ce sont DEUX fichiers indissociables :"
  echo ""
  echo "  - la clé PRIVÉE (ex. id_ed25519) reste sur VOTRE machine. Elle ne"
  echo "    doit JAMAIS être copiée sur un serveur ni envoyée par courriel."
  echo "  - la clé PUBLIQUE (ex. id_ed25519.pub) se dépose sur les serveurs,"
  echo "    dans le fichier ~/.ssh/authorized_keys du compte visé. Elle peut"
  echo "    être diffusée sans risque."
  echo ""
  echo "À la connexion, le serveur envoie un défi que seule la clé privée sait"
  echo "résoudre. Le secret ne circule donc jamais sur le réseau."
  echo ""
  echo "POURQUOI C'EST NETTEMENT PLUS SÛR QU'UN MOT DE PASSE :"
  echo "  - un mot de passe se devine, se rejoue, se tape sur un faux serveur ;"
  echo "  - une clé de 256 bits ne se force pas par essais successifs ;"
  echo "  - les robots qui scannent le port SSH testent des mots de passe :"
  echo "    sans mot de passe accepté, leurs tentatives deviennent inutiles ;"
  echo "  - la connexion devient automatisable (sauvegardes, scripts) sans"
  echo "    écrire de mot de passe en clair quelque part."
  echo ""
  echo "LA PHRASE DE PASSE :"
  echo "  Elle chiffre la clé privée SUR LE DISQUE. Si le fichier est volé, il"
  echo "  reste inutilisable. C'est la protection du dernier recours, et elle"
  echo "  ne se tape qu'une fois par session grâce à l'agent SSH."
  echo ""
  echo "QUI FAIT QUOI :"
  echo "  - machine CLIENTE (votre poste)  → on y GÉNÈRE la paire de clés ;"
  echo "  - SERVEUR (cette machine ?)      → on y DÉPOSE la clé publique."
  echo ""
  echo "=========================================="
  echo ""
}

################################################################################
# FONCTION : Aide « je n'ai pas encore de clé »
################################################################################
# Affichée côté serveur : les commandes à lancer sur le POSTE CLIENT pour
# obtenir une clé publique à coller ensuite ici.
################################################################################
afficher_aide_creation_cliente() {
  local port user
  port="$(ssh_listen_port)"
  user="${STANDARD_USER:-utilisateur}"

  echo ""
  echo "------------------------------------------------------------------"
  echo "  À FAIRE SUR VOTRE POSTE (pas sur ce serveur)"
  echo "------------------------------------------------------------------"
  echo ""
  echo "  Linux ou macOS — dans un terminal :"
  echo ""
  echo "      ssh-keygen -t ed25519 -C \"\$USER@\$(hostname)\""
  echo "      cat ~/.ssh/id_ed25519.pub"
  echo ""
  echo "  Windows 10/11 — dans PowerShell :"
  echo ""
  echo "      ssh-keygen -t ed25519"
  echo "      type \$env:USERPROFILE\\.ssh\\id_ed25519.pub"
  echo ""
  echo "  Copiez la ligne affichée (elle commence par « ssh-ed25519 ») puis"
  echo "  revenez ici et choisissez « la coller »."
  echo ""
  echo "  Variante entièrement automatique, depuis votre poste, une fois le"
  echo "  mot de passe encore actif :"
  echo ""
  echo "      ssh-copy-id -p $port $user@$(adresse_affichable)"
  echo ""
  echo "------------------------------------------------------------------"
  echo ""
}

################################################################################
# FONCTION : Test RÉEL d'une connexion par clé
################################################################################
# C'est la seule preuve acceptable avant de couper le mot de passe. En cas de
# succès, KEY_LOGIN_TESTED passe à 1 et débloque le durcissement.
################################################################################
tester_connexion_cle() {
  local owner="${1:-}" key="${2:-}" remote_user="${3:-}" host="${4:-}" port="${5:-22}"
  local out rc=0
  local -a opts

  [[ -n "$owner" && -n "$key" && -n "$remote_user" && -n "$host" ]] || return 1
  if ! command -v ssh >/dev/null 2>&1; then
    log_warn "La commande « ssh » est indisponible : test impossible."
    return 1
  fi

  opts=(-i "$key" -p "$port"
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
        -o IdentitiesOnly=yes
        -o PreferredAuthentications=publickey)

  if (( KEY_HAS_PASSPHRASE )); then
    echo ""
    log_info "La clé est protégée par une phrase de passe : elle va vous être demandée."
  else
    # Sans phrase de passe, rien ne doit être demandé : BatchMode transforme
    # toute invite en échec franc plutôt qu'en attente silencieuse.
    opts+=(-o BatchMode=yes)
  fi

  log_info "Test de connexion : $remote_user@$host (port $port)..."
  out="$(ssh_run_as "$owner" ssh "${opts[@]}" "$remote_user@$host" true 2>&1)" || rc=$?

  if (( rc == 0 )); then
    log_ok "CONNEXION PAR CLÉ RÉUSSIE vers $remote_user@$host."
    KEY_LOGIN_TESTED=1
    return 0
  fi

  log_err "La connexion par clé a échoué (code $rc)."
  [[ -n "$out" ]] && printf '%s\n' "$out" | sed -e 's/^/    /' >&2
  echo "  Pistes à vérifier :"
  echo "    - clé publique absente du authorized_keys du compte visé ;"
  echo "    - droits trop larges sur le répertoire personnel ou sur .ssh ;"
  echo "    - port, pare-feu, ou compte sans shell de connexion ;"
  echo "    - compte verrouillé (« passwd -S $remote_user » affiche « L ») :"
  echo "      un compte sans mot de passe défini peut être refusé avant même"
  echo "      l'examen de la clé."
  return 1
}

################################################################################
# FONCTION : Entrée de raccourci dans ~/.ssh/config
################################################################################
# Permet de se connecter par « ssh monserveur » sans réécrire le port, le
# compte ni le chemin de la clé. Le bloc est encadré par des marqueurs : une
# nouvelle exécution le remplace au lieu de l'empiler.
################################################################################
configurer_ssh_config() {
  local user="${1:-}" home="${2:-}" key="${3:-}"
  local cfg alias_name host remote_user port group

  cfg="$home/.ssh/config"
  echo ""
  echo "Un alias évite de retaper le port, le compte et le chemin de la clé :"
  echo "  ssh monserveur   au lieu de   ssh -i $key -p 2222 admin@192.168.1.10"
  echo ""

  ask_input "Alias de connexion" "monserveur" v_ssh_alias
  alias_name="$ASK_VALUE"
  ask_input "Nom d'hôte ou adresse IP du serveur" "${STATIC_IP_BARE:-}" v_ssh_host
  host="$ASK_VALUE"
  ask_input "Compte à utiliser sur le serveur" "$user" v_user_name
  remote_user="$ASK_VALUE"
  ask_input "Port SSH du serveur" "$(ssh_listen_port)" v_port
  port="$ASK_VALUE"

  ensure_ssh_dir "$user" "$home/.ssh" || return 1
  [[ -e "$cfg" ]] && backup_file_once "$cfg"

  write_marked_block "$cfg" \
    "# >>> personnalisation-debian13 (alias $alias_name) >>>" \
    "# <<< personnalisation-debian13 (alias $alias_name) <<<" <<EOF
Host $alias_name
    HostName $host
    User $remote_user
    Port $port
    IdentityFile $key
    # N'essaie QUE cette clé : sans cela, ssh présente toutes les identités
    # connues et peut dépasser MaxAuthTries avant d'arriver à la bonne.
    IdentitiesOnly yes
    # Charge la clé dans l'agent au premier usage : la phrase de passe n'est
    # alors demandée qu'une fois par session.
    AddKeysToAgent yes
EOF

  group="$(ssh_user_group "$user")" || group="$user"
  chmod 600 "$cfg" 2>/dev/null || true
  chown "$user:$group" "$cfg" 2>/dev/null || true

  echo ""
  if command -v ssh >/dev/null 2>&1 && ssh_run_as "$user" ssh -G "$alias_name" >/dev/null 2>&1; then
    log_ok "Alias « $alias_name » écrit dans $cfg et relu sans erreur par ssh."
  else
    log_ok "Alias « $alias_name » écrit dans $cfg."
  fi
  echo "  Connexion : ssh $alias_name"
  return 0
}

################################################################################
# FONCTION : Envoi de la clé publique vers un serveur distant
################################################################################
deployer_cle_distante() {
  local user="${1:-}" pub="${2:-}" key="${3:-}"
  local host remote_user port rc=0

  if ! need_cmd ssh-copy-id openssh-client; then
    log_warn "« ssh-copy-id » est indisponible : envoi automatique impossible."
    echo "  Méthode manuelle, depuis cette machine :"
    echo "    cat $pub | ssh <user>@<serveur> 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys'"
    return 1
  fi

  echo ""
  ask_input "Adresse ou nom du serveur distant" "" v_ssh_host
  host="$ASK_VALUE"
  ask_input "Compte sur ce serveur" "$user" v_user_name
  remote_user="$ASK_VALUE"
  ask_input "Port SSH du serveur" "22" v_port
  port="$ASK_VALUE"

  echo ""
  log_info "Envoi de la clé publique vers $remote_user@$host (port $port)..."
  echo "  Le MOT DE PASSE du compte distant va vous être demandé : c'est"
  echo "  normal, c'est la dernière fois."
  echo ""

  ssh_run_as "$user" ssh-copy-id \
    -i "$pub" -p "$port" \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    "$remote_user@$host" || rc=$?

  echo ""
  if (( rc != 0 )); then
    log_err "L'envoi a échoué (code $rc)."
    echo "  Vérifiez l'adresse, le port, le compte, et que le serveur distant"
    echo "  accepte encore l'authentification par mot de passe."
    return 1
  fi

  log_ok "Clé publique déposée sur $remote_user@$host."
  echo ""
  if ask_yes_no "Tester tout de suite la connexion par clé ?" "o"; then
    tester_connexion_cle "$user" "$key" "$remote_user" "$host" "$port" || return 1
  fi
  return 0
}

################################################################################
# FONCTION : Génération d'une paire de clés (machine CLIENTE)
################################################################################
generer_paire_cles() {
  local user home group dir name comment type bits nom_defaut
  local key_path pub_path choix with_pass=1 rc=0 tentative=1
  local -a cmd

  banner "GÉNÉRATION D'UNE PAIRE DE CLÉS SSH"

  if ! need_cmd ssh-keygen openssh-client; then
    log_err "« ssh-keygen » est introuvable et le paquet openssh-client n'a pas pu être installé."
    echo "  Aucune clé ne peut être générée sur cette machine."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    return 1
  fi

  # --- Compte propriétaire ------------------------------------------------------
  local defaut_user="root"
  if (( USER_CREATED )) && [[ -n "$STANDARD_USER" ]]; then
    defaut_user="$STANDARD_USER"
  fi

  echo "La clé appartiendra à un compte précis : elle sera créée dans SON"
  echo "répertoire personnel, avec ses droits."
  echo "  Comptes disponibles : $(ssh_login_users | tr '\n' ' ')"
  echo ""
  ask_input "Compte propriétaire de la clé" "$defaut_user" v_ssh_user
  user="$ASK_VALUE"

  if ! home="$(ssh_user_home "$user")"; then
    log_err "Impossible de déterminer le répertoire personnel de « $user »."
    return 1
  fi
  group="$(ssh_user_group "$user")" || group="$user"

  if [[ ! -d "$home" ]]; then
    log_warn "Le répertoire personnel « $home » n'existe pas encore."
    ask_yes_no "Le créer ?" "o" || return 1
    ensure_home_dir "$user" "$home" || return 1
  fi

  # --- Type de clé --------------------------------------------------------------
  echo ""
  echo "TYPE DE CLÉ :"
  echo "  1. ed25519     Recommandé. Court, rapide, très sûr, standard depuis"
  echo "                 des années sur tous les systèmes à jour."
  echo "  2. rsa 4096    Pour dialoguer avec de vieux équipements (NAS, switchs,"
  echo "                 serveurs antérieurs à 2014) qui ignorent ed25519."
  echo "  3. ecdsa 521   Rarement utile ; parfois imposé par une norme interne."
  echo "  4. ed25519-sk  Clé matérielle FIDO2 (YubiKey…) : le secret ne quitte"
  echo "                 jamais le jeton, qui doit être branché MAINTENANT."
  echo ""
  if ! read -r -p "Votre choix (1/2/3/4) [1] : " choix; then
    choix="1"
    echo ""
  fi
  case "${choix:-1}" in
    2) type="rsa";        bits="4096"; nom_defaut="id_rsa" ;;
    3) type="ecdsa";      bits="521";  nom_defaut="id_ecdsa" ;;
    4) type="ed25519-sk"; bits="";     nom_defaut="id_ed25519_sk" ;;
    *) type="ed25519";    bits="";     nom_defaut="id_ed25519" ;;
  esac

  # --- Emplacement et nom -------------------------------------------------------
  echo ""
  echo "Par convention les clés vivent dans ~/.ssh, mais tout emplacement"
  echo "accessible au compte convient (un support chiffré, par exemple)."
  echo ""
  ask_input "Emplacement (répertoire) de la clé" "$home/.ssh" v_abs_dir
  dir="$ASK_VALUE"
  ask_input "Nom du fichier de la clé" "$nom_defaut" v_key_name
  name="$ASK_VALUE"
  key_path="$dir/$name"
  pub_path="$key_path.pub"

  # --- Jamais d'écrasement silencieux -------------------------------------------
  while [[ -e "$key_path" || -e "$pub_path" ]]; do
    echo ""
    log_warn "Un fichier porte déjà ce nom : $key_path"
    echo "  Écraser une clé privée existante rend DÉFINITIVEMENT inutilisables"
    echo "  tous les accès qui reposent dessus."
    echo ""
    echo "  1. Choisir un autre nom (recommandé)"
    echo "  2. Sauvegarder l'existant, puis écraser"
    echo "  3. Annuler la génération"
    echo ""
    if ! read -r -p "Votre choix (1/2/3) [1] : " choix; then
      choix="3"
      echo ""
    fi
    case "${choix:-1}" in
      2)
        backup_file "$key_path"
        backup_file "$pub_path"
        rm -f "$key_path" "$pub_path"
        ;;
      3)
        log_info "Génération annulée."
        return 1
        ;;
      *)
        ask_input "Nouveau nom du fichier de la clé" "${name}-2" v_key_name
        name="$ASK_VALUE"
        key_path="$dir/$name"
        pub_path="$key_path.pub"
        ;;
    esac
  done

  # --- Commentaire --------------------------------------------------------------
  echo ""
  echo "Le commentaire est inscrit en clair dans la clé : il sert à reconnaître"
  echo "sa provenance des mois plus tard, dans un authorized_keys qui en compte"
  echo "plusieurs."
  echo ""
  ask_input "Commentaire" "$user@$(hostname)-$(date +%Y%m%d)" "" yes
  comment="$ASK_VALUE"

  ensure_ssh_dir "$user" "$dir" || return 1

  # --- Phrase de passe ----------------------------------------------------------
  echo ""
  echo "PHRASE DE PASSE :"
  echo "  Elle chiffre la clé privée sur le disque. Sans elle, quiconque met la"
  echo "  main sur le fichier obtient immédiatement vos accès (sauvegarde"
  echo "  égarée, disque revendu, compte compromis)."
  echo "  Une clé SANS phrase ne se justifie que pour l'automatisation."
  echo ""
  ask_yes_no "Protéger la clé par une phrase de passe ?" "o" || with_pass=0

  # --- Génération ---------------------------------------------------------------
  while true; do
    cmd=(ssh-keygen -t "$type" -f "$key_path" -C "$comment")
    [[ -n "$bits" ]] && cmd+=(-b "$bits")

    if (( with_pass )); then
      echo ""
      echo "ssh-keygen va demander la phrase DEUX FOIS, en anglais :"
      echo "    « Enter passphrase »            → saisissez votre phrase"
      echo "    « Enter same passphrase again » → saisissez-la à nouveau"
      echo "  Rien ne s'affiche pendant la frappe, c'est normal."
      echo ""
      # La phrase n'est JAMAIS passée par l'option -N : la ligne de commande
      # d'un processus est lisible de tous (« ps », /proc). C'est ssh-keygen
      # lui-même qui la demande, directement sur le terminal.
    else
      cmd+=(-N "")
    fi

    rc=0
    ssh_run_as "$user" "${cmd[@]}" || rc=$?
    if (( rc == 0 )) && [[ -f "$key_path" && -f "$pub_path" ]]; then
      break
    fi

    echo ""
    log_err "La génération a échoué (code $rc)."

    # Repli 1 : la bascule d'identité peut être en cause (runuser absent d'un
    # conteneur, PAM restrictif). On retente en root, quitte à corriger le
    # propriétaire juste après.
    if (( tentative == 1 )) && [[ "$user" != "root" ]] && [[ ! -e "$key_path" ]]; then
      tentative=2
      log_info "Nouvelle tentative en root ; les fichiers seront ensuite donnés à $user."
      rc=0
      "${cmd[@]}" || rc=$?
      if (( rc == 0 )) && [[ -f "$key_path" && -f "$pub_path" ]]; then
        break
      fi
      log_err "La seconde tentative a également échoué (code $rc)."
    fi

    # Repli 2 : une clé « -sk » exige un jeton FIDO2 branché et libfido2.
    if [[ "$type" == *-sk ]]; then
      echo "  Les clés « -sk » nécessitent un jeton FIDO2 branché, le paquet"
      echo "  libfido2-1, et un jeton qui accepte l'algorithme demandé."
      echo ""
      if ask_yes_no "Générer plutôt une clé ed25519 logicielle ?" "o"; then
        type="ed25519"
        bits=""
        tentative=1
        rm -f "$key_path" "$pub_path"
        continue
      fi
    fi

    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    return 1
  done

  # --- Droits et propriétaire ---------------------------------------------------
  chown "$user:$group" "$key_path" "$pub_path" 2>/dev/null ||
    log_warn "Impossible de donner les fichiers de clé au compte $user."
  chmod 600 "$key_path" 2>/dev/null || true
  chmod 644 "$pub_path" 2>/dev/null || true

  # --- Vérification RÉELLE ------------------------------------------------------
  local perms proprio anomalie=0
  perms="$(stat -c '%a' "$key_path" 2>/dev/null)"
  proprio="$(stat -c '%U' "$key_path" 2>/dev/null)"
  [[ "$perms" == "600" ]] || anomalie=1
  [[ "$proprio" == "$user" ]] || anomalie=1

  echo ""
  if (( anomalie )); then
    log_warn "Clé créée, mais ses attributs sont inattendus (droits $perms, propriétaire $proprio)."
    echo "  Attendu : droits 600, propriétaire $user. ssh refuse d'utiliser une"
    echo "  clé privée lisible par d'autres comptes."
  else
    log_ok "PAIRE DE CLÉS CRÉÉE"
  fi

  echo ""
  echo "  Clé PRIVÉE   : $key_path"
  echo "                 (droits $perms — à ne JAMAIS copier ailleurs)"
  echo "  Clé PUBLIQUE : $pub_path"
  echo "                 (à déposer sur les serveurs)"
  local empreinte
  if empreinte="$(ssh_fingerprint_file "$pub_path")"; then
    echo "  Empreinte    : $empreinte"
  fi
  echo ""
  echo "  Contenu de la clé PUBLIQUE, à copier telle quelle :"
  echo "  ------------------------------------------------------------------"
  sed -e 's/^/  /' "$pub_path"
  echo "  ------------------------------------------------------------------"
  echo ""

  KEY_GENERATED=1
  KEY_PATH="$key_path"
  KEY_PUB_PATH="$pub_path"
  KEY_OWNER="$user"
  KEY_HAS_PASSPHRASE="$with_pass"

  if (( with_pass )); then
    echo "  Astuce : « ssh-add $key_path » charge la clé dans l'agent, la phrase"
    echo "  de passe n'est alors demandée qu'une fois par session."
    echo ""
  fi

  # --- Options complémentaires --------------------------------------------------
  if ask_yes_no "Créer un raccourci de connexion dans ~/.ssh/config ?" "o"; then
    configurer_ssh_config "$user" "$home" "$key_path" || true
  fi

  echo ""
  if ask_yes_no "Envoyer dès maintenant cette clé publique vers un serveur distant ?" "n"; then
    deployer_cle_distante "$user" "$pub_path" "$key_path" || true
  fi

  return 0
}

################################################################################
# FONCTION : Collecte des clés publiques à installer (côté SERVEUR)
################################################################################
# Les clés retenues sont accumulées dans PUBKEYS_COLLECTED : un tableau ne peut
# pas être renvoyé par une fonction en bash.
################################################################################
PUBKEYS_COLLECTED=()

ajouter_cle_collectee() {
  local line="${1:-}" silencieux="${2:-non}"

  # Un copier-coller depuis Windows traîne des retours chariot, invisibles mais
  # qui rendent la clé inutilisable.
  line="${line//$'\r'/}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"

  [[ -n "$line" ]] || return 1
  [[ "$line" == \#* ]] && return 1

  if ! is_ssh_pubkey "$line"; then
    [[ "$silencieux" == "oui" ]] || log_warn "Ligne ignorée (clé publique non reconnue) : ${line:0:48}..."
    return 1
  fi

  local existante
  if (( ${#PUBKEYS_COLLECTED[@]} > 0 )); then
    for existante in "${PUBKEYS_COLLECTED[@]}"; do
      [[ "$(ssh_pubkey_body "$existante")" == "$(ssh_pubkey_body "$line")" ]] && return 1
    done
  fi

  PUBKEYS_COLLECTED+=("$line")
  return 0
}

################################################################################
# FONCTION : Récupération de clés depuis un fichier ou une URL
################################################################################
importer_cles_fichier() {
  local fichier="${1:-}" ajoutees=0 ligne

  if [[ ! -r "$fichier" ]]; then
    log_err "Fichier illisible ou inexistant : $fichier"
    return 1
  fi
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    ajouter_cle_collectee "$ligne" "oui" && ajoutees=$((ajoutees + 1))
  done < "$fichier"

  if (( ajoutees == 0 )); then
    log_err "Aucune clé publique exploitable dans $fichier."
    return 1
  fi
  log_ok "$ajoutees clé(s) retenue(s) depuis $fichier."
  return 0
}

telecharger_cles() {
  local url="${1:-}" tmp rc=0

  if [[ "$url" != https://* ]]; then
    log_err "Seules les URL « https:// » sont acceptées (une clé récupérée en clair peut être remplacée en route)."
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    need_cmd curl curl >/dev/null 2>&1 || true
  fi

  tmp="$(mktemp)" || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --max-time 20 -o "$tmp" -- "$url" || rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=20 -O "$tmp" -- "$url" || rc=$?
  else
    log_err "Ni curl ni wget ne sont disponibles : téléchargement impossible."
    rm -f "$tmp"
    return 1
  fi

  if (( rc != 0 )); then
    log_err "Téléchargement impossible depuis $url (code $rc)."
    rm -f "$tmp"
    return 1
  fi

  importer_cles_fichier "$tmp"
  rc=$?
  rm -f "$tmp"
  return $rc
}

################################################################################
# FONCTION : Dépôt d'une clé publique dans authorized_keys (côté SERVEUR)
################################################################################
installer_cle_publique() {
  local user home group ssh_dir authfile choix shell_user
  local ajoutees=0 ignorees=0 cle url login fichier

  banner "DÉPÔT D'UNE CLÉ PUBLIQUE SUR CE SERVEUR"

  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    log_warn "Le serveur SSH (openssh-server) n'est pas installé sur cette machine."
    echo "  La clé peut tout de même être déposée : elle sera prise en compte"
    echo "  dès l'installation du serveur."
    echo ""
  fi

  # --- Compte destinataire ------------------------------------------------------
  local defaut_user="root"
  if (( USER_CREATED )) && [[ -n "$STANDARD_USER" ]]; then
    defaut_user="$STANDARD_USER"
  fi

  echo "La clé publique autorise la connexion à UN compte précis de ce serveur."
  echo "  Comptes disponibles : $(ssh_login_users | tr '\n' ' ')"
  echo ""
  ask_input "Compte autorisé par cette clé" "$defaut_user" v_ssh_user
  user="$ASK_VALUE"

  if ! home="$(ssh_user_home "$user")"; then
    log_err "Impossible de déterminer le répertoire personnel de « $user »."
    return 1
  fi
  group="$(ssh_user_group "$user")" || group="$user"

  shell_user="$(ssh_user_shell "$user")"
  if [[ "$shell_user" == *nologin || "$shell_user" == */false ]]; then
    echo ""
    log_warn "Le compte « $user » a pour shell « $shell_user » : il ne peut pas ouvrir de session."
    echo "  La clé sera installée, mais la connexion SSH restera refusée."
    ask_yes_no "Continuer quand même ?" "n" || return 1
  fi

  if [[ "$user" == "root" ]]; then
    local root_login
    root_login="$(sshd_effective permitrootlogin)"
    if [[ "$root_login" == "no" ]]; then
      echo ""
      log_warn "La connexion SSH de root est actuellement DÉSACTIVÉE (PermitRootLogin no)."
      echo "  La clé serait installée mais inutilisable en l'état."
      echo ""
      if ask_yes_no "Autoriser root UNIQUEMENT par clé (PermitRootLogin prohibit-password) ?" "n"; then
        local cible
        cible="$(sshd_target_file)"
        backup_file_once /etc/ssh/sshd_config
        [[ "$cible" != "/etc/ssh/sshd_config" ]] && backup_file_once "$cible"
        set_sshd_directive "$cible" "PermitRootLogin" "prohibit-password"
        if ssh_reload_config; then
          log_ok "root pourra se connecter par clé, jamais par mot de passe."
        else
          log_err "Configuration refusée par sshd : modification à vérifier manuellement."
          SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
        fi
      fi
    fi
  fi

  if [[ ! -d "$home" ]]; then
    log_warn "Le répertoire personnel « $home » n'existe pas."
    ask_yes_no "Le créer ?" "o" || return 1
    ensure_home_dir "$user" "$home" || return 1
  fi

  # --- Collecte des clés --------------------------------------------------------
  PUBKEYS_COLLECTED=()

  while true; do
    echo ""
    echo "------------------------------------------"
    echo "  PROVENANCE DE LA CLÉ PUBLIQUE"
    echo "------------------------------------------"
    echo "  1. La coller ici (une ligne, commençant par « ssh-ed25519 »…)"
    echo "  2. La lire dans un fichier présent sur ce serveur"
    echo "  3. La télécharger depuis une URL https"
    echo "  4. L'importer depuis un compte GitHub"
    if (( KEY_GENERATED )); then
      echo "  5. Utiliser la clé générée à l'instant ($KEY_PUB_PATH)"
    fi
    echo "  6. Je n'ai pas encore de clé — m'expliquer comment en créer une"
    echo "  0. Terminer la saisie (${#PUBKEYS_COLLECTED[@]} clé(s) retenue(s))"
    echo ""
    if ! read -r -p "Votre choix : " choix; then
      choix="0"
      echo ""
    fi

    case "$choix" in
      1)
        echo ""
        echo "Collez la clé PUBLIQUE (une seule ligne), puis Entrée :"
        ask_input "Clé publique" "" v_pubkey
        if ajouter_cle_collectee "$ASK_VALUE"; then
          log_ok "Clé retenue : $(ssh_fingerprint_line "$ASK_VALUE" || ssh_pubkey_type "$ASK_VALUE")"
        else
          log_info "Cette clé est déjà dans la liste."
        fi
        ;;
      2)
        echo ""
        ask_input "Chemin du fichier contenant la ou les clés" "" ""
        fichier="$ASK_VALUE"
        importer_cles_fichier "$fichier" || true
        ;;
      3)
        echo ""
        ask_input "URL https de la clé publique" "" ""
        url="$ASK_VALUE"
        telecharger_cles "$url" || true
        ;;
      4)
        echo ""
        echo "GitHub publie les clés publiques d'un compte sur https://github.com/<login>.keys"
        echo "⚠ N'importez que VOTRE compte : ces clés donneront un accès complet."
        echo ""
        ask_input "Identifiant GitHub" "" v_ssh_alias
        login="$ASK_VALUE"
        telecharger_cles "https://github.com/${login}.keys" || true
        ;;
      5)
        if (( KEY_GENERATED )); then
          importer_cles_fichier "$KEY_PUB_PATH" || true
        else
          log_warn "Aucune clé n'a été générée pendant cette exécution."
        fi
        ;;
      6)
        afficher_aide_creation_cliente
        read -r -p "Appuyez sur Entrée pour revenir au menu..." _ || true
        ;;
      0)
        break
        ;;
      *)
        log_warn "Choix invalide."
        ;;
    esac
  done

  if (( ${#PUBKEYS_COLLECTED[@]} == 0 )); then
    echo ""
    log_info "Aucune clé publique n'a été fournie : rien n'est installé."
    return 1
  fi

  # --- Récapitulatif et confirmation --------------------------------------------
  echo ""
  echo "------------------------------------------"
  echo "  CLÉS À INSTALLER POUR « $user »"
  echo "------------------------------------------"
  for cle in "${PUBKEYS_COLLECTED[@]}"; do
    echo "  - $(ssh_fingerprint_line "$cle" || printf '%s' "$(ssh_pubkey_type "$cle") ${cle:0:40}...")"
  done
  echo "------------------------------------------"
  echo ""
  echo "Chacune de ces clés donnera un accès complet au compte « $user »."
  echo ""
  if ! ask_yes_no "Installer ces clés dans $home/.ssh/authorized_keys ?" "o"; then
    log_info "Installation annulée."
    return 1
  fi

  # --- Installation -------------------------------------------------------------
  ssh_dir="$home/.ssh"
  ensure_ssh_dir "$user" "$ssh_dir" || return 1
  authfile="$ssh_dir/authorized_keys"

  if [[ -e "$authfile" ]]; then
    backup_file_once "$authfile"
  else
    : > "$authfile"
  fi
  ensure_trailing_newline "$authfile"

  for cle in "${PUBKEYS_COLLECTED[@]}"; do
    if authkeys_contains "$authfile" "$cle"; then
      ignorees=$((ignorees + 1))
      continue
    fi
    if printf '%s\n' "$cle" >> "$authfile"; then
      ajoutees=$((ajoutees + 1))
    else
      log_err "Écriture impossible dans $authfile"
      SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
      return 1
    fi
  done

  chmod 600 "$authfile" 2>/dev/null || log_warn "Impossible d'appliquer les droits 600 sur $authfile."
  chown "$user:$group" "$authfile" 2>/dev/null || log_warn "Impossible de donner $authfile au compte $user."

  echo ""
  log_ok "$ajoutees clé(s) ajoutée(s), $ignorees déjà présente(s)."
  echo "  Fichier : $authfile ($(stat -c '%a %U:%G' "$authfile" 2>/dev/null))"

  if (( ajoutees > 0 )); then
    AUTHKEY_ADDED=1
    AUTHKEY_USER="$user"
    AUTHKEY_COUNT=$((AUTHKEY_COUNT + ajoutees))
  elif (( ignorees > 0 )) && ! (( AUTHKEY_ADDED )); then
    # Les clés étaient déjà là : l'accès par clé est en place malgré tout.
    AUTHKEY_ADDED=1
    AUTHKEY_USER="$user"
  fi

  # --- Contrôles de bon fonctionnement ------------------------------------------
  echo ""
  log_info "Vérification des conditions exigées par sshd..."

  local empreintes
  if empreintes="$(ssh_fingerprint_file "$authfile")"; then
    echo "  Clés effectivement lisibles par sshd :"
    printf '%s\n' "$empreintes" | sed -e 's/^/    /'
  else
    log_warn "ssh-keygen ne parvient pas à relire $authfile : vérifiez son contenu."
  fi

  # « chmod go-w » suffit à satisfaire StrictModes, mais un .ssh reste un
  # répertoire privé : on le remet à 700 quoi qu'il arrive.
  check_strict_modes "$home" "$ssh_dir"
  chmod 700 "$ssh_dir" 2>/dev/null || true

  local akf
  akf="$(sshd_effective authorizedkeysfile)"
  if [[ -n "$akf" && "$akf" != *".ssh/authorized_keys"* ]]; then
    log_warn "sshd ne lit PAS le fichier standard : AuthorizedKeysFile = $akf"
    echo "  La clé vient d'être écrite dans $authfile, qui ne sera pas consulté."
    echo "  Adaptez la directive ou déplacez le fichier avant de fermer cette session."
  fi

  # --- Preuve par le test --------------------------------------------------------
  if (( KEY_GENERATED )) && [[ -f "$KEY_PATH" ]]; then
    echo ""
    echo "Un test en boucle locale (127.0.0.1) permet de PROUVER que la"
    echo "connexion par clé fonctionne, sans quitter cette session."
    echo ""
    if ask_yes_no "Tester la connexion par clé maintenant ?" "o"; then
      tester_connexion_cle "$KEY_OWNER" "$KEY_PATH" "$user" "127.0.0.1" "$(ssh_listen_port)" || true
    fi
  fi

  return 0
}

################################################################################
# FONCTION : Durcissement de l'authentification SSH
################################################################################
# Active explicitement l'authentification par clé, puis propose de couper le
# mot de passe — l'opération la plus risquée de cette étape, protégée par un
# retour arrière automatique armé AVANT la modification.
################################################################################
durcir_authentification() {
  local cible bin valeur delai choix rc=0

  (( AUTHKEY_ADDED )) || return 0
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    return 0
  fi

  cible="$(sshd_target_file)"
  bin="$(command -v sshd || echo /usr/sbin/sshd)"

  backup_file_once /etc/ssh/sshd_config
  [[ "$cible" != "/etc/ssh/sshd_config" ]] && backup_file_once "$cible"

  # --- Authentification par clé : explicite, et sans risque ---------------------
  set_sshd_directive "$cible" "PubkeyAuthentication" "yes"
  if ! "$bin" -t 2>/dev/null; then
    log_err "La configuration SSH devient invalide : restauration."
    restore_file "$cible" "${cible}.bak.${RUN_STAMP}" || rm -f "$cible"
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    return 1
  fi
  ssh_reload_config || log_warn "Rechargement de sshd impossible."

  valeur="$(sshd_effective pubkeyauthentication)"
  if [[ "$valeur" == "yes" ]]; then
    log_ok "Authentification par clé active (PubkeyAuthentication yes)."
  else
    log_warn "PubkeyAuthentication vaut « ${valeur:-inconnu} » après modification."
  fi

  # --- Coupure du mot de passe ---------------------------------------------------
  echo ""
  echo "------------------------------------------"
  echo "  DÉSACTIVER L'AUTHENTIFICATION PAR MOT DE PASSE ?"
  echo "------------------------------------------"
  echo ""
  echo "C'est le vrai gain de sécurité : tant que le mot de passe est accepté,"
  echo "les robots continuent d'essayer, et un mot de passe faible reste une"
  echo "porte ouverte malgré la clé."
  echo ""
  echo "C'est aussi l'opération la plus risquée de ce script : si la clé n'est"
  echo "pas réellement exploitable, PLUS PERSONNE ne peut se connecter."
  echo ""

  if (( KEY_LOGIN_TESTED )); then
    log_ok "Une connexion par clé a été testée avec succès pendant cette exécution."
  else
    log_warn "Aucune connexion par clé n'a pu être prouvée pendant cette exécution."
    echo "  Sans preuve, cette désactivation est un pari."
    echo ""
    if ! ask_yes_no "Avez-vous DÉJÀ testé la connexion par clé depuis une autre session ?" "n"; then
      echo ""
      log_info "Mot de passe conservé. Testez « ssh -i <clé> $AUTHKEY_USER@<ip> » depuis"
      echo "  votre poste, puis relancez ce script pour finir le durcissement."
      return 0
    fi
  fi

  echo ""
  if ! ask_yes_no "Désactiver l'authentification par mot de passe ?" "n"; then
    log_info "Authentification par mot de passe conservée."
    return 0
  fi

  # --- Filet de sécurité armé AVANT la modification ------------------------------
  echo ""
  echo "Un retour automatique va être armé : sans confirmation de votre part,"
  echo "le mot de passe sera réactivé tout seul."
  echo ""
  echo "  1. 5 minutes"
  echo "  2. 10 minutes (recommandé)"
  echo "  3. 15 minutes"
  echo "  4. Aucun filet (déconseillé)"
  echo ""
  if ! read -r -p "Votre choix (1/2/3/4) [2] : " choix; then
    choix="2"
    echo ""
  fi
  case "${choix:-2}" in
    1) delai=5 ;;
    3) delai=15 ;;
    4) delai=0 ;;
    *) delai=10 ;;
  esac
  SSH_AUTH_ROLLBACK_DELAY="$delai"

  if (( delai > 0 )); then
    install_ssh_auth_tools "$cible" || log_warn "Installation des outils de retour arrière incomplète."
    systemctl stop ssh-cles-rollback.timer >/dev/null 2>&1 || true
    systemctl reset-failed ssh-cles-rollback.timer ssh-cles-rollback.service >/dev/null 2>&1 || true

    if systemd-run --unit=ssh-cles-rollback \
         --description="Réactivation du mot de passe SSH si le durcissement n'est pas confirmé" \
         --on-active="${delai}min" \
         /usr/local/sbin/ssh-cles-rollback >/dev/null 2>&1; then
      SSH_AUTH_ROLLBACK_ARMED=1
      log_ok "Retour automatique armé : mot de passe réactivé dans $delai minutes sans confirmation."
    else
      log_warn "Impossible d'armer le retour automatique."
      echo ""
      if ! ask_yes_no "Désactiver le mot de passe SANS filet de sécurité ?" "n"; then
        log_info "Authentification par mot de passe conservée."
        return 0
      fi
    fi
  else
    log_warn "Aucun filet de sécurité : gardez impérativement cette session ouverte."
  fi

  # --- Modification ---------------------------------------------------------------
  set_sshd_directive "$cible" "PasswordAuthentication" "no"
  # Sans cette seconde directive, Debian accepte encore le mot de passe par le
  # canal « clavier-interactif » : la coupure serait illusoire.
  set_sshd_directive "$cible" "KbdInteractiveAuthentication" "no"

  if ! "$bin" -t 2>/dev/null; then
    log_err "Configuration invalide : restauration immédiate."
    restore_file "$cible" "${cible}.bak.${RUN_STAMP}" || rm -f "$cible"
    ssh_reload_config || true
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    return 1
  fi

  if ! ssh_reload_config; then
    log_warn "sshd n'a pas pu être rechargé : la modification n'est pas active."
  fi

  # --- Vérification de ce qui s'applique VRAIMENT --------------------------------
  valeur="$(sshd_effective passwordauthentication)"
  if [[ "$valeur" == "no" ]]; then
    PASSWORD_AUTH_DISABLED=1
    echo ""
    log_ok "AUTHENTIFICATION PAR MOT DE PASSE DÉSACTIVÉE (vérifié via sshd -T)."
    echo ""
    echo "  ⚠ NE FERMEZ PAS CETTE SESSION avant d'avoir réussi une connexion"
    echo "    par clé depuis un AUTRE terminal :"
    echo ""
    echo "      ssh -i <votre-clé> -p $(ssh_listen_port) $AUTHKEY_USER@$(adresse_affichable)"
    echo ""
    if (( SSH_AUTH_ROLLBACK_ARMED )); then
      echo "  Une fois la connexion réussie, confirmez :"
      echo ""
      echo "      sudo ssh-cles-confirmer"
      echo ""
      echo "  Sans cette confirmation, le mot de passe sera réactivé dans"
      echo "  $SSH_AUTH_ROLLBACK_DELAY minutes. Si vous n'arrivez pas à vous"
      echo "  reconnecter : ne faites rien, attendez."
      echo ""
    else
      echo "  Pour revenir en arrière : sudo ssh-cles-rollback"
      echo "  (ou éditez $cible puis « systemctl reload ssh »)"
      echo ""
    fi
  else
    log_err "PasswordAuthentication vaut toujours « ${valeur:-inconnu} » : la coupure n'a PAS pris."
    local sources
    sources="$(sshd_directive_sources PasswordAuthentication)"
    if [[ -n "$sources" ]]; then
      echo "  sshd retient la PREMIÈRE valeur rencontrée, et ces fichiers la définissent :"
      printf '%s\n' "$sources" | sed -e 's/^/    /'
      echo "  Un fichier de /etc/ssh/sshd_config.d/ dont le numéro est INFÉRIEUR à"
      echo "  99 (par exemple 50-cloud-init.conf) l'emporte sur celui du script."
    fi
    echo ""
    log_info "L'état réel est donc inchangé : le mot de passe reste accepté."
    # On réaligne notre fichier sur la réalité et on désarme le filet, qui
    # n'aurait plus rien à restaurer.
    set_sshd_directive "$cible" "PasswordAuthentication" "yes"
    set_sshd_directive "$cible" "KbdInteractiveAuthentication" "yes"
    ssh_reload_config || true
    if (( SSH_AUTH_ROLLBACK_ARMED )); then
      systemctl stop ssh-cles-rollback.timer >/dev/null 2>&1 || true
      systemctl reset-failed ssh-cles-rollback.timer ssh-cles-rollback.service >/dev/null 2>&1 || true
      SSH_AUTH_ROLLBACK_ARMED=0
      log_info "Retour automatique désarmé (il n'y a rien à restaurer)."
    fi
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    rc=1
  fi

  return $rc
}

################################################################################
# POINT D'ARRÊT POUR LES TESTS
################################################################################
# Toutes les fonctions sont définies. Si le fichier a été sourcé uniquement pour
# les tester, on s'arrête ici : aucune étape interactive ne doit démarrer.
################################################################################
if [ -n "${PERSONNALISATION_SOURCE_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

################################################################################
# INITIALISATION
################################################################################
detect_os

################################################################################
# ÉTAPE 1 : CONFIGURATION DE LA COLORATION SYNTAXIQUE
################################################################################
banner "CONFIGURATION SERVEUR DEBIAN 13 (Trixie)"

while true; do
    banner "ÉTAPE 1/8 : COLORATION SYNTAXIQUE"
    echo "Souhaitez-vous activer la coloration syntaxique pour"
    echo "l'utilisateur root dans la console ?"
    echo ""
    echo "Cela améliorera la lisibilité du terminal en ajoutant"
    echo "des couleurs au prompt et aux commandes."
    echo ""
    echo "Choix disponibles :"
    echo -e "  ${C_BOLD}1. oui${C_RESET}         - Activer la coloration"
    echo -e "  ${C_BOLD}2. non${C_RESET}         - Continuer sans coloration"
    echo -e "  ${C_BOLD}3. explication${C_RESET} - Afficher plus de détails"
    echo ""
    if ! read -r -p "$(echo -e "${CURRENT_STEP_COLOR}?${C_RESET} Votre choix : ")" choix; then
        choix="2"
        echo ""
    fi

    case "$choix" in
    oui | o | y | 1)
        echo ""
        activer_coloration
        break
        ;;
    non | n | 2)
        echo ""
        log_info "Coloration syntaxique désactivée"
        echo "  Vous pourrez l'activer manuellement plus tard."
        echo ""
        break
        ;;
    explication | e | 3)
        afficher_explication
        read -r -p "Appuyez sur Entrée pour revenir au menu..." _ || true
        clear
        ;;
    *)
        echo ""
        log_warn "Choix invalide. Veuillez entrer '1', '2', ou '3'."
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
banner "ÉTAPE 2/8 : MISE À JOUR DU SYSTÈME"
echo "Cette étape va :"
echo "  1. Mettre à jour la liste des paquets disponibles (apt update)"
echo "  2. Installer les mises à jour de sécurité et correctifs (apt upgrade)"
echo ""
echo "⏱ Cette opération peut prendre plusieurs minutes selon"
echo "   votre connexion Internet et l'état du système."
echo ""

# Une résolution DNS cassée est la cause n°1 d'échec d'apt : autant le dire tout
# de suite plutôt que de laisser l'utilisateur face à un mur de messages.
if ! getent ahostsv4 deb.debian.org >/dev/null 2>&1; then
  log_warn "Le nom « deb.debian.org » ne se résout pas : la résolution DNS de ce serveur semble déjà défaillante."
  echo "  Contenu actuel de /etc/resolv.conf :"
  sed -e 's/^/    /' /etc/resolv.conf 2>/dev/null || echo "    (fichier absent)"
  echo ""
  echo "  La mise à jour va probablement échouer. L'étape 5 (réseau) permettra"
  echo "  de corriger durablement la configuration DNS."
  echo ""
  ask_yes_no "Tenter la mise à jour quand même ?" "o" || SKIP_UPDATE=1
fi

if [[ "${SKIP_UPDATE:-0}" != "1" ]]; then
  echo "Démarrage de la mise à jour..."
  echo ""
  if run_cmd "Actualisation de la liste des paquets (apt-get update)..." apt_run update; then
    if run_cmd "Installation des mises à jour (apt-get upgrade)..." apt_run upgrade; then
      UPDATE_DONE=1
    fi
  fi
fi

if (( UPDATE_DONE )); then
  echo ""
  log_ok "Système mis à jour avec succès"
  echo ""
else
  echo ""
  log_warn "La mise à jour n'a pas abouti complètement."
  echo ""
fi

# Outils nécessaires aux vérifications réseau de l'étape 5. iputils-ping est de
# priorité « important » sur Debian, donc normalement déjà présent ; arping est
# optionnel (il permet une détection fiable des conflits d'adresses).
need_cmd ping iputils-ping >/dev/null 2>&1 || log_warn "La commande « ping » est indisponible : les vérifications réseau seront limitées."
command -v arping >/dev/null 2>&1 || install_pkgs iputils-arping >/dev/null 2>&1 || true

################################################################################
# ÉTAPE 3 : CONFIGURATION DU CLAVIER FRANÇAIS
################################################################################
# Configure le clavier pour la disposition AZERTY française, ce qui est
# essentiel pour une saisie confortable si vous utilisez un clavier français.
################################################################################
banner "ÉTAPE 3/8 : CONFIGURATION DU CLAVIER"
echo "Configuration du clavier en disposition française (AZERTY)..."
echo ""

KEYBOARD_OK=1
run_cmd "Installation des paquets nécessaires..." install_pkgs console-setup keyboard-configuration kbd || KEYBOARD_OK=0

if (( KEYBOARD_OK )); then
  log_info "Chargement immédiat de la disposition française..."
  if loadkeys fr 2>/dev/null || loadkeys fr-pc 2>/dev/null || loadkeys fr-latin1 2>/dev/null || localectl set-keymap fr 2>/dev/null; then
    log_ok "Disposition française appliquée immédiatement à la console."
  else
    log_info "Chargement immédiat en console ignoré (sans console TTY physique ou via SSH)."
  fi

  if [ -f /etc/default/keyboard ]; then
    backup_file /etc/default/keyboard
    log_info "Configuration permanente du clavier..."
    if grep -q '^XKBLAYOUT=' /etc/default/keyboard; then
      sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT="fr"/' /etc/default/keyboard || KEYBOARD_OK=0
    else
      echo 'XKBLAYOUT="fr"' >> /etc/default/keyboard
    fi
  else
    log_info "Création de /etc/default/keyboard..."
    printf 'XKBMODEL="pc105"\nXKBLAYOUT="fr"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' > /etc/default/keyboard
  fi

  run_cmd "Reconfiguration du paquet keyboard-configuration..." \
    env DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive keyboard-configuration || KEYBOARD_OK=0
  run_cmd "Application de la configuration..." setupcon || log_warn "setupcon a échoué (sans console physique, c'est sans conséquence)."
fi

if (( KEYBOARD_OK )) && grep -q 'XKBLAYOUT="fr"' /etc/default/keyboard 2>/dev/null; then
  KEYBOARD_DONE=1
  echo ""
  log_ok "CLAVIER CONFIGURÉ EN FRANÇAIS"
  echo "  Les touches sont maintenant mappées en disposition AZERTY."
  echo "  Exemple : A et Q sont inversés par rapport à QWERTY"
  echo ""
else
  echo ""
  log_warn "La configuration du clavier n'a pas pu être appliquée entièrement."
  echo ""
fi

################################################################################
# ÉTAPE 4 : CONFIGURATION DU HOSTNAME
################################################################################
# Le hostname est le nom de votre machine sur le réseau.
# Il est affiché dans le prompt et utilisé pour identifier le serveur.
################################################################################
banner "ÉTAPE 4/8 : CONFIGURATION DU HOSTNAME"
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

# Les règles ci-dessus sont désormais RÉELLEMENT vérifiées : l'ancienne version
# les affichait puis acceptait n'importe quelle saisie, y compris un nom
# contenant « / » ou « & » qui corrompait /etc/hosts.
ask_input "Entrez le nouveau hostname (ou Entrée pour garder l'actuel)" "" v_hostname yes
NEW_HOSTNAME="$ASK_VALUE"

if [[ -n "$NEW_HOSTNAME" ]]; then
  echo ""
  if run_cmd "Modification du hostname en : $NEW_HOSTNAME" hostnamectl set-hostname "$NEW_HOSTNAME"; then
    backup_file /etc/hosts
    log_info "Mise à jour du fichier /etc/hosts..."
    # Réécriture par awk : le nom n'est jamais interprété comme une expression
    # régulière ni comme une chaîne de remplacement sed.
    HOSTS_TMP="$(mktemp)"
    awk -v h="$NEW_HOSTNAME" '
      $1 == "127.0.1.1" { print "127.0.1.1\t" h; done = 1; next }
      { print }
      END { if (!done) print "127.0.1.1\t" h }
    ' /etc/hosts > "$HOSTS_TMP" && cat "$HOSTS_TMP" > /etc/hosts
    rm -f "$HOSTS_TMP"
    HOSTNAME_DONE=1
    echo ""
    log_ok "Hostname configuré : $NEW_HOSTNAME"
    echo "  Le nouveau nom sera actif après reconnexion."
    echo ""
  fi
else
  echo ""
  log_info "Hostname inchangé : $(hostname)"
  echo ""
fi

################################################################################
# ÉTAPE 5 : CONFIGURATION RÉSEAU (IP FIXE)
################################################################################
# Cette étape PRÉPARE une adresse IP fixe. Elle n'applique rien : la bascule a
# lieu à la toute fin du script, après validation, afin que la session SSH
# courante survive jusqu'au bout.
#
# Pourquoi une IP fixe ?
# - Nécessaire pour un serveur accessible depuis le réseau
# - Évite que l'IP change au redémarrage (contrairement au DHCP)
# - Permet de configurer des règles firewall et DNS stables
################################################################################
banner "ÉTAPE 5/8 : CONFIGURATION RÉSEAU"
echo "Configuration d'une adresse IP fixe (statique)."
echo ""
echo "Une IP fixe est recommandée pour un serveur car :"
echo "  - L'adresse ne change jamais (contrairement au DHCP)"
echo "  - Facilite l'accès distant et la configuration DNS"
echo "  - Permet des règles firewall stables"
echo ""
echo "DÉROULEMENT SÉCURISÉ DE CETTE ÉTAPE :"
echo "  1. Vos paramètres sont validés (format, cohérence, conflit d'adresse)"
echo "  2. Ils sont testés À CHAUD sans toucher à votre adresse actuelle,"
echo "     donc SANS COUPER votre session SSH"
echo "  3. Rien n'est écrit tant que les tests n'ont pas réussi"
echo "  4. La bascule réelle n'aura lieu qu'à la fin du script"
echo "  5. Un retour automatique au DHCP est armé en cas de problème"
echo ""

if ask_yes_no "Souhaitez-vous configurer une IP fixe ?" "n"; then
  CONFIGURE_IP="y"

  DETECTED_IFACE="$(default_iface)"
  echo ""
  log_info "Détection des interfaces réseau disponibles..."
  echo ""
  echo "Interfaces réseau détectées :"
  while IFS= read -r _if; do
    [[ -n "$_if" ]] || continue
    _addr="$(ip -o -4 addr show dev "$_if" scope global 2>/dev/null | awk '{ print $4; exit }')"
    if [[ "$_if" == "$DETECTED_IFACE" ]]; then
      echo "  - $_if  ${_addr:+($_addr)}  ← interface portant la route par défaut"
    else
      echo "  - $_if  ${_addr:+($_addr)}"
    fi
  done < <(list_interfaces)
  echo ""
  echo "Note : 'lo' (loopback) est l'interface locale, elle n'apparaît pas ici."
  echo ""

  NET_ACCEPTED=0
  NET_ABANDON=0

  while (( ! NET_ACCEPTED && ! NET_ABANDON )); do

    # --- Saisie -----------------------------------------------------------------
    ask_input "Nom de l'interface réseau" "$DETECTED_IFACE" v_iface
    INTERFACE="$ASK_VALUE"

    NET_STACK="$(detect_net_stack "$INTERFACE")"
    echo ""
    log_ok "Gestionnaire réseau détecté : $(net_stack_label "$NET_STACK")"
    echo "  La configuration sera écrite dans cette pile, sans migration :"
    echo "  changer de gestionnaire en cours de route est la principale cause"
    echo "  de serveur injoignable après un post-installation."
    echo ""

    echo "Informations à fournir :"
    echo "  1. Adresse IP avec masque de sous-réseau en notation CIDR"
    echo "     Exemple : 192.168.1.100/24"
    echo "     /24 = masque 255.255.255.0 (réseau de 254 hôtes)"
    echo "     /16 = masque 255.255.0.0 (réseau de 65534 hôtes)"
    echo ""
    ask_input "Entrez l'adresse IP fixe avec le masque" "$(current_cidr "$INTERFACE")" v_cidr
    STATIC_IP="$ASK_VALUE"
    STATIC_IP_BARE="${STATIC_IP%%/*}"
    STATIC_PREFIX="${STATIC_IP##*/}"
    echo ""
    echo "  → Masque correspondant : $(prefix_to_netmask "$STATIC_PREFIX")"
    echo "  → Réseau               : $(net_addr "$STATIC_IP_BARE" "$STATIC_PREFIX")/$STATIC_PREFIX"
    echo ""

    echo "  2. Passerelle par défaut (gateway)"
    echo "     C'est généralement l'adresse IP de votre routeur/box"
    echo "     Exemple : 192.168.1.1 ou 192.168.0.254"
    echo ""
    ask_input "Entrez l'adresse de la passerelle" "$(current_gateway "$INTERFACE")" v_gateway
    GATEWAY="$ASK_VALUE"
    echo ""

    echo "  3. Serveurs DNS"
    echo "     Les serveurs DNS traduisent les noms de domaine en adresses IP"
    echo "     Exemples courants :"
    echo "       - Votre box/routeur : $GATEWAY (souvent le plus fiable en local)"
    echo "       - Cloudflare : 1.1.1.1 et 1.0.0.1"
    echo "       - Quad9      : 9.9.9.9 et 149.112.112.112"
    echo "       - Google     : 8.8.8.8 et 8.8.4.4"
    echo ""
    ask_input "Entrez le(s) serveur(s) DNS (séparés par des espaces)" "$(current_dns)" v_dns_list
    DNS_SERVERS="$ASK_VALUE"

    # --- Récapitulatif avant test ------------------------------------------------
    echo ""
    echo "------------------------------------------"
    echo "  PARAMÈTRES À TESTER"
    echo "------------------------------------------"
    echo "  Gestionnaire : $(net_stack_label "$NET_STACK")"
    echo "  Interface    : $INTERFACE"
    echo "  IP fixe      : $STATIC_IP"
    echo "  Masque       : $(prefix_to_netmask "$STATIC_PREFIX")"
    echo "  Passerelle   : $GATEWAY"
    echo "  DNS          : $DNS_SERVERS"
    echo "------------------------------------------"
    echo ""

    if ! ask_yes_no "Ces paramètres sont-ils corrects ?" "o"; then
      echo ""
      log_info "Reprise de la saisie."
      echo ""
      continue
    fi

    # --- Conflit d'adresse --------------------------------------------------------
    echo ""
    log_info "Vérification que $STATIC_IP_BARE n'est pas déjà utilisée sur le réseau..."
    if addr_in_use "$INTERFACE" "$STATIC_IP_BARE"; then
      echo ""
      log_err "L'adresse $STATIC_IP_BARE répond déjà : une autre machine l'utilise."
      echo "  Attribuer la même adresse à deux machines rend les deux instables."
      echo ""
      if ! ask_yes_no "Utiliser cette adresse quand même (fortement déconseillé) ?" "n"; then
        echo ""
        log_info "Choisissez une autre adresse."
        echo ""
        continue
      fi
    else
      log_ok "Adresse $STATIC_IP_BARE libre."
    fi

    # --- Test à chaud --------------------------------------------------------------
    if network_preflight "$INTERFACE" "$STATIC_IP" "$GATEWAY" "$DNS_SERVERS"; then
      NET_ACCEPTED=1
      break
    fi

    # --- Échec : que faire ? ---------------------------------------------------------
    echo ""
    echo "=========================================="
    echo "  LA CONFIGURATION PROPOSÉE NE FONCTIONNE PAS"
    echo "=========================================="
    echo ""
    echo "Aucun des domaines de test n'a répondu avec ces paramètres."
    echo "Rien n'a été modifié sur le système : votre configuration actuelle"
    echo "(DHCP ou autre) est intacte et votre session SSH n'a pas bougé."
    echo ""
    echo "Que souhaitez-vous faire ?"
    echo "  1. Ressaisir les paramètres (adresse, passerelle, DNS)"
    echo "  2. Abandonner l'IP fixe et RESTER EN DHCP (recommandé)"
    echo "  3. Forcer cette configuration malgré l'échec des tests"
    echo ""
    if ! read -r -p "Votre choix (1/2/3) : " NET_FAIL_CHOICE; then
      NET_FAIL_CHOICE="2"
      echo ""
    fi

    case "$NET_FAIL_CHOICE" in
      1)
        echo ""
        log_info "Reprise de la saisie."
        echo ""
        ;;
      3)
        echo ""
        log_warn "Configuration forcée malgré l'échec des tests."
        echo "  Le retour automatique au DHCP reste armé : si le serveur devient"
        echo "  injoignable, il restaurera seul sa configuration précédente."
        echo ""
        if ask_yes_no "Confirmez-vous ce choix risqué ?" "n"; then
          NET_ACCEPTED=1
        fi
        ;;
      *)
        echo ""
        log_info "IP fixe abandonnée : le serveur conserve sa configuration actuelle (DHCP)."
        echo ""
        NET_ABANDON=1
        CONFIGURE_IP="n"
        ;;
    esac
  done

  # --- Écriture de la configuration ------------------------------------------------
  if (( NET_ACCEPTED )); then
    banner "ENREGISTREMENT DE LA CONFIGURATION"
    # À partir d'ici, toute sauvegarde est enregistrée dans le manifeste réseau :
    # ce sont les seuls fichiers que le retour arrière restaurera. Le manifeste
    # est réinitialisé pour qu'une exécution précédente ne fasse pas restaurer
    # des fichiers sans rapport avec la bascule en cours.
    mkdir -p "$STATE_DIR"
    : > "$NET_BACKUP_MANIFEST"
    NET_BACKUP_MODE=1
    NET_WRITE_OK=1
    case "$NET_STACK" in
      ifupdown)       write_ifupdown_config "$INTERFACE" "$STATIC_IP" "$GATEWAY" "$DNS_SERVERS" || NET_WRITE_OK=0 ;;
      networkd)       write_networkd_config "$INTERFACE" "$STATIC_IP" "$GATEWAY" "$DNS_SERVERS" || NET_WRITE_OK=0 ;;
      networkmanager) write_nm_config       "$INTERFACE" "$STATIC_IP" "$GATEWAY" "$DNS_SERVERS" || NET_WRITE_OK=0 ;;
      *)              log_err "Pile réseau non reconnue : $NET_STACK" ; NET_WRITE_OK=0 ;;
    esac

    if (( NET_WRITE_OK )); then
      # NetworkManager gère lui-même le DNS du profil ; dans les autres cas il
      # faut le configurer explicitement, c'est là que se jouait la panne.
      if [[ "$NET_STACK" != "networkmanager" ]]; then
        configure_dns "$DNS_SERVERS"
      else
        DNS_METHOD="networkmanager"
        log_ok "DNS confié à NetworkManager : $DNS_SERVERS"
      fi

      NET_CONFIGURED=1
      NET_PENDING_APPLY=1

      echo ""
      log_ok "CONFIGURATION RÉSEAU ENREGISTRÉE (pas encore appliquée)"
      echo ""
      echo "Récapitulatif :"
      echo "  Gestionnaire : $(net_stack_label "$NET_STACK")"
      echo "  Interface    : $INTERFACE"
      echo "  IP fixe      : $STATIC_IP"
      echo "  Passerelle   : $GATEWAY"
      echo "  DNS          : $DNS_SERVERS"
      echo ""
      echo "⚠  La bascule sera proposée à la FIN du script, pour que votre"
      echo "   session SSH actuelle reste utilisable jusqu'au bout."
      echo ""
    else
      log_err "La configuration réseau n'a pas pu être écrite."
      echo "  Le système reste dans sa configuration actuelle."
      echo ""
    fi
    NET_BACKUP_MODE=0
  fi
else
  echo ""
  log_info "Configuration réseau ignorée"
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
################################################################################
banner "ÉTAPE 6/8 : UTILISATEUR STANDARD"
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

while true; do
  if ! read -r -p "Nom de l'utilisateur (laissez vide pour ignorer) : " STANDARD_USER; then
    STANDARD_USER=""
    echo ""
  fi

  if [[ -z "$STANDARD_USER" ]]; then
    echo "Aucun utilisateur standard ne sera créé."
    break
  fi

  if [[ ! "$STANDARD_USER" =~ ^[a-z][-a-z0-9_]*$ ]]; then
    echo ""
    log_warn "Le format du nom '$STANDARD_USER' est invalide."
    echo "  (Le système refuse les points, majuscules ou caractères spéciaux)"
    SUGGESTION="$(printf '%s' "$STANDARD_USER" | tr '[:upper:]' '[:lower:]' | tr '.' '-' | tr ' ' '-')"
    if [[ "$SUGGESTION" =~ ^[-0-9] ]]; then
      SUGGESTION="u$SUGGESTION"
    fi
    echo "  Suggestion : essayez '$SUGGESTION'"
    echo ""
    continue
  fi

  if id "$STANDARD_USER" &>/dev/null; then
    echo ""
    log_warn "L'utilisateur '$STANDARD_USER' existe déjà sur ce système."
    echo "  Veuillez choisir un autre nom."
    echo ""
    continue
  fi

  echo ""
  echo ">>> Création de l'utilisateur : $STANDARD_USER"

  if ! command -v sudo >/dev/null 2>&1; then
    run_cmd "Installation du paquet sudo..." install_pkgs sudo || true
  fi

  if adduser "$STANDARD_USER"; then
    if ! getent group sudo >/dev/null 2>&1; then
      log_warn "Le groupe « sudo » n'existe pas : installation de sudo requise."
      run_cmd "Installation du paquet sudo..." install_pkgs sudo || true
    fi

    if run_cmd "Ajout de $STANDARD_USER au groupe sudo..." usermod -aG sudo "$STANDARD_USER"; then
      USER_CREATED=1
      echo ""
      log_ok "SUCCÈS : Utilisateur $STANDARD_USER créé et ajouté aux administrateurs."
    else
      USER_CREATED=1
      log_warn "Utilisateur $STANDARD_USER créé, mais SANS privilèges sudo."
    fi

    echo ""
    if ask_yes_no "Voulez-vous activer la coloration syntaxique pour $STANDARD_USER ?" "o"; then
      USER_BASHRC="/home/$STANDARD_USER/.bashrc"
      if [ -f "$USER_BASHRC" ]; then
        log_info "Activation de la coloration dans $USER_BASHRC..."
        backup_file "$USER_BASHRC"
        sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' "$USER_BASHRC"
        sed -i 's/^#alias ls/alias ls/' "$USER_BASHRC"
        sed -i 's/^#alias grep/alias grep/' "$USER_BASHRC"
        sed -i 's/^#alias fgrep/alias fgrep/' "$USER_BASHRC"
        sed -i 's/^#alias egrep/alias egrep/' "$USER_BASHRC"
        log_ok "Prompt et alias colorés activés pour $STANDARD_USER"
      else
        log_warn "Fichier .bashrc non trouvé, impossible d'activer la coloration."
      fi
    fi
    break
  else
    echo ""
    log_err "La commande adduser a échoué."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    STANDARD_USER=""
    if ! ask_yes_no "Voulez-vous réessayer avec un autre nom ?" "o"; then
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
banner "ÉTAPE 7/8 : SÉCURISATION SSH"
echo "Configuration du service SSH pour l'accès à distance."
echo ""

log_info "Vérification de l'installation du service SSH..."

if dpkg -s openssh-server &> /dev/null; then
    log_ok "Le service SSH (openssh-server) est DÉJÀ INSTALLÉ."
    CURRENT_IP="$(current_ipv4 "${INTERFACE:-}")"
    if [[ -n "$CURRENT_IP" ]]; then
        echo "   Vous pouvez vous connecter via : ssh utilisateur@$CURRENT_IP"
    fi
else
    log_err "Le service SSH n'est PAS installé."
    echo "   Sans SSH, vous ne pourrez pas gérer ce serveur à distance."
    echo ""
    if ask_yes_no "Voulez-vous installer le serveur SSH maintenant ?" "o"; then
        run_cmd "Installation de openssh-server..." install_pkgs openssh-server || true
        if dpkg -s openssh-server &> /dev/null; then
            log_ok "SSH installé avec succès."
        else
            log_warn "Installation échouée : la configuration SSH sera passée."
            SKIP_SSH_CONFIG="true"
        fi
    else
        log_warn "Installation ignorée."
        echo "   La configuration SSH sera passée."
        SKIP_SSH_CONFIG="true"
    fi
fi

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

    if ssh_socket_active; then
      echo "ℹ Sur cette Debian 13, SSH est démarré par « ssh.socket »."
      echo "  C'est la socket systemd qui décide du port d'écoute : modifier"
      echo "  seulement « Port » dans sshd_config n'aurait AUCUN effet."
      echo "  Le script écrira donc la surcharge au bon endroit."
      echo ""
    fi

    ask_input "Entrez le nouveau port SSH (Entrée = 22)" "22" v_ssh_port
    SSH_PORT="$ASK_VALUE"

    SSHD_TARGET="$(sshd_target_file)"
    backup_file /etc/ssh/sshd_config
    [[ "$SSHD_TARGET" != "/etc/ssh/sshd_config" ]] && backup_file "$SSHD_TARGET"

    echo ""
    log_info "Configuration du port SSH sur $SSH_PORT (fichier : $SSHD_TARGET)..."
    set_sshd_directive "$SSHD_TARGET" "Port" "$SSH_PORT"

    # Menu pour la gestion du login ROOT
    echo ""
    echo "--- CONFIGURATION DE L'ACCÈS ROOT (root login) ---"
    echo "1. DÉSACTIVER la connexion root (Recommandé pour la sécurité)"
    echo "2. AUTORISER la connexion root (⚠ DANGEREUX ⚠ - Lab uniquement)"
    echo "3. Ne rien modifier (Garder la config actuelle)"
    echo ""
    if ! read -r -p "Votre choix (1/2/3) : " ROOT_LOGIN_CHOICE; then
      ROOT_LOGIN_CHOICE="3"
      echo ""
    fi

    case "$ROOT_LOGIN_CHOICE" in
      1)
          # Se couper l'accès root sans disposer d'un autre compte, c'est se
          # verrouiller dehors : on prévient explicitement.
          if (( ! USER_CREATED )) && ! getent group sudo 2>/dev/null | cut -d: -f4 | grep -q '[^[:space:]]'; then
              log_warn "Aucun utilisateur avec privilèges sudo n'a été détecté sur ce système."
              echo "  Désactiver l'accès root en SSH vous priverait de tout accès distant."
              echo ""
              if ask_yes_no "Désactiver quand même l'accès root ?" "n"; then
                  set_sshd_directive "$SSHD_TARGET" "PermitRootLogin" "no"
                  log_ok "Accès root SSH : DÉSACTIVÉ."
              else
                  log_info "Accès root conservé."
              fi
          else
              set_sshd_directive "$SSHD_TARGET" "PermitRootLogin" "no"
              log_ok "Accès root SSH : DÉSACTIVÉ."
          fi
          ;;
      2)
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
          if ask_yes_no "Confirmez-vous ce choix dangereux ?" "n"; then
              set_sshd_directive "$SSHD_TARGET" "PermitRootLogin" "yes"
              log_warn "Accès root SSH : AUTORISÉ (Soyez prudent)."
          else
              log_info "Annulé. Aucune modification sur l'accès root."
          fi
          ;;
      *)
          log_info "Aucune modification sur l'accès root."
          ;;
    esac

    # --- Validation AVANT redémarrage --------------------------------------------
    # Un sshd_config invalide empêche sshd de redémarrer : sur une machine
    # distante, c'est la perte définitive de l'accès. On vérifie donc d'abord, et
    # on restaure la sauvegarde en cas de problème.
    echo ""
    log_info "Vérification de la syntaxe de la configuration SSH..."
    SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
    if "$SSHD_BIN" -t 2>/tmp/sshd-test.$$; then
        log_ok "Configuration SSH syntaxiquement valide."
        SSHD_VALID=1
    else
        SSHD_VALID=0
        log_err "La configuration SSH générée est INVALIDE :"
        sed -e 's/^/    /' "/tmp/sshd-test.$$" >&2
        echo ""
        log_warn "Restauration de la configuration précédente pour ne pas perdre l'accès SSH."
        if [[ "$SSHD_TARGET" != "/etc/ssh/sshd_config" ]]; then
            # Le fichier d'inclusion est soit restauré depuis sa sauvegarde
            # (s'il préexistait), soit supprimé (si c'est nous qui l'avons créé).
            if ! restore_file "$SSHD_TARGET" "${SSHD_TARGET}.bak.${RUN_STAMP}"; then
                rm -f "$SSHD_TARGET"
            fi
        fi
        restore_file /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.${RUN_STAMP}" || true
        SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    fi
    rm -f "/tmp/sshd-test.$$"

    if (( SSHD_VALID )); then
        # --- Application du port --------------------------------------------------
        if ssh_socket_active; then
            log_info "Application du port via la surcharge de ssh.socket..."
            mkdir -p /etc/systemd/system/ssh.socket.d
            backup_file /etc/systemd/system/ssh.socket.d/10-port.conf
            cat > /etc/systemd/system/ssh.socket.d/10-port.conf <<EOF
# Généré par le script de personnalisation Debian 13 le $(date)
# Sur Debian 13, sshd est démarré par activation de socket : c'est ici, et non
# dans sshd_config, que se choisit le port d'écoute.
[Socket]
# La première ligne vide efface le port 22 hérité de l'unité d'origine.
ListenStream=
ListenStream=${SSH_PORT}
EOF
            systemctl daemon-reload
            run_cmd "Redémarrage de ssh.socket..." systemctl restart ssh.socket || true
            systemctl restart ssh.service >/dev/null 2>&1 || true
        else
            run_cmd "Redémarrage du service SSH..." systemctl restart ssh || true
        fi

        # --- Vérification RÉELLE du port d'écoute ---------------------------------
        sleep 1
        if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}\$"; then
            SSH_PORT_APPLIED=1
            echo ""
            log_ok "CONFIGURATION SSH APPLIQUÉE — SSH écoute bien sur le port $SSH_PORT."
        else
            echo ""
            log_err "SSH n'écoute PAS sur le port $SSH_PORT."
            echo "  Ports actuellement en écoute pour SSH :"
            ss -tlnp 2>/dev/null | grep -iE 'sshd|ssh\.socket' | sed -e 's/^/    /' || echo "    (aucun)"
            echo ""
            log_warn "Ne fermez PAS votre session actuelle avant d'avoir compris pourquoi."
            SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
        fi

        if [[ "$SSH_PORT" != "22" ]] && (( SSH_PORT_APPLIED )); then
            echo ""
            echo "!!! IMPORTANT !!!"
            echo "Le port SSH a été changé pour $SSH_PORT"
            echo "Pour vous reconnecter, utilisez : ssh -p $SSH_PORT utilisateur@serveur"
            echo ""
            echo "Si un pare-feu est actif (nftables, ufw, firewalld), pensez à y"
            echo "autoriser le port $SSH_PORT avant de fermer cette session."
            echo ""
        fi
    fi
else
    log_info "Configuration SSH sautée."
fi

################################################################################
# ÉTAPE 8 : AUTHENTIFICATION PAR CLÉ SSH
################################################################################
# Le mot de passe reste le maillon faible d'un accès SSH : il se devine, se
# rejoue, et les robots le testent sans relâche sur le port exposé. Cette étape
# met en place l'authentification par clé, dans un sens ou dans l'autre selon
# le rôle de la machine :
#
#   - machine CLIENTE : génération d'une paire de clés (la privée reste ici) ;
#   - SERVEUR         : dépôt d'une clé publique dans authorized_keys, puis
#                       durcissement de sshd.
#
# Elle vient APRÈS l'étape 7 à dessein : le port SSH définitif est déjà connu et
# vérifié, et l'utilisateur standard de l'étape 6 peut être proposé par défaut.
################################################################################
banner "ÉTAPE 8/8 : AUTHENTIFICATION PAR CLÉ SSH"
echo "Se connecter avec une clé plutôt qu'avec un mot de passe."
echo ""
echo "Une paire de clés se compose de deux fichiers :"
echo "  - la clé PRIVÉE, qui ne quitte jamais la machine cliente ;"
echo "  - la clé PUBLIQUE, déposée sur les serveurs à atteindre."
echo ""
echo "Le rôle de CETTE machine détermine ce qu'il y a à faire ici."
echo ""

while true; do
    echo -e "${CURRENT_STEP_COLOR}━━━ RÔLE DE CETTE MACHINE ━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo ""
    echo -e "  ${C_BOLD}1. SERVEUR${C_RESET}  — elle REÇOIT des connexions SSH"
    echo "     → déposer une clé publique dans authorized_keys"
    echo -e "  ${C_BOLD}2. CLIENT${C_RESET}   — elle SE CONNECTE à d'autres machines"
    echo "     → générer une paire de clés ici"
    echo -e "  ${C_BOLD}3. LES DEUX${C_RESET} — poste rebond, serveur qui sauvegarde ailleurs..."
    echo "     → générer une paire, puis déposer une clé publique"
    echo -e "  ${C_BOLD}4. Ignorer cette étape${C_RESET}"
    echo -e "  ${C_BOLD}5. Explication${C_RESET} (à quoi sert une clé, comment ça marche)"
    echo ""
    if ! read -r -p "$(echo -e "${CURRENT_STEP_COLOR}?${C_RESET} Votre choix : ")" SSH_ROLE_CHOICE; then
        SSH_ROLE_CHOICE="4"
        echo ""
    fi

    case "$SSH_ROLE_CHOICE" in
    1 | serveur | server | s)
        SSH_ROLE="serveur"
        installer_cle_publique || true
        durcir_authentification || true
        break
        ;;
    2 | client | c)
        SSH_ROLE="client"
        generer_paire_cles || true
        break
        ;;
    3 | deux | les-deux | b)
        SSH_ROLE="deux"
        # L'ordre compte : la paire est générée d'abord, ce qui permet ensuite
        # de proposer sa clé publique au dépôt local, puis de PROUVER que la
        # connexion par clé fonctionne avant tout durcissement.
        generer_paire_cles || true
        echo ""
        installer_cle_publique || true
        durcir_authentification || true
        break
        ;;
    4 | non | n | 0)
        SSH_ROLE="aucun"
        echo ""
        log_info "Étape ignorée : la connexion SSH restera par mot de passe."
        echo "  Vous pourrez relancer ce script plus tard pour la mettre en place."
        echo ""
        break
        ;;
    5 | explication | e)
        afficher_explication_cles
        read -r -p "Appuyez sur Entrée pour revenir au menu..." _ || true
        clear
        ;;
    *)
        echo ""
        log_warn "Choix invalide. Entrez un nombre de 1 à 5."
        echo ""
        ;;
    esac
done

################################################################################
# RÉCAPITULATIF FINAL
################################################################################
# Le récapitulatif s'appuie uniquement sur des drapeaux d'état réels : il
# n'annonce plus un succès simplement parce que l'utilisateur a saisi une
# valeur, comme c'était le cas auparavant.
################################################################################
banner "CONFIGURATION TERMINÉE"
echo "Récapitulatif des changements réellement appliqués :"

(( COLORATION_DONE )) && echo "  ✓ Coloration syntaxique activée pour root"
if (( UPDATE_DONE )); then
  echo "  ✓ Système mis à jour (Debian ${OS_VERSION_ID:-13})"
else
  echo "  ⚠ Mise à jour du système : incomplète ou ignorée"
fi
if (( KEYBOARD_DONE )); then
  echo "  ✓ Clavier configuré en français (AZERTY)"
else
  echo "  ⚠ Clavier : configuration non confirmée"
fi
(( HOSTNAME_DONE )) && echo "  ✓ Hostname : $NEW_HOSTNAME"

if (( NET_CONFIGURED )); then
  echo "  ✓ IP fixe préparée et testée : $STATIC_IP ($INTERFACE, $(net_stack_label "$NET_STACK"))"
  echo "    DNS : $DNS_SERVERS"
  echo "    (bascule proposée juste après ce récapitulatif)"
elif [[ "$CONFIGURE_IP" == "y" ]]; then
  echo "  ⚠ IP fixe : demandée mais NON configurée (le serveur reste en DHCP)"
fi

if (( USER_CREATED )); then
  echo "  ✓ Utilisateur créé : $STANDARD_USER (avec sudo)"
fi

if [[ "$SKIP_SSH_CONFIG" == "false" ]]; then
    if (( SSH_PORT_APPLIED )); then
        echo "  ✓ Port SSH : $SSH_PORT (vérifié en écoute)"
    else
        echo "  ⚠ Port SSH : modification NON confirmée"
    fi
    # sshd -T donne la configuration EFFECTIVE, en tenant compte des fichiers
    # inclus. Un simple grep du fichier principal passait à côté des surcharges.
    EFFECTIVE_ROOT="$("$(command -v sshd || echo /usr/sbin/sshd)" -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2; exit }')"
    case "${EFFECTIVE_ROOT:-}" in
        no)                    echo "  ✓ Accès root SSH : DÉSACTIVÉ (Sécurisé)" ;;
        yes)                   echo "  ⚠ Accès root SSH : AUTORISÉ (DANGEREUX)" ;;
        prohibit-password|without-password)
                               echo "  ✓ Accès root SSH : par clé uniquement" ;;
        forced-commands-only)  echo "  ✓ Accès root SSH : commandes forcées uniquement" ;;
        *)                     echo "  - Accès root SSH : état indéterminé" ;;
    esac
else
    echo "  - SSH : Non installé ou non configuré"
fi

# --- Authentification par clé ---------------------------------------------------
if (( KEY_GENERATED )); then
    echo "  ✓ Paire de clés créée pour $KEY_OWNER : $KEY_PATH"
    if (( KEY_HAS_PASSPHRASE )); then
        echo "    (protégée par une phrase de passe)"
    else
        echo "    ⚠ sans phrase de passe : le fichier suffit à ouvrir l'accès"
    fi
elif [[ "$SSH_ROLE" == "client" || "$SSH_ROLE" == "deux" ]]; then
    echo "  ⚠ Paire de clés : demandée mais NON créée"
fi

if (( AUTHKEY_ADDED )); then
    if (( AUTHKEY_COUNT > 0 )); then
        echo "  ✓ Clé publique installée pour $AUTHKEY_USER ($AUTHKEY_COUNT ajoutée(s))"
    else
        echo "  ✓ Clé publique déjà en place pour $AUTHKEY_USER (aucun ajout nécessaire)"
    fi
    if (( KEY_LOGIN_TESTED )); then
        echo "    (connexion par clé testée avec succès)"
    else
        echo "    ⚠ connexion par clé non testée : vérifiez-la AVANT de fermer cette session"
    fi
elif [[ "$SSH_ROLE" == "serveur" || "$SSH_ROLE" == "deux" ]]; then
    echo "  ⚠ Clé publique : aucune n'a été installée"
fi

if [[ "$SKIP_SSH_CONFIG" == "false" ]]; then
    EFFECTIVE_PASSWORD="$(sshd_effective passwordauthentication)"
    case "${EFFECTIVE_PASSWORD:-}" in
        no)
            echo "  ✓ Mot de passe SSH : DÉSACTIVÉ (connexion par clé uniquement)"
            if (( SSH_AUTH_ROLLBACK_ARMED )); then
                echo "    ⚠ À CONFIRMER sous $SSH_AUTH_ROLLBACK_DELAY min : sudo ssh-cles-confirmer"
            fi
            ;;
        yes) echo "  - Mot de passe SSH : toujours accepté" ;;
        *)   : ;;
    esac
fi

if (( SCRIPT_ERRORS > 0 )); then
  echo ""
  log_warn "$SCRIPT_ERRORS erreur(s) ont été rencontrée(s) pendant l'exécution (voir plus haut)."
fi

################################################################################
# COMMANDES DE VÉRIFICATION
################################################################################
# Affichées AVANT la bascule réseau : une fois celle-ci lancée, la session SSH
# se fige et l'utilisateur ne verrait plus rien de ce qui suit.
################################################################################
banner "COMMANDES DE VÉRIFICATION"
echo "Une fois reconnecté, lancez ces commandes :"
echo ""
VERIF_N=1
if (( NET_CONFIGURED )); then
  echo "$VERIF_N. Vérifier l'IP   : ip -4 addr show $INTERFACE"
  echo "   (Vous devriez voir $STATIC_IP)"
  VERIF_N=$((VERIF_N + 1))
  echo "$VERIF_N. Vérifier le DNS : getent hosts example.org && cat /etc/resolv.conf"
  VERIF_N=$((VERIF_N + 1))
  echo "$VERIF_N. CONFIRMER l'IP  : sudo ip-fixe-confirmer"
  VERIF_N=$((VERIF_N + 1))
fi
if [[ "$SKIP_SSH_CONFIG" == "false" ]]; then
  echo "$VERIF_N. Vérifier SSH    : ss -tlnp | grep -i ssh"
  echo "   (Vous devriez voir le port ${SSH_PORT:-22})"
  VERIF_N=$((VERIF_N + 1))
fi
if (( USER_CREATED )); then
  echo "$VERIF_N. Tester l'accès  : ssh -p ${SSH_PORT:-22} $STANDARD_USER@${STATIC_IP_BARE:-<IP>}"
  VERIF_N=$((VERIF_N + 1))
fi
if (( AUTHKEY_ADDED )); then
  echo "$VERIF_N. Tester la CLÉ   : ssh -i <votre-clé-privée> -p ${SSH_PORT:-22} $AUTHKEY_USER@$(adresse_affichable)"
  echo "   (depuis le poste qui détient la clé privée)"
  VERIF_N=$((VERIF_N + 1))
fi
if (( KEY_GENERATED )); then
  echo "$VERIF_N. Clé publique à diffuser : cat $KEY_PUB_PATH"
  VERIF_N=$((VERIF_N + 1))
fi
echo ""

# Le durcissement SSH prime sur tout le reste : sans confirmation dans le délai
# imparti, le mot de passe est réactivé. C'est donc la première chose à faire
# après reconnexion, avant même la confirmation de l'IP fixe.
if (( SSH_AUTH_ROLLBACK_ARMED )) && (( PASSWORD_AUTH_DISABLED )); then
  echo "=========================================================="
  echo "  ⚠ À FAIRE EN PRIORITÉ — DURCISSEMENT SSH NON CONFIRMÉ"
  echo "=========================================================="
  echo ""
  echo "  Le mot de passe SSH est désactivé, mais un retour automatique est"
  echo "  armé : sans confirmation dans les $SSH_AUTH_ROLLBACK_DELAY minutes,"
  echo "  il sera réactivé tout seul."
  echo ""
  echo "    1. Reconnectez-vous avec votre clé, depuis un AUTRE terminal :"
  echo "         ssh -i <votre-clé-privée> -p ${SSH_PORT:-22} $AUTHKEY_USER@$(adresse_affichable)"
  echo "    2. Confirmez :"
  echo "         sudo ssh-cles-confirmer"
  echo ""
  echo "  Si la connexion par clé échoue : ne faites rien, attendez. Le mot de"
  echo "  passe redeviendra utilisable tout seul."
  echo ""
  echo "=========================================================="
  echo ""
fi
echo "=========================================="
echo ""

################################################################################
# SIGNATURE
################################################################################
echo "Merci d'avoir utilisé ce script fourni par :"
echo "
 ⡷⣸ ⠄ ⢀⣀ ⢀⡀ ⡇ ⢀⣀ ⢀⣀   ⣏⡱ ⡎⢱ ⡏⢱ ⣎⣱ ⡇ ⡷⣸ ⣏⡉
 ⠇⠹ ⠇ ⠣⠤ ⠣⠜ ⠣ ⠣⠼ ⠭⠕   ⠧⠜ ⠣⠜ ⠧⠜ ⠇⠸ ⠇ ⠇⠹ ⠧⠤

LinkedIn : https://www.linkedin.com/in/bodaine
"
echo ""

################################################################################
# BASCULE RÉSEAU — DERNIÈRE OPÉRATION DU SCRIPT
################################################################################
# Tout le reste est terminé : on peut désormais toucher au réseau sans risquer
# d'interrompre le script à mi-parcours, et l'utilisateur a déjà sous les yeux
# toutes les instructions dont il aura besoin après la coupure.
################################################################################
if (( NET_PENDING_APPLY )); then
  banner "BASCULE VERS L'ADRESSE IP FIXE"

  RECONNECT_PORT="22"
  (( SSH_PORT_APPLIED )) && RECONNECT_PORT="$SSH_PORT"
  RECONNECT_USER="${STANDARD_USER:-utilisateur}"
  (( USER_CREATED )) || RECONNECT_USER="utilisateur"

  echo "La configuration a été enregistrée et validée. Il reste à l'appliquer."
  echo ""
  echo "  Adresse actuelle  : $(current_ipv4 "$INTERFACE") (session SSH en cours)"
  echo "  Nouvelle adresse  : $STATIC_IP_BARE"
  echo ""
  echo "Au moment de la bascule, votre session SSH actuelle se figera : elle est"
  echo "attachée à l'ancienne adresse. C'est normal et sans gravité."
  echo ""
  echo "Deux possibilités :"
  echo "  1. Appliquer MAINTENANT (recommandé) — vous vous reconnectez tout de"
  echo "     suite sur la nouvelle adresse et vous confirmez."
  echo "  2. Appliquer au PROCHAIN REDÉMARRAGE — rien ne bouge d'ici là."
  echo ""
  echo "Dans les deux cas, un retour automatique au DHCP est armé : sans"
  echo "confirmation de votre part, le serveur restaure seul sa configuration."
  echo ""

  if ! read -r -p "Votre choix (1/2) : " APPLY_CHOICE; then
    APPLY_CHOICE="2"
    echo ""
  fi

  install_network_tools

  if [[ "$APPLY_CHOICE" == "1" ]]; then
    NET_APPLY_MODE="now"

    echo ""
    echo "Délai avant retour automatique au DHCP en l'absence de confirmation :"
    echo "  1. 5 minutes"
    echo "  2. 10 minutes (recommandé)"
    echo "  3. 15 minutes"
    echo ""
    if ! read -r -p "Votre choix (1/2/3) : " DELAY_CHOICE; then
      DELAY_CHOICE="2"
      echo ""
    fi
    case "$DELAY_CHOICE" in
      1) ROLLBACK_DELAY=5 ;;
      3) ROLLBACK_DELAY=15 ;;
      *) ROLLBACK_DELAY=10 ;;
    esac

    # Le retour arrière est armé AVANT la bascule : si celle-ci échoue à
    # mi-chemin, le filet est déjà en place.
    systemctl stop ip-fixe-rollback.timer >/dev/null 2>&1 || true
    systemctl reset-failed ip-fixe-rollback.timer ip-fixe-rollback.service >/dev/null 2>&1 || true

    if systemd-run --unit=ip-fixe-rollback \
         --description="Retour automatique au DHCP si le changement d'IP n'est pas confirmé" \
         --on-active="${ROLLBACK_DELAY}min" \
         /usr/local/sbin/ip-fixe-rollback >/dev/null 2>&1; then
      log_ok "Retour automatique au DHCP armé dans $ROLLBACK_DELAY minutes."
    else
      log_warn "Impossible d'armer le retour automatique minuté."
      echo "  Le garde-fou de démarrage reste actif, mais soyez prudent."
      echo ""
      if ! ask_yes_no "Appliquer la nouvelle adresse malgré tout ?" "n"; then
        NET_APPLY_MODE="reboot"
      fi
    fi

    if [[ "$NET_APPLY_MODE" == "now" ]]; then
      echo ""
      echo "=========================================================="
      echo "  À FAIRE IMMÉDIATEMENT APRÈS LA BASCULE"
      echo "=========================================================="
      echo ""
      echo "  1. Reconnectez-vous :"
      echo ""
      echo "       ssh -p $RECONNECT_PORT $RECONNECT_USER@$STATIC_IP_BARE"
      echo ""
      echo "  2. Confirmez le changement (sinon retour au DHCP dans"
      echo "     $ROLLBACK_DELAY minutes) :"
      echo ""
      echo "       sudo ip-fixe-confirmer"
      echo ""
      echo "  Si vous n'arrivez pas à vous reconnecter : ne faites rien."
      echo "  Le serveur reviendra tout seul en DHCP dans $ROLLBACK_DELAY minutes,"
      echo "  et redeviendra joignable sur son ancienne adresse."
      echo ""
      echo "=========================================================="
      echo ""
      read -r -p "Appuyez sur Entrée pour lancer la bascule..." _ || true

      # La bascule est confiée à systemd : détachée de cette session SSH, elle
      # ira jusqu'au bout même si la connexion tombe pendant l'opération.
      if systemd-run --unit=ip-fixe-appliquer --collect \
           --description="Application de la configuration IP fixe" \
           /usr/local/sbin/ip-fixe-appliquer >/dev/null 2>&1; then
        log_ok "Bascule lancée en arrière-plan (indépendante de cette session)."
        echo ""
        echo "Votre session va probablement se figer d'un instant à l'autre."
        echo "Reconnectez-vous sur : ssh -p $RECONNECT_PORT $RECONNECT_USER@$STATIC_IP_BARE"
        echo "puis lancez : sudo ip-fixe-confirmer"
        echo ""
        # Le script s'arrête ici : proposer un redémarrage maintenant n'aurait
        # aucun sens, la session est sur le point d'être coupée et un reboot
        # annulerait la minuterie de retour arrière encore en cours.
        if (( SCRIPT_ERRORS > 0 )); then
          exit 1
        fi
        exit 0
      fi

      log_err "Le lancement de la bascule a échoué."
      echo "  Vous pouvez l'appliquer manuellement : sudo /usr/local/sbin/ip-fixe-appliquer"
      echo ""
      SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    fi
  else
    NET_APPLY_MODE="reboot"
  fi

  if [[ "$NET_APPLY_MODE" == "reboot" ]]; then
    echo ""
    log_info "La nouvelle adresse sera appliquée au prochain redémarrage."
    echo ""
    echo "  Après le redémarrage :"
    echo "    - Reconnectez-vous : ssh -p $RECONNECT_PORT $RECONNECT_USER@$STATIC_IP_BARE"
    echo "    - Confirmez        : sudo ip-fixe-confirmer"
    echo ""
    echo "  Si le serveur n'est pas joignable après le redémarrage, le garde-fou"
    echo "  intégré détectera l'absence de connectivité dans la minute qui suit"
    echo "  le démarrage et restaurera automatiquement la configuration DHCP."
    echo ""
    echo "  Pour appliquer sans redémarrer : sudo /usr/local/sbin/ip-fixe-appliquer"
    echo ""
  fi
fi

################################################################################
# REDÉMARRAGE
################################################################################
# On n'arrive ici que si aucune bascule immédiate n'a été lancée : soit il n'y
# avait pas de changement d'IP, soit il est prévu pour le prochain démarrage.
################################################################################
if (( NET_PENDING_APPLY )) && [[ "$NET_APPLY_MODE" == "reboot" ]]; then
  echo "Redémarrer maintenant appliquera aussi la nouvelle adresse IP."
  echo "Pensez à lancer « sudo ip-fixe-confirmer » une fois reconnecté."
  echo ""
fi

if ask_yes_no "Voulez-vous redémarrer le système maintenant ?" "n"; then
  echo ""
  echo "Redémarrage en cours..."
  reboot
else
  echo ""
  echo "N'oubliez pas de redémarrer manuellement avec la commande 'reboot'"
  echo "pour appliquer tous les changements système."
  echo ""
fi

# Le code de sortie reflète l'état réel de l'exécution : un outil d'automatisation
# appelant ce script doit pouvoir détecter qu'une étape a échoué.
if (( SCRIPT_ERRORS > 0 )); then
  exit 1
fi
exit 0
