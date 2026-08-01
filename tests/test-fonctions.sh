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
