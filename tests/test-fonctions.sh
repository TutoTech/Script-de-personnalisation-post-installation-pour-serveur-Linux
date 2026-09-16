#!/bin/bash
################################################################################
# Tests unitaires des fonctions pures du script de personnalisation Debian 13
################################################################################
# Ces tests ne touchent JAMAIS au système : ils ne vérifient que les fonctions
# de calcul et de validation, chargées via PERSONNALISATION_SOURCE_ONLY.
#
# Lancement :  ./tests/test-fonctions.sh
################################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CIBLE="$SCRIPT_DIR/script-de-personnalisation-post-installation-pour-debian-13.sh"

if [[ ! -f "$CIBLE" ]]; then
  echo "Script introuvable : $CIBLE" >&2
  exit 1
fi

# Chargement des fonctions uniquement.
PERSONNALISATION_SOURCE_ONLY=1
export PERSONNALISATION_SOURCE_ONLY
# shellcheck source=/dev/null
. "$CIBLE"

TESTS=0
ECHECS=0

ok() {
  TESTS=$((TESTS + 1))
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$description"
  else
    printf '  ✗ %s  (attendu : succès)\n' "$description" >&2
    ECHECS=$((ECHECS + 1))
  fi
}

ko() {
  TESTS=$((TESTS + 1))
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✗ %s  (attendu : échec)\n' "$description" >&2
    ECHECS=$((ECHECS + 1))
  else
    printf '  ✓ %s\n' "$description"
  fi
}

egal() {
  TESTS=$((TESTS + 1))
  local description="$1" attendu="$2" obtenu="$3"
  if [[ "$attendu" == "$obtenu" ]]; then
    printf '  ✓ %s\n' "$description"
  else
    printf '  ✗ %s  (attendu « %s », obtenu « %s »)\n' "$description" "$attendu" "$obtenu" >&2
    ECHECS=$((ECHECS + 1))
  fi
}

echo "== is_ipv4 =="
ok "192.168.0.10 est valide"          is_ipv4 192.168.0.10
ok "0.0.0.0 est valide"               is_ipv4 0.0.0.0
ok "255.255.255.255 est valide"       is_ipv4 255.255.255.255
ko "192.168.0.256 est refusée"        is_ipv4 192.168.0.256
ko "192.168.0 est refusée"            is_ipv4 192.168.0
ko "192.168.0.1.5 est refusée"        is_ipv4 192.168.0.1.5
ko "010.1.1.1 (zéro en tête) refusée" is_ipv4 010.1.1.1
ko "une chaîne vide est refusée"      is_ipv4 ""
ko "abc.def.ghi.jkl est refusée"      is_ipv4 abc.def.ghi.jkl

echo "== is_ipaddr (IPv4 ou IPv6) =="
ok "1.1.1.1"                          is_ipaddr 1.1.1.1
ok "2606:4700:4700::1111"             is_ipaddr 2606:4700:4700::1111
ko "pas-une-adresse"                  is_ipaddr pas-une-adresse

echo "== conversions et arithmétique =="
egal "ip_to_int 0.0.0.0"              "0"               "$(ip_to_int 0.0.0.0)"
egal "ip_to_int 255.255.255.255"      "4294967295"      "$(ip_to_int 255.255.255.255)"
egal "ip_to_int 192.168.0.10"         "3232235530"      "$(ip_to_int 192.168.0.10)"
egal "int_to_ip 3232235530"           "192.168.0.10"    "$(int_to_ip 3232235530)"
egal "prefix_to_netmask 24"           "255.255.255.0"   "$(prefix_to_netmask 24)"
egal "prefix_to_netmask 16"           "255.255.0.0"     "$(prefix_to_netmask 16)"
egal "prefix_to_netmask 8"            "255.0.0.0"       "$(prefix_to_netmask 8)"
egal "prefix_to_netmask 30"           "255.255.255.252" "$(prefix_to_netmask 30)"
egal "prefix_to_netmask 32"           "255.255.255.255" "$(prefix_to_netmask 32)"
egal "net_addr 192.168.0.10/24"       "192.168.0.0"     "$(net_addr 192.168.0.10 24)"
egal "net_addr 10.5.7.9/16"           "10.5.0.0"        "$(net_addr 10.5.7.9 16)"
egal "bcast_addr 192.168.0.10/24"     "192.168.0.255"   "$(bcast_addr 192.168.0.10 24)"
egal "bcast_addr 172.16.4.3/22"       "172.16.7.255"    "$(bcast_addr 172.16.4.3 22)"

echo "== ip_in_subnet =="
ok "192.168.0.1 dans 192.168.0.10/24"    ip_in_subnet 192.168.0.1 192.168.0.10 24
ko "192.168.1.1 hors 192.168.0.10/24"    ip_in_subnet 192.168.1.1 192.168.0.10 24
ok "10.0.255.1 dans 10.0.0.5/16"         ip_in_subnet 10.0.255.1 10.0.0.5 16
ko "10.1.0.1 hors 10.0.0.5/16"           ip_in_subnet 10.1.0.1 10.0.0.5 16

echo "== v_cidr =="
ok "192.168.1.100/24 accepté"            v_cidr 192.168.1.100/24
ok "10.0.0.1/8 accepté"                  v_cidr 10.0.0.1/8
ok "192.168.0.1/31 accepté (liaison)"    v_cidr 192.168.0.1/31
ko "192.168.1.100 sans masque refusé"    v_cidr 192.168.1.100
ko "10.0.0.1/33 refusé"                  v_cidr 10.0.0.1/33
ko "10.0.0.1/0 refusé"                   v_cidr 10.0.0.1/0
ko "adresse réseau 192.168.0.0/24"       v_cidr 192.168.0.0/24
ko "adresse broadcast 192.168.0.255/24"  v_cidr 192.168.0.255/24
ko "192.168.0.300/24 refusé"             v_cidr 192.168.0.300/24

echo "== v_gateway (dépend de STATIC_IP) =="
# v_gateway lit la variable globale STATIC_IP pour vérifier l'appartenance au
# sous-réseau : on la positionne avant l'appel.
# shellcheck disable=SC2034
STATIC_IP="192.168.0.10/24"
ok "192.168.0.1 acceptée"                v_gateway 192.168.0.1
ko "identique à l'adresse du serveur"    v_gateway 192.168.0.10
ko "adresse invalide"                    v_gateway 192.168.0.999

echo "== v_dns_list =="
ok "un serveur"                          v_dns_list "1.1.1.1"
ok "deux serveurs"                       v_dns_list "8.8.8.8 1.1.1.1"
ok "IPv6 accepté"                        v_dns_list "2606:4700:4700::1111"
ko "liste vide refusée"                  v_dns_list ""
ko "valeur non numérique refusée"        v_dns_list "8.8.8.8 monserveur"

echo "== v_hostname =="
ok "serveur-web"                         v_hostname serveur-web
ok "db01"                                v_hostname db01
ko "majuscules refusées"                 v_hostname Serveur
ko "point refusé"                        v_hostname j.dupont
ko "tiret en fin refusé"                 v_hostname serveur-
ko "tiret au début refusé"               v_hostname -serveur
ko "slash refusé"                        v_hostname "srv/1"
ko "plus de 63 caractères refusé"        v_hostname "$(printf 'a%.0s' $(seq 1 64))"

echo "== v_iface =="
ko "interface inexistante refusée"       v_iface interface-qui-nexiste-pas
ko "nom avec espace refusé"              v_iface "eth 0"

echo "== build_resolv_conf =="
TMP_RESOLV="$(mktemp)"
build_resolv_conf "$TMP_RESOLV" "8.8.8.8 1.1.1.1"
egal "deux lignes nameserver"            "2" "$(grep -c '^nameserver ' "$TMP_RESOLV")"
ok   "options timeout présente"          grep -q '^options timeout:2 attempts:2' "$TMP_RESOLV"
build_resolv_conf "$TMP_RESOLV" "1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4 5.5.5.5"
egal "limité aux 3 premiers serveurs"    "3" "$(grep -c '^nameserver ' "$TMP_RESOLV")"
rm -f "$TMP_RESOLV"

echo "== net_stack_label =="
egal "ifupdown"       "ifupdown (/etc/network/interfaces)" "$(net_stack_label ifupdown)"
egal "networkd"       "systemd-networkd"                   "$(net_stack_label networkd)"
egal "networkmanager" "NetworkManager"                     "$(net_stack_label networkmanager)"
egal "valeur inconnue" "inconnue"                          "$(net_stack_label nimportequoi)"

echo "== write_marked_block (idempotence) =="
TMP_RC="$(mktemp)"
printf 'ligne existante\n' > "$TMP_RC"
for _ in 1 2 3; do
  write_marked_block "$TMP_RC" "# >>> debut >>>" "# <<< fin <<<" <<'BLOC'
contenu du bloc
BLOC
done
egal "le marqueur de début n'apparaît qu'une fois" "1" "$(grep -c '^# >>> debut >>>$' "$TMP_RC")"
egal "le contenu n'est pas dupliqué"               "1" "$(grep -c '^contenu du bloc$' "$TMP_RC")"
egal "la ligne préexistante est conservée"         "1" "$(grep -c '^ligne existante$' "$TMP_RC")"
rm -f "$TMP_RC"

