# Script-de-personnalisation-post-installation-pour-serveur-Linux
Script Bash d'automatisation post-installation pour serveur Debian 13 (Trixie). Configure rapidement les essentiels : clavier FR, IP fixe avec vérification et retour automatique au DHCP, coloration syntaxique, création d'utilisateur sudo et sécurisation SSH. Idéal pour transformer une installation minimale en environnement prêt à l'emploi.

---

# Version Française

## 🚀 Script de Post-Installation Debian 13 (Trixie)

Ce script Bash est conçu pour automatiser la configuration initiale d'un serveur **Debian 13 (Trixie)** fraîchement installé. Il transforme une installation minimale en un environnement de travail sécurisé, ergonomique et prêt pour la production en quelques minutes.

### 🛠 Fonctionnalités

Le script traite les sept étapes essentielles de la mise en service d'un serveur :

1. **Confort visuel** : Activation de la coloration syntaxique pour l'utilisateur `root` (Prompt PS1, `ls`, `grep`).
2. **Mise à jour système** : Actualisation complète des paquets (`apt-get update` & `upgrade`), en mode strictement non interactif.
3. **Localisation** : Configuration du clavier en français (**AZERTY**).
4. **Identité** : Personnalisation du nom d'hôte (hostname), avec validation du format.
5. **Réseau statique** : Configuration d'une IP fixe **dans le gestionnaire réseau déjà en place**, avec vérification préalable et retour automatique au DHCP en cas de problème.
6. **Sécurité Utilisateur** : Création d'un utilisateur standard avec privilèges `sudo` pour éviter l'usage de root.
7. **Durcissement SSH** : Changement du port d'écoute (compatible avec l'activation par socket de Debian 13) et configuration de l'accès root.

### 🛡 Comment le changement d'IP est sécurisé

Le passage en IP fixe est l'opération la plus risquée d'un post-installation : une simple faute de frappe peut rendre un serveur distant définitivement injoignable. Le script applique donc cinq garde-fous.

| Garde-fou | Ce qu'il évite |
|---|---|
| **Détection du gestionnaire réseau** (`ifupdown`, `systemd-networkd` ou `NetworkManager`) et écriture **dans celui-ci** | Aucune migration de pile : c'est la première cause de serveur hors ligne après un post-installation |
| **Validation des saisies** : interface existante, CIDR correct, adresse ni réseau ni broadcast, passerelle dans le bon sous-réseau, détection de **conflit d'adresse** sur le réseau | Une IP déjà utilisée ou une passerelle hors sous-réseau |
| **Test à chaud non destructif** : l'adresse est ajoutée en **secondaire** (l'adresse DHCP reste active), puis on teste la passerelle, la résolution DNS et le ping de `example.org`, `debian.org` et `cloudflare.com` | La session SSH n'est **jamais** coupée pendant la vérification, et rien n'est écrit tant que les tests échouent |
| **Bascule en toute fin de script**, exécutée de façon détachée via `systemd-run` | La coupure SSH ne peut plus interrompre l'opération à mi-chemin |
| **Retour automatique au DHCP** : une minuterie systemd restaure la configuration précédente sans confirmation de votre part, et un service de démarrage fait de même si le serveur ne répond pas après un redémarrage | Un serveur injoignable nécessitant un déplacement physique ou une console IPMI |

Après la bascule, reconnectez-vous sur la nouvelle adresse et validez :

```bash
sudo ip-fixe-confirmer
```

Sans cette confirmation, le serveur revient de lui-même à sa configuration précédente. Si vous n'arrivez pas à vous reconnecter, **ne faites rien** : le retour est automatique.

Commandes installées par le script :

| Commande | Rôle |
|---|---|
| `ip-fixe-confirmer` | Valide le changement d'IP et désarme tous les retours automatiques |
| `ip-fixe-appliquer` | Applique la configuration préparée (utile si vous aviez choisi « appliquer au redémarrage ») |
| `ip-fixe-rollback` | Force immédiatement le retour à la configuration précédente |

### 🌐 Note sur le DNS sous Debian 13

Debian 13 n'installe **pas** `systemd-resolved` sur une installation serveur minimale, et la directive `DNS=` d'un fichier `.network` n'est lue que par ce service. De même, `dns-nameservers` dans `/etc/network/interfaces` n'a aucun effet sans le paquet `resolvconf`. C'est la cause classique d'une résolution de noms cassée après un passage en IP fixe.

Le script détecte donc la situation réelle et configure le DNS là où il sera effectivement pris en compte :

* `systemd-resolved` actif → fichier de surcharge dans `/etc/systemd/resolved.conf.d/` et `/etc/resolv.conf` pointé sur le résolveur local ;
* `resolvconf` installé → les serveurs lui sont fournis, il génère `/etc/resolv.conf` ;
* aucun des deux (**cas par défaut**) → `/etc/resolv.conf` est écrit directement, et `dhcpcd` (client DHCP par défaut de Trixie) est configuré pour ne plus l'écraser.

### 📋 Prérequis

* Un serveur tournant sous **Debian 13**.
* Les privilèges **root** ou **sudo**.
* Un accès console (physique, IPMI ou VNC) reste conseillé par prudence, mais n'est plus indispensable : les garde-fous décrits ci-dessus sont conçus pour permettre un usage entièrement à distance.

