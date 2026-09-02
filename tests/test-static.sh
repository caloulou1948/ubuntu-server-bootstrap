#!/usr/bin/env bash

set -Eeuo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$project_root/install.sh"

[[ -f "$installer" ]] || { echo "missing installer: $installer" >&2; exit 1; }
bash -n "$installer"

for required_text in \
  'Choose the desktop environment' \
  '1) XFCE lightweight' \
  '2) Standard Ubuntu GNOME desktop' \
  '3) No desktop' \
  'Install GitHub CLI (gh)?' \
  'apt_install git gh' \
  'ubuntu-desktop-minimal' \
  'ubuntu-session' \
  'gdm3' \
  'Install XRDP remote desktop access?' \
  'Install Docker Engine and Docker Compose v2?' \
  'Install OpenSSH server and UFW firewall basics?' \
  'Install Rocket.Chat?' \
  'Install Nextcloud?' \
  'Install Frigate?' \
  'Install Shinobi?' \
  'Configure local graphical boot with the selected desktop?' \
  'graphical.target' \
  'lightdm-gtk-greeter' \
  'user-session=xfce' \
  'dbus-run-session -- startxfce4' \
  'Verified XFCE session components' \
  'disable_conflicting_display_manager' \
  'systemctl restart' \
  'systemctl is-enabled --quiet' \
  'systemctl is-active --quiet' \
  'graphical.target is the system default target' \
  'rebooting now to start the graphical login screen' \
  'required dependency' \
  'Preserving existing' \
  'docker compose' \
  'run_in_dir "$service_dir" docker compose' \
  'config -q'; do
  rg -Fq "$required_text" "$installer" || {
    echo "missing required installer marker: $required_text" >&2
    exit 1
  }
done

echo "static installer checks passed"