# Non-régression : un marqueur de fin supprimé à la main ne doit JAMAIS faire
# disparaître la suite du fichier. Un découpage « à l'état » tronquait tout ce
# qui suivait le marqueur de début.
TMP_RC="$(mktemp)"
printf 'avant\n# >>> debut >>>\nancien bloc\nAPRES-A-CONSERVER\nfin de fichier\n' > "$TMP_RC"
write_marked_block "$TMP_RC" "# >>> debut >>>" "# <<< fin <<<" 2>/dev/null <<'BLOC'
nouveau contenu
BLOC
egal "marqueur de fin absent : ligne suivante conservée" "1" "$(grep -c '^APRES-A-CONSERVER$' "$TMP_RC")"
egal "marqueur de fin absent : fin de fichier conservée" "1" "$(grep -c '^fin de fichier$' "$TMP_RC")"
egal "marqueur de fin absent : nouveau bloc ajouté"      "1" "$(grep -c '^nouveau contenu$' "$TMP_RC")"
rm -f "$TMP_RC"

# Cas inverse : marqueurs présents mais dans le désordre — on ne touche à rien.
TMP_RC="$(mktemp)"
printf '# <<< fin <<<\nA-CONSERVER\n# >>> debut >>>\n' > "$TMP_RC"
write_marked_block "$TMP_RC" "# >>> debut >>>" "# <<< fin <<<" 2>/dev/null <<'BLOC'
nouveau contenu
BLOC
egal "marqueurs inversés : contenu conservé"             "1" "$(grep -c '^A-CONSERVER$' "$TMP_RC")"
rm -f "$TMP_RC"

# Réécriture atomique : droits conservés, aucun temporaire laissé, et un lien
# symbolique est suivi (le fichier visé est réécrit, le lien reste en place).
TMP_RCD="$(mktemp -d)"
printf 'ligne existante\n' > "$TMP_RCD/rc"
chmod 640 "$TMP_RCD/rc"
ln -s "$TMP_RCD/rc" "$TMP_RCD/lien"
write_marked_block "$TMP_RCD/lien" "# >>> debut >>>" "# <<< fin <<<" <<'BLOC'
via le lien
BLOC
egal "droits conservés"                      "640" "$(stat -c '%a' "$TMP_RCD/rc")"
ok   "le lien symbolique est resté un lien"  test -L "$TMP_RCD/lien"
egal "le fichier visé porte le bloc"         "1" "$(grep -c '^via le lien$' "$TMP_RCD/rc")"
# shellcheck disable=SC2012
egal "aucun temporaire laissé"               "lien rc" "$(ls -A "$TMP_RCD" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$TMP_RCD"

# Lien symbolique irrésoluble (répertoire cible absent) : refusé, rien n'est écrit.
TMP_RCD="$(mktemp -d)"
ln -s "$TMP_RCD/inexistant/cible" "$TMP_RCD/lien-casse"
wmb_lien_casse() { write_marked_block "$TMP_RCD/lien-casse" "# >>> debut >>>" "# <<< fin <<<" <<< "bloc"; }
ko   "lien irrésoluble : refusé"                          wmb_lien_casse
ko   "lien irrésoluble : rien n'est créé"                 test -e "$TMP_RCD/inexistant"
egal "lien irrésoluble : aucun temporaire laissé"         "lien-casse" "$(ls -A "$TMP_RCD")"
rm -rf "$TMP_RCD"

echo "== set_sshd_directive =="
TMP_SSHD="$(mktemp)"
printf '#Port 22\nPermitRootLogin prohibit-password\n' > "$TMP_SSHD"
set_sshd_directive "$TMP_SSHD" "Port" "2222"
egal "Port décommenté et modifié"        "Port 2222" "$(grep -E '^Port ' "$TMP_SSHD")"
set_sshd_directive "$TMP_SSHD" "PermitRootLogin" "no"
egal "PermitRootLogin remplacé"          "PermitRootLogin no" "$(grep -E '^PermitRootLogin ' "$TMP_SSHD")"
set_sshd_directive "$TMP_SSHD" "MaxAuthTries" "3"
egal "directive absente ajoutée"         "MaxAuthTries 3" "$(grep -E '^MaxAuthTries ' "$TMP_SSHD")"
egal "aucune duplication de Port"        "1" "$(grep -c '^Port ' "$TMP_SSHD")"
rm -f "$TMP_SSHD"

echo "== set_sshd_directive (caractères spéciaux dans la valeur) =="
# « & », « | » et « \ » ont un sens dans la partie remplacement de sed : une
# valeur qui en contient doit être écrite telle quelle.
TMP_SSHD="$(mktemp)"
printf '#Banner none\n' > "$TMP_SSHD"
set_sshd_directive "$TMP_SSHD" "Banner" '/etc/issue&net|x\y'
egal "« & », « | » et « \ » écrits tels quels" 'Banner /etc/issue&net|x\y' "$(grep -E '^Banner ' "$TMP_SSHD")"
rm -f "$TMP_SSHD"

echo "== backup_file (manifeste inaccessible : pas de copie orpheline) =="
# Une copie que le manifeste ne référence pas ne serait jamais retrouvée : elle
# est retirée quand l'inscription échoue (hors étape réseau).
TMP_BF="$(mktemp -d)"
printf 'contenu\n' > "$TMP_BF/conf"
# Lues par backup_file.
# shellcheck disable=SC2034
STATE_DIR="$TMP_BF/etat" BACKUP_MANIFEST="$TMP_BF/etat/manifest" NET_BACKUP_MODE=0
ok   "manifeste accessible : sauvegarde réussie"             backup_file "$TMP_BF/conf"
ok   "copie présente"                                        test -e "$TMP_BF/conf.bak.$RUN_STAMP"
egal "copie inscrite au manifeste"                           "1" "$(grep -c "^$TMP_BF/conf"$'\t' "$BACKUP_MANIFEST")"
rm -f "$TMP_BF/conf.bak.$RUN_STAMP"
BACKUP_MANIFEST="$TMP_BF/etat/inexistant/manifest"
ko   "manifeste inaccessible : échec"                        backup_file "$TMP_BF/conf"
ko   "manifeste inaccessible : aucune copie orpheline"       test -e "$TMP_BF/conf.bak.$RUN_STAMP"
printf 'x\n' > "$TMP_BF/pas-un-dossier"
STATE_DIR="$TMP_BF/pas-un-dossier/etat" BACKUP_MANIFEST="$STATE_DIR/manifest"
ko   "répertoire d'état impossible : échec"                  backup_file "$TMP_BF/conf"
ko   "répertoire d'état impossible : aucune copie orpheline" test -e "$TMP_BF/conf.bak.$RUN_STAMP"
rm -rf "$TMP_BF"

echo "== resoudre_lien =="
TMP_RL="$(mktemp -d)"
printf 'x\n' > "$TMP_RL/fichier"
ln -s "$TMP_RL/fichier" "$TMP_RL/lien"
ln -s "$TMP_RL/inexistant/cible" "$TMP_RL/lien-casse"
egal "fichier ordinaire : lui-même"          "$TMP_RL/fichier" "$(resoudre_lien "$TMP_RL/fichier")"
egal "lien symbolique : sa cible"            "$TMP_RL/fichier" "$(resoudre_lien "$TMP_RL/lien")"
ko   "lien irrésoluble : échec"              resoudre_lien "$TMP_RL/lien-casse"
ko   "argument vide : échec"                 resoudre_lien ""
rm -rf "$TMP_RL"

echo "== restore_file / sshd_restore_or_remove =="
# La copie passe par un fichier temporaire : un échec ne supprime jamais
# l'original. Codes : 0 restauré, 2 sauvegarde absente, 1 copie en échec.
TMP_RSD="$(mktemp -d)"
TMP_RS="$TMP_RSD/fichier"
printf 'origine\n' > "$TMP_RS"
cp "$TMP_RS" "$TMP_RS.bak.$RUN_STAMP"
chmod 640 "$TMP_RS.bak.$RUN_STAMP"
printf 'modifie\n' > "$TMP_RS"
chmod 600 "$TMP_RS"
ok   "restauration réussie"                 restore_file "$TMP_RS" "$TMP_RS.bak.$RUN_STAMP"
egal "contenu d'origine rétabli"            "origine" "$(cat "$TMP_RS")"
egal "droits de la sauvegarde reportés"     "640" "$(stat -c '%a' "$TMP_RS")"
egal "aucun temporaire laissé (nom imprévisible, nettoyé)" "0" "$(find "$TMP_RSD" -name '.*' | wc -l)"
egal "sauvegarde absente : code 2"          "2" "$(restore_file "$TMP_RS" "$TMP_RS-absent"; echo $?)"
egal "sauvegarde absente : fichier intact"  "origine" "$(cat "$TMP_RS")"
ok   "sshd_restore_or_remove restaure"      sshd_restore_or_remove "$TMP_RS"
rm -f "$TMP_RS.bak.$RUN_STAMP"
ok   "sans sauvegarde : fichier créé par nous, supprimé" sshd_restore_or_remove "$TMP_RS"
ko   "le fichier n'existe plus"             test -e "$TMP_RS"
rm -rf "$TMP_RSD"

