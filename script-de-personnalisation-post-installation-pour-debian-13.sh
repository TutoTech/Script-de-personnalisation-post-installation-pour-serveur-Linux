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
# FONCTION : Affichage
################################################################################
# Uniformise la présentation. Les messages d'erreur et d'avertissement partent
# sur la sortie d'erreur (stderr) afin de rester visibles même si la sortie
# standard est redirigée dans un fichier de log.
################################################################################
log()       { printf '%s\n' "$*"; }
log_info()  { printf '→ %s\n' "$*"; }
log_ok()    { printf '✓ %s\n' "$*"; }
log_warn()  { printf '⚠ %s\n' "$*" >&2; }
log_err()   { printf '❌ %s\n' "$*" >&2; }

banner() {
  echo ""
  echo "=========================================="
  echo "  $*"
  echo "=========================================="
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
  local hint reply

  case "${default,,}" in
    y|yes|o|oui|1) hint="[O/n]" ;;
    n|no|non|0)    hint="[o/N]" ;;
    *)             hint="[o/n]" ;;
  esac

  while true; do
    if ! read -r -p "$question $hint : " reply; then
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
      shown="$prompt [$default] : "
    else
      shown="$prompt : "
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

v_ssh_port() {
  local port="${1:-}"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    log_warn "« $port » n'est pas un port valide (1-65535)."
    return 1
  fi
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
echo ""
echo "╔════════════════════════════════════════╗"
echo "║   CONFIGURATION SERVEUR DEBIAN 13      ║"
echo "║            (Trixie)                    ║"
echo "╚════════════════════════════════════════╝"
echo ""

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
    echo "  1. oui         - Activer la coloration"
    echo "  2. non         - Continuer sans coloration"
    echo "  3. explication - Afficher plus de détails"
    echo ""
    if ! read -r -p "Votre choix : " choix; then
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
banner "ÉTAPE 2/7 : MISE À JOUR DU SYSTÈME"
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
banner "ÉTAPE 3/7 : CONFIGURATION DU CLAVIER"
echo "Configuration du clavier en disposition française (AZERTY)..."
echo ""

KEYBOARD_OK=1
run_cmd "Installation des paquets nécessaires..." install_pkgs console-setup keyboard-configuration || KEYBOARD_OK=0

if (( KEYBOARD_OK )); then
  run_cmd "Chargement immédiat de la disposition française..." loadkeys fr || true

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
banner "ÉTAPE 4/7 : CONFIGURATION DU HOSTNAME"
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
banner "ÉTAPE 5/7 : CONFIGURATION RÉSEAU"
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
banner "ÉTAPE 6/7 : UTILISATEUR STANDARD"
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
banner "ÉTAPE 7/7 : SÉCURISATION SSH"
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
fi
echo ""
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