### 🚀 Utilisation

Pour lancer la configuration, exécutez simplement la commande suivante directement dans le terminal de votre Debian (accès à Internet requis) :

```bash
sudo -E bash -c 'f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/TutoTech/Script-de-personnalisation-post-installation-pour-serveur-Linux/main/script-de-personnalisation-post-installation-pour-debian-13.sh -o "$f" && chmod +x "$f" && "$f" ; rm -f "$f"'
```
ou plus classiquement : 

```bash
chmod +x script-de-personnalisation-post-installation-pour-debian-13.sh
sudo ./script-de-personnalisation-post-installation-pour-debian-13.sh

```

### 🧪 Développement

```bash
bash -n script-de-personnalisation-post-installation-pour-debian-13.sh   # syntaxe
shellcheck -s bash -e SC2317 script-de-personnalisation-post-installation-pour-debian-13.sh
bash tests/test-fonctions.sh                                             # tests unitaires
```

Les tests chargent le script avec `PERSONNALISATION_SOURCE_ONLY=1`, qui n'expose que les fonctions : rien n'est exécuté et le système n'est jamais modifié.

---

# English Version

## 🚀 Debian 13 (Trixie) Post-Installation Script

This Bash script is designed to automate the initial configuration of a fresh **Debian 13 (Trixie)** server installation. It streamlines a minimal install into a secure, user-friendly, and production-ready environment within minutes.

### 🛠 Features

The script automates seven critical setup steps:

1. **Shell Enhancement**: Enables syntax highlighting for the `root` user (PS1 prompt, `ls`, `grep` aliases).
2. **System Update**: Full package list update and upgrade (`apt-get update` & `upgrade`), strictly non-interactive.
3. **Localization**: Configures the keyboard layout to French (**AZERTY**).
4. **Identity**: Customizes the machine's hostname, with format validation.
5. **Static Networking**: Sets up a static IP address **in whichever network stack is already in place**, with pre-flight verification and automatic DHCP rollback.
6. **User Security**: Creates a standard non-root user with `sudo` privileges.
7. **SSH Hardening**: Changes the listening port (socket-activation aware, as required on Debian 13) and configures root login.

### 🛡 How the IP change is made safe

Switching to a static IP is the riskiest part of any post-install: a single typo can leave a remote server permanently unreachable. The script therefore applies five safeguards.

| Safeguard | What it prevents |
|---|---|
| **Detects the active network manager** (`ifupdown`, `systemd-networkd` or `NetworkManager`) and writes **into it** | No stack migration — the number one cause of a server going offline after a post-install |
| **Input validation**: interface must exist, valid CIDR, address is neither network nor broadcast, gateway within the subnet, plus **duplicate address detection** on the wire | An IP already in use, or a gateway outside the subnet |
| **Non-disruptive live test**: the address is added as a **secondary** one (the DHCP address stays up), then the gateway, DNS resolution and pings to `example.org`, `debian.org` and `cloudflare.com` are checked | Your SSH session is **never** dropped during verification, and nothing is written while the tests fail |
| **Switch-over at the very end of the script**, run detached via `systemd-run` | An SSH disconnect can no longer interrupt the operation halfway through |
| **Automatic DHCP rollback**: a systemd timer restores the previous configuration unless you confirm, and a boot-time service does the same if the server does not answer after a reboot | An unreachable server requiring physical or IPMI console access |

After the switch, reconnect on the new address and confirm:

```bash
sudo ip-fixe-confirmer
```

Without that confirmation the server reverts on its own. If you cannot reconnect, **do nothing** — rollback is automatic.

### 🌐 A note on DNS under Debian 13

Debian 13 does **not** install `systemd-resolved` on a minimal server install, and the `DNS=` directive of a `.network` file is only read by that service. Likewise, `dns-nameservers` in `/etc/network/interfaces` does nothing without the `resolvconf` package. This is the classic cause of broken name resolution after switching to a static IP.

The script therefore detects the actual setup and configures DNS where it will really be honoured: via `systemd-resolved` when active, via `resolvconf` when installed, and otherwise by writing `/etc/resolv.conf` directly while stopping `dhcpcd` (Trixie's default DHCP client) from overwriting it.

### 📋 Prerequisites

* A server running **Debian 13**.
* **Root** or **sudo** privileges.
* Console access (physical, IPMI or VNC) is still recommended as a precaution, but is no longer required: the safeguards above are designed for fully remote use.

### 🚀 Usage

To start the configuration, simply run:

```bash
sudo -E bash -c 'f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/TutoTech/Script-de-personnalisation-post-installation-pour-serveur-Linux/main/script-de-personnalisation-post-installation-pour-debian-13.sh -o "$f" && chmod +x "$f" && "$f" ; rm -f "$f"'
```

or : 

```bash
chmod +x script-de-personnalisation-post-installation-pour-debian-13.sh
sudo ./script-de-personnalisation-post-installation-pour-debian-13.sh

```

### 🧪 Development

```bash
bash -n script-de-personnalisation-post-installation-pour-debian-13.sh
shellcheck -s bash -e SC2317 script-de-personnalisation-post-installation-pour-debian-13.sh
bash tests/test-fonctions.sh
```

---