echo "== sshd_snapshot_durcissement / sshd_restaurer_durcissement =="
# La copie de l'exécution (.bak.RUN_STAMP) date d'avant l'étape 7 ; le
# durcissement (étape 8) doit revenir à SA copie de référence, prise juste
# avant lui, sans défaire l'étape 7.
TMP_SD="$(mktemp)"
printf 'avant etape 7\n' > "$TMP_SD.bak.$RUN_STAMP"
printf 'Port 2222\n' > "$TMP_SD"
ok   "copie de référence prise"                        sshd_snapshot_durcissement "$TMP_SD"
printf 'Port 2222\nPasswordAuthentication no\n' > "$TMP_SD"
ok   "restauration réussie"                            sshd_restaurer_durcissement "$TMP_SD"
egal "version d'après l'étape 7 rétablie, pas celle d'avant" "Port 2222" "$(cat "$TMP_SD")"
egal "copie de l'exécution intacte"                    "avant etape 7" "$(cat "$TMP_SD.bak.$RUN_STAMP")"
rm -f "$TMP_SD" "$TMP_SD.bak.$RUN_STAMP" "$(sshd_ref_durcissement "$TMP_SD")"
ok   "fichier absent : absence notée"                  sshd_snapshot_durcissement "$TMP_SD"
ok   "marqueur d'absence présent"                      test -e "$(sshd_ref_durcissement "$TMP_SD").absent"
printf 'PasswordAuthentication no\n' > "$TMP_SD"
ok   "fichier créé par le durcissement : supprimé"     sshd_restaurer_durcissement "$TMP_SD"
ko   "le fichier n'existe plus"                        test -e "$TMP_SD"
ko   "marqueur retiré"                                 test -e "$(sshd_ref_durcissement "$TMP_SD").absent"
ko   "ni copie de référence ni marqueur : refus"       sshd_restaurer_durcissement "$TMP_SD"

echo "== v_port =="
ok "22 accepté"                          v_port 22
ok "65535 accepté"                       v_port 65535
ko "0 refusé"                            v_port 0
ko "65536 refusé"                        v_port 65536
ko "valeur non numérique refusée"        v_port deux-mille
ko "valeur vide refusée"                 v_port ""

################################################################################
# Clés SSH
################################################################################
# Les trois clés ci-dessous sont de VRAIES clés publiques (générées puis
# jetées) : les valider sur des chaînes inventées ne prouverait rien.
CLE_ED25519="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFJM/PVmU6wnjFPK/7WRI6hUDZFEMRDygr7hBQ3XU1zx jean@portable"
CLE_RSA="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCRBwVnwPS0sl0FLV1ZxzyHh920LVCvEdWoM56bYapfCimE2AuYO86N+ok3ovm3nhxRVbyyG6vKGAgWlQylMDd+jzfCrgEomnQJqdeIqv2ZvT+bT8zw85l3u+LITDeGNVJTGXwJzrjLWVYSedkYs1Tci6zlouU//OF5Jp+WYmEZK4M/zLZlXc+bssMvMTOk9C5m7onFDFButTdnIcKg3+CoCTQ2TCPY9ssAc/1d50eg5ivSg2O83uatnfu6rwbMGbjsDkaoO3Hg3pKQwiWP5g3IzwjI/LWNBTDMzL6vGD8E8jqoSOHU5vE/XjN/iKAl+7s+nU4tP45CLy51aScyLc9b admin@poste"
CLE_ECDSA="ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAEnSrXNITxpNG5sr+3tRA/MmadiXh3rCIcXn8QIj8tDXJ1sBRAhHdhMonZ70KzExCdVcmLy5h2LvTbkXESGiWfnyQB5qAChJpZKIsaY6Ig87lPRNEFSUHCWBEVZ1hNCYxfaJuHWaib0NFC1SwcSX0SqkrzFTWUKrRNovsvQdhiGIybvww== ops@nas"

echo "== ssh_holds_port / v_ssh_port (occupation du port, 22 compris) =="
SORTIE_SSHD='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
SORTIE_AUTRE='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("nginx",pid=2,fd=6))'
ok "port tenu par sshd : SSH le tient"       ssh_holds_port 22 "$SORTIE_SSHD"
ko "port tenu par nginx : SSH ne le tient pas" ssh_holds_port 22 "$SORTIE_AUTRE"
ko "aucun processus : SSH ne le tient pas"   ssh_holds_port 22 ""
# Analyse de « Listen » de ssh.socket : un port par ligne, sans motif compact.
egal "Listen « [::]:22 (Stream) » → 22"                 "22"      "$(printf '[::]:22 (Stream)\n' | ports_depuis_listen)"
egal "Listen « 0.0.0.0:2222 (Stream) » → 2222"          "2222"    "$(printf '0.0.0.0:2222 (Stream)\n' | ports_depuis_listen)"
egal "Listen « 22 (Stream) » (toutes interfaces) → 22"  "22"      "$(printf '22 (Stream)\n' | ports_depuis_listen)"
egal "Listen : socket Unix ignorée"                     ""        "$(printf '/run/sshd.sock (Stream)\n' | ports_depuis_listen)"
egal "Listen : plusieurs entrées"                       "22 2222" "$(printf '[::]:22 (Stream)\n0.0.0.0:2222 (Stream)\n' | ports_depuis_listen | tr '\n' ' ' | sed 's/ $//')"
# Branche « activation par socket » : c'est systemd (PID 1) qui tient le port
# pour ssh.socket. « systemctl » est doublé : socket active ou non, et sa liste
# Listen.
TMP_SC="$(mktemp -d)"
# shellcheck disable=SC2016
printf '#!/bin/bash\ncase "$1" in\n  is-active) [ -e "%s/socket-active" ] ;;\n  show) cat "%s/listen" ;;\n  *) exit 0 ;;\nesac\n' "$TMP_SC" "$TMP_SC" > "$TMP_SC/systemctl"
chmod 755 "$TMP_SC/systemctl"
SORTIE_SYSTEMD='LISTEN 0 4096 *:22 *:* users:(("systemd",pid=1,fd=40))'
# shellcheck disable=SC2030,SC2031
holds_avec_systemctl() { ( PATH="$TMP_SC:$PATH"; ssh_holds_port "$1" "$2" ); }
printf '[::]:22 (Stream)\n0.0.0.0:22 (Stream)\n' > "$TMP_SC/listen"
: > "$TMP_SC/socket-active"
ok "socket active sur 22, port 22 : SSH le tient"                 holds_avec_systemctl 22 "$SORTIE_SYSTEMD"
ko "socket active sur 22, port 2222 : SSH ne le tient pas"        holds_avec_systemctl 2222 "$SORTIE_SYSTEMD"
printf '[::]:2222 (Stream)\n' > "$TMP_SC/listen"
ko "socket sur 2222 : « 22 » n'est pas pris pour un suffixe"      holds_avec_systemctl 22 "$SORTIE_SYSTEMD"
ok "socket sur 2222 : le 2222 est tenu"                           holds_avec_systemctl 2222 "$SORTIE_SYSTEMD"
rm -f "$TMP_SC/socket-active"
ko "socket inactive : systemd en écoute n'est pas SSH"            holds_avec_systemctl 2222 "$SORTIE_SYSTEMD"
rm -rf "$TMP_SC"
# « ss » est remplacé par une doublure qui rejoue une sortie choisie : le port
# 22 doit subir le même contrôle que les autres ports. L'ancien code l'en
# exemptait : un autre service tenant le 22 était accepté, le redémarrage de
# sshd échouait ensuite.
TMP_SS="$(mktemp -d)"
# La doublure choisit sa sortie d'après le filtre « sport = :PORT » qu'elle
# reçoit, comme le vrai ss : une sortie ne concernant pas le port demandé n'est
# jamais rejouée. Sans fixture pour ce port, rien n'écoute.
# shellcheck disable=SC2016
printf '#!/bin/bash\nargs="$*"\nport="${args##*sport = :}"\nf="%s/sortie.$port"\n[ -r "$f" ] && cat "$f"\nexit 0\n' "$TMP_SS" > "$TMP_SS/ss"
chmod 755 "$TMP_SS/ss"
# La modification de PATH est volontairement limitée au sous-shell.
# shellcheck disable=SC2030,SC2031
v_ssh_port_avec_ss() { ( PATH="$TMP_SS:$PATH"; v_ssh_port "$1" ); }
printf '%s\n' "$SORTIE_AUTRE"                > "$TMP_SS/sortie.22"
printf '%s\n' "${SORTIE_AUTRE//:22 /:2222 }" > "$TMP_SS/sortie.2222"
ko "22 tenu par un autre service : refusé"    v_ssh_port_avec_ss 22
ko "2222 tenu par un autre service : refusé"  v_ssh_port_avec_ss 2222
rm -f "$TMP_SS/sortie.2222"
ok "2222 libre alors que 22 est occupé : accepté (filtre par port)" v_ssh_port_avec_ss 2222
printf '%s\n' "$SORTIE_SSHD"                 > "$TMP_SS/sortie.22"
printf '%s\n' "${SORTIE_SSHD//:22 /:2222 }"  > "$TMP_SS/sortie.2222"
ok "22 tenu par sshd : accepté"               v_ssh_port_avec_ss 22
ok "2222 tenu par sshd : accepté"             v_ssh_port_avec_ss 2222
rm -f "$TMP_SS/sortie.22" "$TMP_SS/sortie.2222"
ok "22 libre : accepté"                       v_ssh_port_avec_ss 22
ok "2222 libre : accepté"                     v_ssh_port_avec_ss 2222
rm -rf "$TMP_SS"

