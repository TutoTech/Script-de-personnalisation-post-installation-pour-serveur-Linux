# Script-de-personnalisation-post-installation-pour-serveur-Linux
Script Bash d'automatisation post-installation pour serveur Debian 13 (Trixie). Configure rapidement les essentiels : clavier FR, IP fixe avec vérification et retour automatique au DHCP, coloration syntaxique, création d'utilisateur sudo, sécurisation SSH et authentification par clé (génération d'une paire côté client, dépôt de la clé publique côté serveur). Idéal pour transformer une installation minimale en environnement prêt à l'emploi.

---

# Version Française

## 🚀 Script de Post-Installation Debian 13 (Trixie)

Ce script Bash est conçu pour automatiser la configuration initiale d'un serveur **Debian 13 (Trixie)** fraîchement installé. Il transforme une installation minimale en un environnement de travail sécurisé, ergonomique et prêt pour la production en quelques minutes.

### 🛠 Fonctionnalités

Le script traite les huit étapes essentielles de la mise en service d'un serveur :

1. **Confort visuel** : Activation de la coloration syntaxique pour l'utilisateur `root` (Prompt PS1, `ls`, `grep`).
2. **Mise à jour système** : Actualisation complète des paquets (`apt-get update` & `upgrade`), en mode strictement non interactif.
3. **Localisation** : Configuration du clavier en français (**AZERTY**).
4. **Identité** : Personnalisation du nom d'hôte (hostname), avec validation du format.
5. **Réseau statique** : Configuration d'une IP fixe **dans le gestionnaire réseau déjà en place**, avec vérification préalable et retour automatique au DHCP en cas de problème.
6. **Sécurité Utilisateur** : Création d'un utilisateur standard avec privilèges `sudo` pour éviter l'usage de root.
7. **Durcissement SSH** : Changement du port d'écoute (compatible avec l'activation par socket de Debian 13) et configuration de l'accès root.
8. **Authentification par clé** : Génération d'une paire de clés si la machine est un **client**, dépôt d'une clé publique dans `authorized_keys` si c'est un **serveur**, puis durcissement facultatif avec retour automatique en cas de problème.

### 🔑 Authentification par clé SSH

L'étape 8 demande d'abord le **rôle de la machine**, puis déroule la branche correspondante — ou les deux, pour un poste rebond.

**Machine cliente — génération d'une paire de clés**

| Choix proposé | Détail |
|---|---|
| Compte propriétaire | La clé est créée dans le répertoire personnel de ce compte, avec ses droits (l'utilisateur créé à l'étape 6 est proposé par défaut) |
| Type | `ed25519` (recommandé), `rsa 4096` (vieux équipements), `ecdsa 521`, ou `ed25519-sk` pour une clé matérielle FIDO2 — avec repli proposé sur `ed25519` si aucun jeton ne répond |
| Emplacement et nom | Répertoire et nom de fichier libres, validés (chemin absolu, pas de `..`, pas de suffixe `.pub`) |
| Phrase de passe | Demandée par `ssh-keygen` lui-même, **jamais passée en argument** : la ligne de commande d'un processus est lisible par tous via `ps` |
| Commentaire | Pour reconnaître la clé des mois plus tard dans un `authorized_keys` qui en compte plusieurs |
| Raccourci `~/.ssh/config` | Bloc idempotent `Host` / `HostName` / `User` / `Port` / `IdentityFile` / `IdentitiesOnly` / `AddKeysToAgent` : la connexion devient `ssh monserveur` |
| Envoi immédiat | `ssh-copy-id` vers un serveur distant, suivi d'un **test de connexion réel** |

Une clé existante n'est **jamais écrasée en silence** : le script propose un autre nom, ou une sauvegarde préalable.

**Serveur — dépôt d'une clé publique**

La clé peut être collée, lue dans un fichier, téléchargée depuis une URL `https`, importée depuis un compte GitHub (`https://github.com/<login>.keys`), ou reprise de la paire générée à l'instant. Une entrée « je n'ai pas encore de clé » affiche les commandes à lancer sur le poste client.

Chaque clé est vérifiée avant installation : type reconnu (les clés DSA, refusées par OpenSSH depuis la version 7, sont écartées), corps base64 cohérent avec le type annoncé, refus explicite d'une clé **privée** collée par erreur, suppression des retours chariot d'un copier-coller Windows. Le dépôt est **idempotent** : une clé déjà présente n'est pas ajoutée une seconde fois, même si son commentaire diffère.

Le script vérifie ensuite ce qui empêche réellement une clé de fonctionner :

* droits `700` sur `~/.ssh`, `600` sur `authorized_keys`, propriétaire correct ;
* **`StrictModes`** : si le répertoire personnel ou `.ssh` est accessible en écriture au groupe ou à tous, `sshd` ignore la clé **sans aucun message** — le script le détecte et propose la correction ;
* saut de ligne final garanti, sans quoi la clé suivante viendrait se coller à la précédente et les invaliderait toutes les deux ;
* `AuthorizedKeysFile` réellement en vigueur, relu via `sshd -T` ;
* **test de connexion en boucle locale** quand une clé privée est disponible : la seule preuve possible depuis le serveur.

