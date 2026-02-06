# Script-de-personnalisation-post-installation-pour-serveur-Linux
Script Bash d'automatisation post-installation pour serveur Debian 13 (Trixie). Configure rapidement les essentiels : clavier FR, IP fixe (systemd-networkd), coloration syntaxique, création d'utilisateur sudo et sécurisation SSH. Idéal pour transformer une installation minimale en environnement prêt à l'emploi.

---

# Version Française

## 🚀 Script de Post-Installation Debian 13 (Trixie)

Ce script Bash est conçu pour automatiser la configuration initiale d'un serveur **Debian 13 (Trixie)** fraîchement installé. Il transforme une installation minimale en un environnement de travail sécurisé, ergonomique et prêt pour la production en quelques minutes.

### 🛠 Fonctionnalités

Le script traite les sept étapes essentielles de la mise en service d'un serveur :

1. **Confort visuel** : Activation de la coloration syntaxique pour l'utilisateur `root` (Prompt PS1, `ls`, `grep`).
2. **Mise à jour système** : Actualisation complète des paquets (`apt update` & `upgrade`).
3. **Localisation** : Configuration du clavier en français (**AZERTY**).
4. **Identité** : Personnalisation du nom d'hôte (hostname).
5. **Réseau statique** : Configuration d'une IP fixe via `systemd-networkd` (méthode moderne).
6. **Sécurité Utilisateur** : Création d'un utilisateur standard avec privilèges `sudo` pour éviter l'usage de root.
7. **Durcissement SSH** : Changement du port par défaut et désactivation de l'accès direct en root.

### 📋 Prérequis

* Un serveur tournant sous **Debian 13**.
* Un accès direct à la console (physique ou via IPMI/VNC) est recommandé, notamment pour la configuration réseau.
* Les privilèges **root** ou **sudo**.

### 🚀 Utilisation

Pour lancer la configuration, exécutez simplement la commande suivante directement dans le terminal de votre Debian (accès à Internet requis) :

```bash
sudo -E bash -c 'f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/TutoTech/Script-de-personnalisation-post-installation-pour-serveur-Linux/main/script-de-personnalisation-post-installation-pour-debian-13.sh -o "$f" && chmod +x "$f" && "$f" && rm -f "$f"'
```
ou plus classiquement : 

```bash
chmod +x script-de-personnalisation-post-installation-pour-debian-13.sh
sudo ./script-de-personnalisation-post-installation-pour-debian-13.sh

```

---

# English Version

## 🚀 Debian 13 (Trixie) Post-Installation Script

This Bash script is designed to automate the initial configuration of a fresh **Debian 13 (Trixie)** server installation. It streamlines a minimal install into a secure, user-friendly, and production-ready environment within minutes.

### 🛠 Features

The script automates seven critical setup steps:

1. **Shell Enhancement**: Enables syntax highlighting for the `root` user (PS1 prompt, `ls`, `grep` aliases).
2. **System Update**: Full package list update and upgrade (`apt update` & `upgrade`).
3. **Localization**: Configures the keyboard layout to French (**AZERTY**).
4. **Identity**: Customizes the machine's hostname.
5. **Static Networking**: Sets up a static IP address using `systemd-networkd` (modern standard).
6. **User Security**: Creates a standard non-root user with `sudo` privileges.
7. **SSH Hardening**: Changes the default SSH port and disables direct root login.

### 📋 Prerequisites

* A server running **Debian 13**.
* Direct console access (physical or VNC/IPMI) is recommended, especially when modifying network settings.
* **Root** or **sudo** privileges.

### 🚀 Usage

To start the configuration, simply run:

```bash
sudo -E bash -c 'f=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/TutoTech/Script-de-personnalisation-post-installation-pour-serveur-Linux/main/script-de-personnalisation-post-installation-pour-debian-13.sh -o "$f" && chmod +x "$f" && "$f" && rm -f "$f"'
```

or : 

```bash
chmod +x script-de-personnalisation-post-installation-pour-debian-13.sh
sudo ./script-de-personnalisation-post-installation-pour-debian-13.sh

```

---