echo "== ssh_pubkey_b64_prefix (entête base64 déduite du type) =="
egal "ssh-ed25519"    "AAAAC3NzaC1lZDI1NTE5" "$(ssh_pubkey_b64_prefix ssh-ed25519)"
egal "ssh-rsa"        "AAAAB3NzaC1y"         "$(ssh_pubkey_b64_prefix ssh-rsa)"
egal "ecdsa-nistp521" "AAAAE2VjZHNhLXNoYTItbmlzdHA1" "$(ssh_pubkey_b64_prefix ecdsa-sha2-nistp521)"

echo "== is_ssh_pubkey =="
ok "clé ed25519 réelle"                  is_ssh_pubkey "$CLE_ED25519"
ok "clé rsa réelle"                      is_ssh_pubkey "$CLE_RSA"
ok "clé ecdsa réelle"                    is_ssh_pubkey "$CLE_ECDSA"
ok "sans commentaire"                    is_ssh_pubkey "${CLE_ED25519% *}"
ok "clé FIDO2 (sk-)"                     is_ssh_pubkey "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIKPXn1TfPmM6z0dGqk+8vXcCEplGCyMQ2m3rIcQ7WEc7 jean@yubikey"
ko "chaîne vide"                         is_ssh_pubkey ""
ko "texte quelconque"                    is_ssh_pubkey "bonjour tout le monde"
ko "clé DSA obsolète"                    is_ssh_pubkey "ssh-dss AAAAB3NzaC1kc3MAAACBAJ7bpKHLcMTBLcMTBLcMTBLcMTBLcMTBLc9k user@old"
ko "type seul, sans corps"               is_ssh_pubkey "ssh-ed25519"
ko "corps tronqué"                       is_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1 jean@portable"
ko "caractère interdit dans le corps"    is_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFJM/PVmU6wnjFPK!7WRI6hUDZFEMRDygr7hBQ3XU1zx x@y"
# Contrôle croisé : le type annoncé ne correspond pas au contenu du blob.
ko "type rsa sur un corps ed25519"       is_ssh_pubkey "ssh-rsa ${CLE_ED25519#* }"
# Les options en début de ligne (command=, no-pty...) ne sont pas gérées : une
# option mal recopiée passerait inaperçue.
ko "ligne préfixée d'options"            is_ssh_pubkey "command=\"/bin/true\" $CLE_ED25519"

echo "== v_pubkey (validateur de saisie) =="
ok "clé publique valide"                 v_pubkey "$CLE_ED25519"
ko "clé privée collée par erreur"        v_pubkey "-----BEGIN OPENSSH PRIVATE KEY-----"
ko "chemin de fichier au lieu d'une clé" v_pubkey "/home/jean/.ssh/id_ed25519.pub"
ko "clé DSA refusée explicitement"       v_pubkey "ssh-dss AAAAB3NzaC1kc3MAAACBAJ7bpKHLcMTBLcMTBLcMTBLcMTBLcMTBLc9k user@old"

echo "== ssh_pubkey_type / ssh_pubkey_body =="
egal "type ed25519"   "ssh-ed25519" "$(ssh_pubkey_type "$CLE_ED25519")"
egal "corps ed25519"  "AAAAC3NzaC1lZDI1NTE5AAAAIFJM/PVmU6wnjFPK/7WRI6hUDZFEMRDygr7hBQ3XU1zx" "$(ssh_pubkey_body "$CLE_ED25519")"

echo "== v_key_name =="
ok "id_ed25519"                          v_key_name id_ed25519
ok "cle-sauvegarde_2026"                 v_key_name cle-sauvegarde_2026
ko "chemin refusé"                       v_key_name ".ssh/id_ed25519"
ko "suffixe .pub refusé"                 v_key_name id_ed25519.pub
ko "tiret en tête refusé"                v_key_name -f
ko "espace refusé"                       v_key_name "ma cle"
ko "nom vide refusé"                     v_key_name ""
ko "plus de 64 caractères refusé"        v_key_name "$(printf 'a%.0s' $(seq 1 65))"

echo "== v_abs_dir =="
ok "/home/jean/.ssh"                     v_abs_dir /home/jean/.ssh
ok "/root/.ssh"                          v_abs_dir /root/.ssh
ko "chemin relatif refusé"               v_abs_dir .ssh
ko "remontée .. refusée"                 v_abs_dir /home/jean/../root/.ssh
ko "espace refusé"                       v_abs_dir "/home/jean/mes cles"

echo "== v_user_name / v_ssh_host / v_ssh_alias =="
ok "jdupont"                             v_user_name jdupont
ok "srv_admin"                           v_user_name srv_admin
ko "majuscule refusée"                   v_user_name Jean
ko "point refusé"                        v_user_name j.dupont
ko "plus de 32 caractères refusé"        v_user_name "$(printf 'u%.0s' $(seq 1 33))"
ok "nom d'hôte"                          v_ssh_host serveur.example.org
ok "adresse IPv4"                        v_ssh_host 192.168.1.10
ok "adresse IPv6"                        v_ssh_host 2606:4700:4700::1111
ko "espace refusé"                       v_ssh_host "mon serveur"
ko "hôte vide refusé"                    v_ssh_host ""
ok "alias simple"                        v_ssh_alias monserveur
ko "alias avec espace refusé"            v_ssh_alias "mon serveur"

echo "== authkeys_contains =="
TMP_AUTH="$(mktemp)"
printf '%s\n' "$CLE_ED25519" > "$TMP_AUTH"
ok "clé identique détectée"              authkeys_contains "$TMP_AUTH" "$CLE_ED25519"
# Le commentaire varie d'une machine à l'autre : la comparaison porte sur le
# corps de la clé, sinon la même clé serait ajoutée en double.
ok "même clé, autre commentaire"         authkeys_contains "$TMP_AUTH" "${CLE_ED25519% *} autre-commentaire"
ko "autre clé non détectée"              authkeys_contains "$TMP_AUTH" "$CLE_RSA"
ko "fichier inexistant"                  authkeys_contains "$TMP_AUTH-absent" "$CLE_ED25519"
printf '# %s\n' "$CLE_RSA" >> "$TMP_AUTH"
ko "clé en commentaire ignorée"          authkeys_contains "$TMP_AUTH" "$CLE_RSA"
rm -f "$TMP_AUTH"

echo "== ensure_trailing_newline =="
# Sans saut de ligne final, la clé suivante viendrait se coller à la dernière :
# les deux deviendraient invalides.
TMP_AUTH="$(mktemp)"
printf 'premiere-ligne' > "$TMP_AUTH"
ensure_trailing_newline "$TMP_AUTH"
egal "saut de ligne ajouté"              "1" "$(grep -c '^premiere-ligne$' "$TMP_AUTH")"
ensure_trailing_newline "$TMP_AUTH"
egal "pas de ligne vide en trop"         "1" "$(wc -l < "$TMP_AUTH" | tr -d ' ')"
: > "$TMP_AUTH"
ensure_trailing_newline "$TMP_AUTH"
egal "fichier vide laissé vide"          "0" "$(wc -c < "$TMP_AUTH" | tr -d ' ')"
rm -f "$TMP_AUTH"

echo "== str_len_utf8 (largeur des bannières en LC_ALL=C) =="
# En LC_ALL=C, ${#chaine} compte des octets : « É » en vaut deux et décalait le
# cadre des bannières d'une colonne par caractère accentué.
egal "ASCII"                             "5" "$(str_len_utf8 abcde)"
egal "accents comptés en caractères"     "9" "$(str_len_utf8 "ÉTAPE 1/8")"
egal "chaîne vide"                       "0" "$(str_len_utf8 "")"

echo "== ifupdown_file_mentions_iface / ifupdown_strip_iface_stanzas =="
# ifupdown applique TOUTES les strophes « iface » d'un même nom : la strophe
# « inet dhcp » de l'installateur doit disparaître quand on écrit la statique,
# sans toucher à lo ni aux autres cartes.
TMP_IFD="$(mktemp -d)"
TMP_IF="$TMP_IFD/interfaces"
cat > "$TMP_IF" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug ens18
iface ens18 inet dhcp
    # commentaire dans la strophe
    metric 100
iface ens18 inet6 static
    address 2001:db8::10/64
    gateway 2001:db8::1

auto ens19 ens18
iface ens19 inet static
    address 10.0.0.2/24