**Durcissement et garde-fou anti-lockout**

`PubkeyAuthentication yes` est posé systématiquement. La désactivation du mot de passe (`PasswordAuthentication no` **et** `KbdInteractiveAuthentication no`, sans quoi la coupure serait illusoire sur Debian) n'est proposée qu'après une connexion par clé prouvée ou une confirmation explicite, et le résultat est vérifié via `sshd -T` — si un fichier de `/etc/ssh/sshd_config.d/` numéroté avant le nôtre l'emporte, le script le nomme au lieu d'annoncer un succès qui n'a pas eu lieu.

Comme pour le changement d'IP, un **retour automatique est armé avant la modification** : sans confirmation dans le délai choisi, le mot de passe est réactivé tout seul.

| Commande | Rôle |
|---|---|
| `ssh-cles-confirmer` | Valide le durcissement et désarme le retour automatique |
| `ssh-cles-rollback` | Réactive immédiatement l'authentification par mot de passe |

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

The script automates eight critical setup steps:

1. **Shell Enhancement**: Enables syntax highlighting for the `root` user (PS1 prompt, `ls`, `grep` aliases).
2. **System Update**: Full package list update and upgrade (`apt-get update` & `upgrade`), strictly non-interactive.
3. **Localization**: Configures the keyboard layout to French (**AZERTY**).
4. **Identity**: Customizes the machine's hostname, with format validation.
5. **Static Networking**: Sets up a static IP address **in whichever network stack is already in place**, with pre-flight verification and automatic DHCP rollback.
6. **User Security**: Creates a standard non-root user with `sudo` privileges.
7. **SSH Hardening**: Changes the listening port (socket-activation aware, as required on Debian 13) and configures root login.
8. **Key-based authentication**: Generates a key pair when the machine is a **client**, installs a public key into `authorized_keys` when it is a **server**, then optionally hardens `sshd` with an automatic rollback.

### 🔑 SSH key authentication

Step 8 first asks for the **machine's role**, then runs the matching branch — or both, for a jump host.

**Client machine — key pair generation**

| Option | Details |
|---|---|
| Owning account | The key is created in that account's home directory, with its ownership (the user created in step 6 is offered by default) |
| Type | `ed25519` (recommended), `rsa 4096` (legacy gear), `ecdsa 521`, or `ed25519-sk` for a FIDO2 hardware token — with a fallback to `ed25519` offered when no token answers |
| Location and name | Free choice of directory and filename, validated (absolute path, no `..`, no `.pub` suffix) |
| Passphrase | Prompted by `ssh-keygen` itself, **never passed as an argument**: a process command line is world-readable through `ps` |
| Comment | So the key stays identifiable months later in an `authorized_keys` holding several |
| `~/.ssh/config` shortcut | Idempotent block with `Host` / `HostName` / `User` / `Port` / `IdentityFile` / `IdentitiesOnly` / `AddKeysToAgent`, turning the connection into `ssh myserver` |
| Immediate deployment | `ssh-copy-id` to a remote server, followed by a **real connection test** |

An existing key is **never silently overwritten**: the script offers another name, or a backup first.

**Server — installing a public key**

The key can be pasted, read from a file, downloaded over `https`, imported from a GitHub account (`https://github.com/<login>.keys`), or taken from the pair just generated. A "I don't have a key yet" entry prints the commands to run on the client machine.

Every key is checked before installation: recognised type (DSA keys, rejected by OpenSSH since version 7, are turned down), base64 body consistent with the announced type, explicit refusal of a **private** key pasted by mistake, and stripping of carriage returns from a Windows copy-paste. Installation is **idempotent**: a key already present is not added twice, even if its comment differs.

The script then checks what actually stops a key from working:

* `700` on `~/.ssh`, `600` on `authorized_keys`, correct ownership;
* **`StrictModes`**: if the home directory or `.ssh` is group- or world-writable, `sshd` ignores the key **with no message at all** — the script detects this and offers to fix it;
* a guaranteed trailing newline, without which the next key would be glued to the previous one, invalidating both;
* the effective `AuthorizedKeysFile`, read back through `sshd -T`;
* a **loopback connection test** whenever a private key is available — the only proof obtainable from the server itself.

**Hardening and lockout safeguard**

`PubkeyAuthentication yes` is always set. Disabling passwords (`PasswordAuthentication no` **and** `KbdInteractiveAuthentication no`, without which the change would be illusory on Debian) is only offered after a proven key login or an explicit confirmation, and the result is verified through `sshd -T` — if a file in `/etc/ssh/sshd_config.d/` sorting before ours wins, the script names it instead of reporting a success that did not happen.

As with the IP change, an **automatic rollback is armed before the change**: without confirmation within the chosen delay, password authentication is re-enabled on its own.

| Command | Purpose |
|---|---|
| `ssh-cles-confirmer` | Confirms the hardening and disarms the automatic rollback |
| `ssh-cles-rollback` | Immediately re-enables password authentication |

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
