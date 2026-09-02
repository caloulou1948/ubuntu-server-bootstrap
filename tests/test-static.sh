#!/usr/bin/env bash

set -Eeuo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$project_root/install.sh"

[[ -f "$installer" ]] || { echo "missing installer: $installer" >&2; exit 1; }
bash -n "$installer"

for required_text in \
  'Install lightweight XFCE desktop?' \
  'Install XRDP remote desktop access?' \
  'Install Docker Engine and Docker Compose v2?' \
  'Install OpenSSH server and UFW firewall basics?' \
  'Install Rocket.Chat?' \
  'Install Nextcloud?' \
  'Install Frigate?' \
  'Install Shinobi?' \
  'Configure local graphical boot with LightDM?' \
  'graphical.target' \
  'lightdm-gtk-greeter' \
  'required dependency' \
  'Preserving existing' \
  'docker compose' \
  'config -q'; do
  rg -Fq "$required_text" "$installer" || {
    echo "missing required installer marker: $required_text" >&2
    exit 1
  }
done

echo "static installer checks passed"