EOF
ok "ens18 mentionnée"                    ifupdown_file_mentions_iface "$TMP_IF" ens18
ok "ens19 mentionnée"                    ifupdown_file_mentions_iface "$TMP_IF" ens19
ko "ens20 absente"                       ifupdown_file_mentions_iface "$TMP_IF" ens20
ko "« ens1 » n'est pas un préfixe de ens18" ifupdown_file_mentions_iface "$TMP_IF" ens1
chmod 640 "$TMP_IF"
touch -d '2020-01-01 00:00:00' "$TMP_IF"
ok   "strip renvoie 0"                   ifupdown_strip_iface_stanzas "$TMP_IF" ens18
egal "droits conservés (réécriture atomique)" "640" "$(stat -c '%a' "$TMP_IF")"
ok   "horodatage rafraîchi (le contenu a changé)" test "$(stat -c '%Y' "$TMP_IF")" -gt 1600000000
egal "aucun temporaire laissé dans le répertoire" "interfaces" "$(ls -A "$TMP_IFD")"
egal "strophe iface ens18 inet retirée"  "0" "$(grep -c '^iface ens18 inet ' "$TMP_IF")"
egal "options de la strophe retirées"    "0" "$(grep -c 'metric 100' "$TMP_IF")"
egal "strophe inet6 de ens18 CONSERVÉE"  "1" "$(grep -c '^iface ens18 inet6 static' "$TMP_IF")"
egal "adresse IPv6 conservée"            "1" "$(grep -c '^    address 2001:db8::10/64' "$TMP_IF")"
egal "allow-hotplug ens18 retiré"        "0" "$(grep -c '^allow-hotplug' "$TMP_IF")"
egal "auto ens19 conservé, sans ens18"   "auto ens19" "$(grep -E '^auto ens' "$TMP_IF")"
egal "strophe lo intacte"                "1" "$(grep -c '^iface lo inet loopback' "$TMP_IF")"
egal "strophe ens19 intacte"             "1" "$(grep -c '^    address 10.0.0.2/24' "$TMP_IF")"
egal "ligne source conservée"            "1" "$(grep -c '^source ' "$TMP_IF")"
ko "ens18 n'est plus mentionnée (inet6 seule ne compte pas)" ifupdown_file_mentions_iface "$TMP_IF" ens18
ko "fichier inexistant refusé"           ifupdown_strip_iface_stanzas "$TMP_IF-absent" ens18
rm -rf "$TMP_IFD"

# Configuration IPv6 seule : sans strophe « inet », RIEN n'est retiré, pas même
# « allow-hotplug », sinon l'IPv6 cesserait de s'activer au démarrage.
TMP_IF="$(mktemp)"
printf 'allow-hotplug ens18\niface ens18 inet6 auto\n' > "$TMP_IF"
ko   "IPv6 seule : non « mentionnée »"     ifupdown_file_mentions_iface "$TMP_IF" ens18
ok   "IPv6 seule : strip renvoie 0"        ifupdown_strip_iface_stanzas "$TMP_IF" ens18
egal "IPv6 seule : allow-hotplug conservé" "1" "$(grep -c '^allow-hotplug ens18$' "$TMP_IF")"
egal "IPv6 seule : strophe inet6 conservée" "1" "$(grep -c '^iface ens18 inet6 auto$' "$TMP_IF")"
rm -f "$TMP_IF"

# Fichier atteint par un lien symbolique : le lien reste un lien, c'est sa cible
# qui est réécrite (un « mv » sur le lien l'aurait remplacé par un fichier).
TMP_IFD="$(mktemp -d)"
printf 'allow-hotplug ens18\niface ens18 inet dhcp\niface lo inet loopback\n' > "$TMP_IFD/interfaces"
ln -s "$TMP_IFD/interfaces" "$TMP_IFD/lien"
ok   "via un lien : strip renvoie 0"            ifupdown_strip_iface_stanzas "$TMP_IFD/lien" ens18
ok   "via un lien : le lien est resté un lien"  test -L "$TMP_IFD/lien"
egal "via un lien : cible réécrite"             "iface lo inet loopback" "$(cat "$TMP_IFD/interfaces")"
# shellcheck disable=SC2012
egal "via un lien : aucun temporaire laissé"    "interfaces lien" "$(ls -A "$TMP_IFD" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$TMP_IFD"

echo "== ecrire_etat_bascule / declarer_fichier_genere =="
# L'état partagé doit rester sourçable quelles que soient les valeurs (un nom de
# profil NetworkManager peut contenir une apostrophe) et être écrit en 600.
TMP_ETAT="$(mktemp -d)"
# shellcheck disable=SC2034
STATE_DIR="$TMP_ETAT" ROLLBACK_STATE="$TMP_ETAT/rollback.env" NET_GENERATED_LIST="$TMP_ETAT/gen.list" NET_BACKUP_MANIFEST="$TMP_ETAT/manifest"
# shellcheck disable=SC2034
NET_STACK="networkmanager" NET_NM_CONNECTION="Wired connection 1 (l'apostrophe)" NET_GENERATED_FILES="" NET_BACKUP_MODE=1
ok   "déclaration d'un fichier généré"     declarer_fichier_genere "$TMP_ETAT/10-ens18"
egal "journal disque alimenté"             "$TMP_ETAT/10-ens18" "$(cat "$TMP_ETAT/gen.list")"
egal "liste mémoire alimentée"             " $TMP_ETAT/10-ens18" "$NET_GENERATED_FILES"
ok   "état écrit"                          ecrire_etat_bascule
egal "état en 600"                         "600" "$(stat -c '%a' "$TMP_ETAT/rollback.env")"
egal "apostrophe relue à l'identique"      "Wired connection 1 (l'apostrophe)" "$(bash -c '. "$1"; printf %s "$NET_NM_CONNECTION"' _ "$TMP_ETAT/rollback.env")"
egal "domaines de test relus"              "example.org debian.org cloudflare.com" "$(bash -c '. "$1"; printf %s "$TEST_DOMAINS"' _ "$TMP_ETAT/rollback.env")"
egal "journal des fichiers générés référencé" "$TMP_ETAT/gen.list" "$(bash -c '. "$1"; printf %s "$GENERATED_LIST"' _ "$TMP_ETAT/rollback.env")"
egal "aucun fichier temporaire laissé"     "0" "$(find "$TMP_ETAT" -name 'rollback.env.*' | wc -l | tr -d ' ')"
# shellcheck disable=SC2034
NET_BACKUP_MODE=0
rm -rf "$TMP_ETAT"

echo "== etat_bascule_sans_ecriture / bascule_ip_en_attente =="
TMP_SE="$(mktemp -d)"
# Lues par bascule_ip_en_attente.
# shellcheck disable=SC2034
STATE_DIR="$TMP_SE" ROLLBACK_STATE="$TMP_SE/rollback.env"
# shellcheck disable=SC2034
CONFIRMED_FLAG="$TMP_SE/confirmed" RUNTIME_CONFIRMED_FLAG="$TMP_SE/confirmed.run"
etat_test() {  # fichier, manifeste, liste générée, fichiers générés, NM modifié, CIDR
  printf 'NET_CIDR=%q\nBACKUP_MANIFEST=%q\nGENERATED_LIST=%q\nNET_GENERATED_FILES=%q\nNET_NM_MODIFIED=%q\n' \
    "$6" "$2" "$3" "$4" "$5" > "$1"
}
: > "$TMP_SE/manifest.vide"
: > "$TMP_SE/gen.vide"
printf '%s\t%s\n' /etc/x /etc/x.bak > "$TMP_SE/manifest.plein"
printf '/etc/y\n' > "$TMP_SE/gen.plein"
etat_test "$TMP_SE/vide"       "$TMP_SE/manifest.vide"  "$TMP_SE/gen.vide"  ""       0 10.0.0.2/24
etat_test "$TMP_SE/sans-manif" "$TMP_SE/inexistant"     "$TMP_SE/gen.vide"  ""       0 10.0.0.3/24
etat_test "$TMP_SE/sauvegarde" "$TMP_SE/manifest.plein" "$TMP_SE/gen.vide"  ""       0 10.0.0.4/24
etat_test "$TMP_SE/genere"     "$TMP_SE/manifest.vide"  "$TMP_SE/gen.plein" ""       0 10.0.0.5/24
etat_test "$TMP_SE/liste-etat" "$TMP_SE/manifest.vide"  "$TMP_SE/gen.vide"  "/etc/z" 0 10.0.0.6/24
etat_test "$TMP_SE/nm"         "$TMP_SE/manifest.vide"  "$TMP_SE/gen.vide"  ""       1 10.0.0.7/24
ok "manifeste et liste vides : sans écriture"        etat_bascule_sans_ecriture "$TMP_SE/vide"
ok "manifeste inexistant : sans écriture"            etat_bascule_sans_ecriture "$TMP_SE/sans-manif"
ko "une sauvegarde : écrit"                          etat_bascule_sans_ecriture "$TMP_SE/sauvegarde"
ko "un fichier généré (journal) : écrit"             etat_bascule_sans_ecriture "$TMP_SE/genere"
ko "un fichier généré (état) : écrit"                etat_bascule_sans_ecriture "$TMP_SE/liste-etat"
ko "profil NetworkManager modifié : écrit"           etat_bascule_sans_ecriture "$TMP_SE/nm"
ko "fichier d'état absent : refusé"                  etat_bascule_sans_ecriture "$TMP_SE/nexiste-pas"
# État d'une version antérieure (sans NET_NM_MODIFIED) : tenu pour écrit.
printf 'NET_CIDR=10.0.0.8/24\nBACKUP_MANIFEST=%q\n' "$TMP_SE/manifest.vide" > "$TMP_SE/ancien"
ko "état d'une version antérieure : tenu pour écrit" etat_bascule_sans_ecriture "$TMP_SE/ancien"
# Un état sans écriture ne surveille rien, sauf s'il a mis de côté un changement
# précédent (.precedent) : c'est alors celui-ci qui est en attente.
cp "$TMP_SE/sauvegarde" "$ROLLBACK_STATE"
ok "état écrit, non confirmé : en attente"           bascule_ip_en_attente
: > "$CONFIRMED_FLAG"
ko "état écrit, confirmé : pas en attente"           bascule_ip_en_attente
rm -f "$CONFIRMED_FLAG"
cp "$TMP_SE/vide" "$ROLLBACK_STATE"
ko "sans écriture, rien mis de côté : pas en attente" bascule_ip_en_attente
cp "$TMP_SE/sauvegarde" "$TMP_SE/rollback.env.precedent"
ok "sans écriture, précédent mis de côté : en attente" bascule_ip_en_attente
rm -rf "$TMP_SE"

echo "== retablir_etat_precedent / retablir_etat_ssh_precedent (échecs propagés) =="
# Un rétablissement qui échoue (état impossible à remettre en place, garde-fou
# non réactivable) doit être signalé à l'appelant, qui n'annonce alors pas le
# changement précédent comme surveillé.
TMP_RP="$(mktemp -d)"
mkdir -p "$TMP_RP/bin" "$TMP_RP/etat"
# shellcheck disable=SC2016
printf '#!/bin/bash\ncase "$1" in\n  enable) [ ! -e "%s/enable-echoue" ] ;;\n  *) exit 0 ;;\nesac\n' "$TMP_RP" > "$TMP_RP/bin/systemctl"
chmod 755 "$TMP_RP/bin/systemctl"
# Lues par les fonctions testées.
# shellcheck disable=SC2034
STATE_DIR="$TMP_RP/etat" ROLLBACK_STATE="$TMP_RP/etat/rollback.env" SSH_AUTH_STATE="$TMP_RP/etat/ssh-auth.env"
# shellcheck disable=SC2034
NET_PREVIOUS_PENDING=1 NET_PRECEDENT_RETABLI=1
retablir_avec_systemctl() {  # code retour de la fonction ; le drapeau est relevé dans un fichier
  (
    # shellcheck disable=SC2030,SC2031
    PATH="$TMP_RP/bin:$PATH"
    retablir_etat_precedent
    rc=$?
    printf '%s' "$NET_PRECEDENT_RETABLI" > "$TMP_RP/drapeau"
    exit "$rc"
  )
}
printf 'NET_CIDR=10.0.0.1/24\n' > "$TMP_RP/etat/rollback.env.precedent"
ok   "état précédent rétabli : succès"                      retablir_avec_systemctl
ok   "état précédent en place"                              grep -q '^NET_CIDR=10.0.0.1/24$' "$ROLLBACK_STATE"
ko   "état mis de côté consommé"                            test -e "$TMP_RP/etat/rollback.env.precedent"
egal "succès : drapeau intact"                              "1" "$(cat "$TMP_RP/drapeau")"
printf 'NET_CIDR=10.0.0.1/24\n' > "$TMP_RP/etat/rollback.env.precedent"
: > "$TMP_RP/enable-echoue"
ko   "garde-fou non réactivable : échec propagé"            retablir_avec_systemctl
egal "garde-fou non réactivable : drapeau à 0"              "0" "$(cat "$TMP_RP/drapeau")"
rm -f "$TMP_RP/enable-echoue"
printf 'NET_CIDR=10.0.0.1/24\n' > "$TMP_RP/etat/rollback.env.precedent"
ROLLBACK_STATE="$TMP_RP/inexistant/rollback.env"
ko   "déplacement impossible : échec propagé"               retablir_avec_systemctl
ok   "déplacement impossible : état mis de côté conservé"   test -e "$TMP_RP/etat/rollback.env.precedent"
egal "déplacement impossible : drapeau à 0"                 "0" "$(cat "$TMP_RP/drapeau")"
# shellcheck disable=SC2034
NET_PREVIOUS_PENDING=0
ok   "aucun changement précédent : rien à faire, succès"    retablir_avec_systemctl
printf 'SSHD_TARGET=/etc/ssh/sshd_config\n' > "$TMP_RP/etat/ssh-auth.env.precedent"
ok   "état SSH précédent rétabli : succès"                  retablir_etat_ssh_precedent
ok   "état SSH précédent en place"                          grep -q '^SSHD_TARGET=' "$SSH_AUTH_STATE"
ok   "aucun état SSH mis de côté : succès"                  retablir_etat_ssh_precedent
printf 'SSHD_TARGET=/etc/ssh/sshd_config\n' > "$TMP_RP/etat/ssh-auth.env.precedent"
SSH_AUTH_STATE="$TMP_RP/inexistant/ssh-auth.env"
ko   "déplacement SSH impossible : échec propagé"           retablir_etat_ssh_precedent
rm -rf "$TMP_RP"

echo "== annuler_ecriture_reseau =="
# Retire les fichiers générés, restaure ceux du manifeste réseau, et renvoie 1
# si une restauration échoue (le garde-fou de démarrage est alors conservé).
TMP_ANN="$(mktemp -d)"
printf 'dhcp\n' > "$TMP_ANN/interfaces"
cp "$TMP_ANN/interfaces" "$TMP_ANN/interfaces.bak"
printf 'static\n' > "$TMP_ANN/interfaces"
printf 'genere\n' > "$TMP_ANN/10-ens18"
printf '%s\t%s\n' "$TMP_ANN/interfaces" "$TMP_ANN/interfaces.bak" > "$TMP_ANN/manifest"
# shellcheck disable=SC2034
NET_BACKUP_MANIFEST="$TMP_ANN/manifest" NET_GENERATED_FILES="$TMP_ANN/10-ens18" NET_STACK="ifupdown" DNS_METHOD=""
ok   "annulation réussie"                    annuler_ecriture_reseau
ko   "fichier généré retiré"                 test -e "$TMP_ANN/10-ens18"
egal "fichier d'origine restauré"            "dhcp" "$(cat "$TMP_ANN/interfaces")"
printf '%s\t%s\n' "$TMP_ANN/interfaces" "$TMP_ANN/absent.bak" > "$TMP_ANN/manifest"
ko   "sauvegarde absente : échec signalé"    annuler_ecriture_reseau
egal "fichier laissé intact malgré l'échec"  "dhcp" "$(cat "$TMP_ANN/interfaces")"
# Un fichier à la fois « généré » ET sauvegardé (préexistant réécrit) doit être
# RESTAURÉ, pas supprimé.
printf 'ancien\n' > "$TMP_ANN/reecrit"
cp "$TMP_ANN/reecrit" "$TMP_ANN/reecrit.bak"
printf 'nouveau\n' > "$TMP_ANN/reecrit"
printf '%s\t%s\n' "$TMP_ANN/reecrit" "$TMP_ANN/reecrit.bak" > "$TMP_ANN/manifest"
# shellcheck disable=SC2034
NET_GENERATED_FILES="$TMP_ANN/reecrit"
ok   "généré et sauvegardé : annulation réussie" annuler_ecriture_reseau
egal "généré et sauvegardé : restauré, pas supprimé" "ancien" "$(cat "$TMP_ANN/reecrit")"
# Manifeste illisible : sans lui, impossible de distinguer un fichier créé d'un
# fichier préexistant réécrit ; l'annulation refuse et ne supprime rien.
printf 'genere\n' > "$TMP_ANN/10-ens18"
# shellcheck disable=SC2034
NET_GENERATED_FILES="$TMP_ANN/10-ens18" NET_BACKUP_MANIFEST="$TMP_ANN/manifest-absent"
ko   "manifeste illisible : annulation refusée" annuler_ecriture_reseau
ok   "manifeste illisible : rien supprimé"      test -e "$TMP_ANN/10-ens18"
rm -rf "$TMP_ANN"

echo "== ask_input (entrée standard fermée) =="
# Sans terminal, une saisie obligatoire sans valeur par défaut acceptable ne
# doit pas boucler indéfiniment : le script s'arrête (code non nul). Le sous-
# shell isole ce « exit » de la suite de tests.
ask_input_eof() { ( ask_input "Valeur" "${1:-}" "${2:-}" "${3:-no}" ) </dev/null; }
ko "sans défaut : arrêt"                 ask_input_eof "" v_port
ko "défaut refusé par le validateur : arrêt" ask_input_eof "abc" v_port
ok "défaut valide : accepté"             ask_input_eof "22" v_port
ok "vide autorisé : accepté"             ask_input_eof "" "" yes
# Une dernière ligne SANS saut de ligne final fait échouer « read » alors que la
# valeur a bien été lue : elle doit primer sur le défaut.
egal "ligne partielle conservée"         "2222" "$(printf '2222' | ( ask_input "Valeur" "22" v_port >/dev/null 2>&1 && printf '%s' "$ASK_VALUE" ))"
egal "ligne partielle « o » = oui"       "oui"  "$(printf 'o' | ( ask_yes_no "Q" "n" >/dev/null 2>&1 && echo oui || echo non ))"

echo "== appliquer_pile (outil généré ip-fixe-commun) =="
# La bibliothèque des outils de bascule est un heredoc du script : on l'en
# extrait pour la charger telle qu'elle sera installée. Les commandes système
# sont remplacées par des doublures qui n'agissent pas et notent leurs appels.
TMP_COMMON="$(mktemp)"
TMP_BIN="$(mktemp -d)"
awk "/<<'COMMON'/ { on = 1; next } /^COMMON\$/ { on = 0 } on" "$CIBLE" > "$TMP_COMMON"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/appels"\nexit 4\n' "$TMP_BIN" > "$TMP_BIN/nmcli"
printf '#!/bin/bash\nexit 0\n' > "$TMP_BIN/logger"
chmod 755 "$TMP_BIN/nmcli" "$TMP_BIN/logger"
appliquer_pile_nm() {  # $1 = pile, $2 = profil NetworkManager enregistré dans l'état
  (
    # shellcheck disable=SC2030,SC2031
    PATH="$TMP_BIN:$PATH"
    # Lues par la bibliothèque chargée ci-dessous.
    # shellcheck disable=SC2034
    NET_STACK="$1"
    # shellcheck disable=SC2034
    NET_NM_CONNECTION="$2"
    # shellcheck source=/dev/null
    . "$TMP_COMMON"
    appliquer_pile
  )
}
ok "bibliothèque extraite et chargeable"       bash -n "$TMP_COMMON"
# État publié avant write_nm_config (profil encore vide) : rien n'a été écrit,
# la réapplication est un cas sans opération. Un « nmcli connection up "" »
# échouerait et le retour arrière se tiendrait pour incomplet à chaque démarrage.
rm -f "$TMP_BIN/appels"
ok "profil vide : aucune opération, succès"    appliquer_pile_nm networkmanager ""
ko "profil vide : nmcli n'est pas appelé"      test -e "$TMP_BIN/appels"
ko "profil renseigné : échec de nmcli propagé" appliquer_pile_nm networkmanager "0f1e2d3c"
egal "profil renseigné : « connection up UUID »" "connection up 0f1e2d3c" "$(cat "$TMP_BIN/appels" 2>/dev/null)"
ko "pile inconnue refusée"                     appliquer_pile_nm inconnue ""
# charger_etat : un état sans écriture se rabat sur le changement précédent mis
# de côté (.precedent), le seul à savoir revenir à la configuration d'origine.
TMP_CE="$(mktemp -d)"
: > "$TMP_CE/manifest.vide"
printf '%s\t%s\n' /etc/x /etc/x.bak > "$TMP_CE/manifest.plein"
printf 'NET_CIDR=%q\nBACKUP_MANIFEST=%q\nNET_NM_MODIFIED=0\n' 10.0.0.9/24 "$TMP_CE/manifest.vide"  > "$TMP_CE/vide"
printf 'NET_CIDR=%q\nBACKUP_MANIFEST=%q\nNET_NM_MODIFIED=0\n' 10.0.0.1/24 "$TMP_CE/manifest.plein" > "$TMP_CE/plein"
cidr_charge() {  # $1 = état actif, $2 = état mis de côté (vide : aucun)
  (
    # shellcheck disable=SC2030,SC2031
    PATH="$TMP_BIN:$PATH"
    # Les outils partent d'un environnement vierge (systemd) : les globales du
    # script chargé par ces tests ne doivent pas s'y glisser.
    unset BACKUP_MANIFEST GENERATED_LIST NET_GENERATED_FILES NET_NM_MODIFIED
    # shellcheck source=/dev/null
    . "$TMP_COMMON"
    STATE_FILE="$TMP_CE/rollback.env"
    cp "$1" "$STATE_FILE"
    rm -f "$STATE_FILE.precedent"
    [ -z "$2" ] || cp "$2" "$STATE_FILE.precedent"
    charger_etat >/dev/null 2>&1 || exit 1
    printf '%s' "${NET_CIDR:-}"
  )
}
egal "état écrit : lu tel quel"                          "10.0.0.1/24" "$(cidr_charge "$TMP_CE/plein" "")"
egal "état écrit, précédent présent : lu tel quel"       "10.0.0.1/24" "$(cidr_charge "$TMP_CE/plein" "$TMP_CE/vide")"
egal "sans écriture, aucun précédent : lu tel quel"      "10.0.0.9/24" "$(cidr_charge "$TMP_CE/vide" "")"
egal "sans écriture, précédent présent : précédent repris" "10.0.0.1/24" "$(cidr_charge "$TMP_CE/vide" "$TMP_CE/plein")"
rm -rf "$TMP_CE"

echo "== ip-fixe-rollback (outil généré) : état sans écriture, état avec écriture =="
# L'outil est extrait de son heredoc ; sa bibliothèque et ses chemins système
# sont redirigés vers un répertoire temporaire, et ses commandes système sont
# doublées (elles notent leurs appels). Un état sans écriture ne doit rien
# restaurer ni réappliquer (ifdown/ifup perturberaient un réseau intact) : il
# retire le garde-fou et s'arrête. Un état avec écriture restaure puis réapplique.
TMP_RB="$(mktemp -d)"
mkdir -p "$TMP_RB/bin"
sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$TMP_RB/rollback.env\"|" "$TMP_COMMON" > "$TMP_RB/commun"
awk "/ip-fixe-rollback 755 bash <<'ROLLBACK'/ { on = 1; next } /^ROLLBACK\$/ { on = 0 } on" "$CIBLE" |
  sed -e "s|^\. /usr/local/sbin/ip-fixe-commun\$|. $TMP_RB/commun|" \
      -e "s|/etc/systemd/system/ip-fixe-watchdog.service|$TMP_RB/watchdog.service|g" > "$TMP_RB/rollback"
ok "outil extrait et analysable"                        bash -n "$TMP_RB/rollback"
for c in systemctl logger ifdown ifup ip dhcpcd dhclient pkill sleep ping getent networkctl nmcli resolvconf; do
  # shellcheck disable=SC2016
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/appels"\nexit 0\n' "$c" "$TMP_RB" > "$TMP_RB/bin/$c"
  chmod 755 "$TMP_RB/bin/$c"
done
rollback_test() {  # $1 = état à charger
  cp "$1" "$TMP_RB/rollback.env"
  rm -f "$TMP_RB/appels"
  : > "$TMP_RB/watchdog.service"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$TMP_RB/bin:$PATH"; bash "$TMP_RB/rollback" >/dev/null 2>&1 )
}
: > "$TMP_RB/manifest.vide"
printf 'NET_STACK=ifupdown\nNET_IFACE=ens18\nNET_GATEWAY=10.0.0.1\nBACKUP_MANIFEST=%q\nNET_NM_MODIFIED=0\nCONFIRMED_FLAG=%q\nRUNTIME_CONFIRMED_FLAG=%q\n' \
  "$TMP_RB/manifest.vide" "$TMP_RB/confirmed" "$TMP_RB/confirmed.run" > "$TMP_RB/etat.vide"
printf 'dhcp\n' > "$TMP_RB/interfaces.bak"
printf 'static\n' > "$TMP_RB/interfaces"
printf '%s\t%s\n' "$TMP_RB/interfaces" "$TMP_RB/interfaces.bak" > "$TMP_RB/manifest.plein"
sed -e "s|manifest.vide|manifest.plein|" "$TMP_RB/etat.vide" > "$TMP_RB/etat.plein"
ok   "sans écriture : succès"                           rollback_test "$TMP_RB/etat.vide"
ko   "sans écriture : ni ifdown, ni ifup, ni ip"        grep -qE '^(ifdown|ifup|ip) ' "$TMP_RB/appels"
ok   "sans écriture : garde-fou désactivé"              grep -q '^systemctl disable ip-fixe-watchdog.service' "$TMP_RB/appels"
ko   "sans écriture : unité du garde-fou retirée"       test -e "$TMP_RB/watchdog.service"
ok   "avec écriture : succès"                           rollback_test "$TMP_RB/etat.plein"
egal "avec écriture : fichier restauré"                 "dhcp" "$(cat "$TMP_RB/interfaces")"
ok   "avec écriture : pile réappliquée (ifup)"          grep -q '^ifup ens18' "$TMP_RB/appels"
ko   "avec écriture : unité du garde-fou retirée aussi" test -e "$TMP_RB/watchdog.service"
rm -rf "$TMP_RB"

echo "== ip-fixe-confirmer / ssh-cles-confirmer (drapeau écrit avant désarmement) =="
# Sans drapeau écrit, rien n'atteste la confirmation : la minuterie et les
# garde-fous doivent rester en place et l'outil échouer.
TMP_CF="$(mktemp -d)"
mkdir -p "$TMP_CF/bin" "$TMP_CF/etat"
for c in systemctl logger; do
  # shellcheck disable=SC2016
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/appels"\nexit 0\n' "$c" "$TMP_CF" > "$TMP_CF/bin/$c"
  chmod 755 "$TMP_CF/bin/$c"
done
sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$TMP_CF/etat/rollback.env\"|" "$TMP_COMMON" > "$TMP_CF/commun"
awk "/ip-fixe-confirmer 755 bash <<'CONFIRM'/ { on = 1; next } /^CONFIRM\$/ { on = 0 } on" "$CIBLE" |
  sed -e "s|^\. /usr/local/sbin/ip-fixe-commun\$|. $TMP_CF/commun|" \
      -e "s|/etc/systemd/system/ip-fixe-watchdog.service|$TMP_CF/watchdog.service|g" > "$TMP_CF/ip-fixe-confirmer"
awk "/ssh-cles-confirmer 755 bash <<'CONFIRM'/ { on = 1; next } /^CONFIRM\$/ { on = 0 } on" "$CIBLE" |
  sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$TMP_CF/etat/ssh-auth.env\"|" \
      -e "s|^FLAG=.*|FLAG=\"$TMP_CF/etat/ssh-auth-confirmed\"|" > "$TMP_CF/ssh-cles-confirmer"
ok "ip-fixe-confirmer extrait et analysable"   bash -n "$TMP_CF/ip-fixe-confirmer"
ok "ssh-cles-confirmer extrait et analysable"  bash -n "$TMP_CF/ssh-cles-confirmer"
printf 'x\n' > "$TMP_CF/pas-un-dossier"
etat_confirm() {  # $1 = drapeau persistant
  printf 'NET_STACK=ifupdown\nNET_IFACE=ens18\nNET_CIDR=10.0.0.2/24\nBACKUP_MANIFEST=%q\nNET_NM_MODIFIED=0\nCONFIRMED_FLAG=%q\nRUNTIME_CONFIRMED_FLAG=%q\n' \
    "$TMP_CF/etat/manifest" "$1" "$TMP_CF/etat/confirmed.run" > "$TMP_CF/etat/rollback.env"
  printf 'SSHD_TARGET=/etc/ssh/sshd_config\nCONFIRMED_FLAG=%q\n' "$1" > "$TMP_CF/etat/ssh-auth.env"
}
outil_cf() {  # $1 = outil
  rm -f "$TMP_CF/appels"
  # shellcheck disable=SC2030,SC2031
  ( PATH="$TMP_CF/bin:$PATH"; bash "$TMP_CF/$1" >/dev/null 2>&1 )
}
etat_confirm "$TMP_CF/pas-un-dossier/sous/confirmed"
ko "ip-fixe-confirmer : drapeau inscriptible impossible → échec"     outil_cf ip-fixe-confirmer
ko "ip-fixe-confirmer : minuterie et garde-fou conservés"           grep -q '^systemctl stop\|^systemctl disable' "$TMP_CF/appels"
ko "ssh-cles-confirmer : drapeau inscriptible impossible → échec"    outil_cf ssh-cles-confirmer
ko "ssh-cles-confirmer : minuterie conservée"                        grep -q '^systemctl stop' "$TMP_CF/appels"
etat_confirm "$TMP_CF/etat/confirmed"
ok "ip-fixe-confirmer : succès"                                      outil_cf ip-fixe-confirmer
ok "ip-fixe-confirmer : drapeau écrit"                               test -e "$TMP_CF/etat/confirmed"
ok "ip-fixe-confirmer : minuterie désarmée"                          grep -q '^systemctl stop ip-fixe-rollback.timer' "$TMP_CF/appels"
rm -f "$TMP_CF/etat/confirmed"
ok "ssh-cles-confirmer : succès"                                     outil_cf ssh-cles-confirmer
ok "ssh-cles-confirmer : drapeau écrit"                              test -e "$TMP_CF/etat/confirmed"
ok "ssh-cles-confirmer : minuterie désarmée"                         grep -q '^systemctl stop ssh-cles-rollback.timer' "$TMP_CF/appels"
rm -rf "$TMP_CF"

echo "== ssh-cles-rollback (outil généré) : repli sur la copie de référence =="
# sshd est doublé : « -t » échoue à la demande (configuration invalide après la
# réécriture) et « -T » annonce le mot de passe accepté. Le repli doit remettre la
# copie de référence en place (temporaire puis « mv », rien de tronqué), ou
# supprimer un fichier qui n'existait pas avant le durcissement (marqueur).
TMP_SR="$(mktemp -d)"
mkdir -p "$TMP_SR/bin" "$TMP_SR/etat" "$TMP_SR/ssh"
for c in systemctl logger; do
  printf '#!/bin/bash\nexit 0\n' > "$TMP_SR/bin/$c"
  chmod 755 "$TMP_SR/bin/$c"
done
# shellcheck disable=SC2016
printf '#!/bin/bash\ncase "$1" in\n  -t) [ ! -e "%s/sshd-invalide" ] ;;\n  -T) cat "%s/sshd-T" ;;\n  *) exit 0 ;;\nesac\n' "$TMP_SR" "$TMP_SR" > "$TMP_SR/bin/sshd"
chmod 755 "$TMP_SR/bin/sshd"
printf 'passwordauthentication yes\n' > "$TMP_SR/sshd-T"
awk "/ssh-cles-rollback 755 bash <<'ROLLBACK'/ { on = 1; next } /^ROLLBACK\$/ { on = 0 } on" "$CIBLE" |
  sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$TMP_SR/etat/ssh-auth.env\"|" > "$TMP_SR/ssh-cles-rollback"
ok "ssh-cles-rollback extrait et analysable"   bash -n "$TMP_SR/ssh-cles-rollback"
CIBLE_SR="$TMP_SR/ssh/99-personnalisation.conf"
REF_SR="$CIBLE_SR.avant-durcissement.test"
printf 'SSHD_TARGET=%q\nSSHD_TARGET_BACKUP=%q\nCONFIRMED_FLAG=%q\n' "$CIBLE_SR" "$REF_SR" "$TMP_SR/etat/confirmed" > "$TMP_SR/etat/ssh-auth.env"
rollback_ssh() {
  # shellcheck disable=SC2030,SC2031
  ( PATH="$TMP_SR/bin:$PATH"; bash "$TMP_SR/ssh-cles-rollback" >/dev/null 2>&1 )
}
# Configuration valide après réécriture : directives posées, pas de repli.
printf 'Port 2222\nPasswordAuthentication no\n' > "$CIBLE_SR"
printf 'Port 2222\n' > "$REF_SR"
ok   "configuration valide : succès"                         rollback_ssh
egal "configuration valide : mot de passe réactivé dans le fichier" "1" "$(grep -c '^PasswordAuthentication yes$' "$CIBLE_SR")"
egal "configuration valide : copie de référence intacte"      "Port 2222" "$(cat "$REF_SR")"
# Configuration invalide : copie de référence remise en place.
printf 'Port 2222\nPasswordAuthentication no\n' > "$CIBLE_SR"
: > "$TMP_SR/sshd-invalide"
ok   "configuration invalide : succès"                        rollback_ssh
egal "configuration invalide : copie de référence remise"     "Port 2222" "$(cat "$CIBLE_SR")"
egal "configuration invalide : aucun temporaire laissé"       "0" "$(find "$TMP_SR/ssh" -name '.*' | wc -l)"
# Fichier absent avant le durcissement (marqueur) : supprimé, pas restauré.
rm -f "$REF_SR" "$CIBLE_SR"
: > "$REF_SR.absent"
ok   "marqueur d'absence : succès"                            rollback_ssh
ko   "marqueur d'absence : fichier créé par le durcissement supprimé" test -e "$CIBLE_SR"
# Le mot de passe reste refusé d'après « sshd -T » : le filet n'a pas joué, l'outil
# le dit par son code de retour (lu par reactiver_mot_de_passe_si_orphelin).
rm -f "$TMP_SR/sshd-invalide"
printf 'passwordauthentication no\n' > "$TMP_SR/sshd-T"
ko   "mot de passe toujours refusé : échec propagé"           rollback_ssh
rm -rf "$TMP_SR"
rm -rf "$TMP_COMMON" "$TMP_BIN"

echo "== run_cmd (propagation du code retour) =="
# Non-régression : bash remet $? à 0 après un « if commande ; then » dont la
# condition échoue. Une capture naïve du code retour ferait passer un échec pour
# un succès, et le récapitulatif final annoncerait une étape réussie à tort.
ok "succès propagé"                      run_cmd "test vrai" true
TESTS=$((TESTS + 1))
RC_OBTENU=0
# « o » : on demande à run_cmd de poursuivre, pour éprouver le chemin de retour
# (et non le chemin d'arrêt du script).
printf 'o\n' | run_cmd "test code 42" bash -c 'exit 42' >/dev/null 2>&1 || RC_OBTENU=$?
egal "code retour exact propagé"         "42" "$RC_OBTENU"

echo ""
echo "=========================================="
if (( ECHECS == 0 )); then
  echo "  ✓ $TESTS tests, 0 échec"
  echo "=========================================="
  exit 0
fi
echo "  ✗ $TESTS tests, $ECHECS échec(s)"
echo "=========================================="
exit 1
