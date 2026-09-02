#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_VERSION="1.1.0"
INSTALL_ROOT="${UBUNTU_BOOTSTRAP_ROOT:-/opt/ubuntu-headless-bootstrap}"
SERVICE_ROOT="$INSTALL_ROOT/services"
STATE_ROOT="$INSTALL_ROOT/state"
DRY_RUN=0
PLAN_ONLY=0
APT_UPDATED=0
TARGET_USER="${SUDO_USER:-}"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

usage() {
  cat <<'USAGE'
Ubuntu Server Bootstrap

Usage:
  sudo bash install.sh           Interactive installation
  bash install.sh --plan         Show the selection plan without changing files
  sudo bash install.sh --dry-run Print commands without changing the host
  bash install.sh --help         Show this help

Environment:
  UBUNTU_BOOTSTRAP_ROOT          Installation root (default: /opt/ubuntu-headless-bootstrap)
USAGE
}

while (($# > 0)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --plan) PLAN_ONLY=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ((DRY_RUN || PLAN_ONLY)); then
  LOG_ROOT="${TMPDIR:-/tmp}/ubuntu-headless-bootstrap"
else
  LOG_ROOT="/var/log/ubuntu-headless-bootstrap"
fi
LOG_FILE="$LOG_ROOT/install-$RUN_STAMP.log"

mkdir -p "$LOG_ROOT"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
if (( ! PLAN_ONLY )); then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

log() {
  local log_line
  log_line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  printf '%s\n' "$log_line"
  if ((PLAN_ONLY)); then
    printf '%s\n' "$log_line" >> "$LOG_FILE"
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

on_error() {
  local exit_code=$?
  log "ERROR: command failed at line $1 (exit $exit_code)"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

run() {
  if ((DRY_RUN || PLAN_ONLY)); then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

run_in_dir() {
  local working_dir="$1"
  shift
  if ((DRY_RUN || PLAN_ONLY)); then
    printf '+ (cd %q && ' "$working_dir"
    printf '%q ' "$@"
    printf ')\n'
    return 0
  fi
  (cd "$working_dir" && "$@")
}

write_file_if_missing() {
  local file_path="$1"
  local file_mode="$2"
  if [[ -e "$file_path" ]]; then
    log "Preserving existing file: $file_path"
    cat >/dev/null
    return 0
  fi
  if ((DRY_RUN || PLAN_ONLY)); then
    cat >/dev/null
    log "Would create: $file_path"
    return 0
  fi
  install -D -m "$file_mode" /dev/null "$file_path"
  cat >"$file_path"
  chmod "$file_mode" "$file_path"
  log "Created: $file_path"
}

prompt_yes_no() {
  local question="$1"
  local default_answer="${2:-n}"
  local answer
  local suffix='[y/N]'
  if [[ "$default_answer" == y ]]; then
    suffix='[Y/n]'
  fi
  while true; do
    read -r -p "$question $suffix " answer || die "Input ended while answering: $question"
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$answer" ]]; then
      answer="$default_answer"
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Please answer yes or no.\n' ;;
    esac
  done
}

prompt_value() {
  local variable_name="$1"
  local question="$2"
  local default_value="${3:-}"
  local answer
  read -r -p "$question${default_value:+ [$default_value]}: " answer || die "Input ended while answering: $question"
  if [[ -z "$answer" ]]; then
    answer="$default_value"
  fi
  printf -v "$variable_name" '%s' "$answer"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  ((PLAN_ONLY)) && return 0
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run the installer with sudo or as root."
}

detect_ubuntu() {
  if ((PLAN_ONLY)); then
    OS_ID='ubuntu'
    VERSION_ID='detected-at-install-time'
    VERSION_CODENAME='detected-at-install-time'
    UBUNTU_ARCH='detected-at-install-time'
    log "Plan mode: Ubuntu release and architecture will be detected on the target."
    return 0
  fi
  [[ -r /etc/os-release ]] || die "/etc/os-release is unavailable."
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-}"
  VERSION_ID="${VERSION_ID:-unknown}"
  VERSION_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  [[ "$OS_ID" == ubuntu ]] || die "This installer supports Ubuntu only; detected: ${OS_ID:-unknown}."
  [[ -n "$VERSION_CODENAME" ]] || die "Ubuntu release codename is unavailable; cannot safely configure the Docker repository."
  UBUNTU_ARCH="$(dpkg --print-architecture)"
  log "Detected Ubuntu $VERSION_ID ($VERSION_CODENAME), architecture $UBUNTU_ARCH."
}

choose_target_user() {
  if [[ -n "$TARGET_USER" && "$TARGET_USER" != root ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    return 0
  fi
  if ((DRY_RUN || PLAN_ONLY)); then
    TARGET_USER='login-user-detected-at-install-time'
    return 0
  fi
  TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1; exit}' /etc/passwd)"
  [[ -n "$TARGET_USER" ]] || die "Could not identify a non-root login user."
  log "Using login user: $TARGET_USER"
}

apt_install() {
  if ((APT_UPDATED == 0)); then
    run apt-get update
    APT_UPDATED=1
  fi
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

set_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  if ((DRY_RUN || PLAN_ONLY)); then
    log "Would set $key in $env_file (value hidden from log)."
    return 0
  fi
  local backup_file="$env_file.bak.$RUN_STAMP"
  if [[ ! -e "$backup_file" ]]; then
    cp -p "$env_file" "$backup_file"
  fi
  local temp_file
  temp_file="$(mktemp)"
  awk -v wanted_key="$key" -v wanted_value="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^" wanted_key "=" {
      print wanted_key "=" wanted_value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) print wanted_key "=" wanted_value
    }
  ' "$env_file" >"$temp_file"
  chmod 600 "$temp_file"
  mv "$temp_file" "$env_file"
  log "Updated $key in $env_file; backup: $backup_file"
}

generate_hex_secret() {
  if ((DRY_RUN || PLAN_ONLY)); then
    printf 'dry-run-secret'
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

install_xfce() {
  log 'Installing XFCE desktop packages.'
  apt_install xfce4 xfce4-goodies dbus-x11
}

install_xrdp() {
  log 'Installing and enabling XRDP.'
  apt_install xrdp
  run systemctl enable --now xrdp
  if [[ "$TARGET_USER" != login-user-detected-at-install-time ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    local target_home
    target_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -n "$target_home" && ! -e "$target_home/.xsession" ]]; then
      if ((DRY_RUN || PLAN_ONLY)); then
        log "Would create XFCE session file for $TARGET_USER."
      else
        printf 'startxfce4\n' >"$target_home/.xsession"
        chown "$TARGET_USER:$TARGET_USER" "$target_home/.xsession"
        chmod 600 "$target_home/.xsession"
      fi
    else
      log "Preserving existing XRDP session file for $TARGET_USER."
    fi
  fi
}

install_ssh_firewall() {
  log 'Installing OpenSSH and UFW basics.'
  apt_install openssh-server ufw
  run systemctl enable --now ssh

  local ssh_ports=(22)
  if (( ! DRY_RUN && ! PLAN_ONLY )) && command_exists sshd; then
    mapfile -t detected_ports < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu)
    if ((${#detected_ports[@]} > 0)); then
      ssh_ports=("${detected_ports[@]}")
    fi
  fi

  run ufw default deny incoming
  run ufw default allow outgoing
  local ssh_port
  for ssh_port in "${ssh_ports[@]}"; do
    run ufw allow "$ssh_port/tcp" comment 'SSH access'
  done
  if [[ -n "${RDP_SOURCE_CIDR:-}" ]]; then
    run ufw allow from "$RDP_SOURCE_CIDR" to any port 3389 proto tcp comment 'XRDP from trusted network'
  else
    log 'XRDP firewall port remains closed because no trusted source CIDR was supplied.'
  fi
  run ufw --force enable
}

install_docker() {
  log 'Installing Docker Engine and Docker Compose v2 from the Docker APT repository.'
  apt_install ca-certificates curl gnupg
  if ((INSTALL_ROCKETCHAT)); then
    apt_install git
  fi

  if ((DRY_RUN || PLAN_ONLY)); then
    log 'Would configure /etc/apt/keyrings/docker.gpg and the Docker APT source.'
  else
    install -d -m 0755 /etc/apt/keyrings
    local key_temp
    key_temp="$(mktemp)"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_temp"
    gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg "$key_temp"
    rm -f "$key_temp"
    chmod a+r /etc/apt/keyrings/docker.gpg
    if [[ ! -e /etc/apt/sources.list.d/docker.list ]]; then
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$UBUNTU_ARCH" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
      chmod 644 /etc/apt/sources.list.d/docker.list
    else
      log 'Preserving existing Docker APT source file.'
    fi
  fi

  APT_UPDATED=0
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run systemctl enable --now docker
  if [[ "$TARGET_USER" != login-user-detected-at-install-time ]] && id "$TARGET_USER" >/dev/null 2>&1; then
    run usermod -aG docker "$TARGET_USER"
    log 'The login user must start a new session before Docker group membership applies.'
  fi
}

prepare_service_root() {
  run install -d -m 0750 "$SERVICE_ROOT" "$STATE_ROOT"
}

compose_config_and_up() {
  local service_dir="$1"
  shift
  log "Validating Compose configuration in $service_dir."
  if (($# > 0)); then
    run docker compose --project-directory "$service_dir" "$@" config -q
  else
    run docker compose --project-directory "$service_dir" config -q
  fi
  log "Starting selected Compose project in $service_dir."
  if (($# > 0)); then
    run docker compose --project-directory "$service_dir" "$@" up -d
  else
    run docker compose --project-directory "$service_dir" up -d
  fi
  log "Compose status for $service_dir:"
  if (($# > 0)); then
    run docker compose --project-directory "$service_dir" "$@" ps
  else
    run docker compose --project-directory "$service_dir" ps
  fi
}

install_rocketchat() {
  local service_dir="$SERVICE_ROOT/rocketchat"
  run install -d -m 0750 "$service_dir"
  if [[ ! -d "$service_dir/.git" ]]; then
    run git clone --depth 1 https://github.com/RocketChat/rocketchat-compose.git "$service_dir"
  else
    log 'Preserving existing Rocket.Chat Compose checkout; no automatic git pull.'
  fi

  if [[ ! -f "$service_dir/.env" ]]; then
    run cp "$service_dir/.env.example" "$service_dir/.env"
    local upstream_release='8.0.1'
    if (( ! DRY_RUN && ! PLAN_ONLY )) && [[ -f "$service_dir/.env.example" ]]; then
      upstream_release="$(awk -F= '$1 == "RELEASE" {print $2; exit}' "$service_dir/.env.example")"
      upstream_release="${upstream_release:-8.0.1}"
    fi
    local rocketchat_release
    prompt_value rocketchat_release 'Rocket.Chat release tag (fixed tag is recommended)' "$upstream_release"
    set_env_value "$service_dir/.env" RELEASE "$rocketchat_release"
    set_env_value "$service_dir/.env" DOMAIN localhost
    set_env_value "$service_dir/.env" ROOT_URL http://localhost:3000
    set_env_value "$service_dir/.env" BIND_IP 127.0.0.1
    set_env_value "$service_dir/.env" HOST_PORT 3000
    set_env_value "$service_dir/.env" LETSENCRYPT_ENABLED false
    set_env_value "$service_dir/.env" TRAEFIK_PROTOCOL http
    set_env_value "$service_dir/.env" MONGODB_BIND_IP 127.0.0.1
  else
    log 'Preserving existing Rocket.Chat .env file.'
  fi

  compose_config_and_up "$service_dir" \
    -f compose.database.yml \
    -f compose.yml \
    -f compose.nats.yml \
    -f docker.yml
}

install_nextcloud() {
  local service_dir="$SERVICE_ROOT/nextcloud"
  run install -d -m 0750 "$service_dir"
  local db_root_password db_password
  db_root_password="$(generate_hex_secret)"
  db_password="$(generate_hex_secret)"

  if [[ ! -f "$service_dir/.env" ]]; then
    if ((DRY_RUN || PLAN_ONLY)); then
      log "Would create protected Nextcloud .env with generated database secrets."
    else
      cat >"$service_dir/.env" <<EOF
NEXTCLOUD_IMAGE=nextcloud:stable-apache
NEXTCLOUD_DB_IMAGE=mariadb:11.4
NEXTCLOUD_REDIS_IMAGE=redis:7-alpine
NEXTCLOUD_PORT=8081
MYSQL_ROOT_PASSWORD=$db_root_password
MYSQL_PASSWORD=$db_password
EOF
      chmod 600 "$service_dir/.env"
      log "Created protected Nextcloud .env."
    fi
  else
    log 'Preserving existing Nextcloud .env file and database credentials.'
  fi

  write_file_if_missing "$service_dir/compose.yml" 0644 <<'EOF'
services:
  db:
    image: ${NEXTCLOUD_DB_IMAGE}
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb-file-per-table=1
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
    volumes:
      - db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mariadb-admin ping -h localhost -u root -p\"$${MYSQL_ROOT_PASSWORD}\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 12

  redis:
    image: ${NEXTCLOUD_REDIS_IMAGE}
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis:/data

  app:
    image: ${NEXTCLOUD_IMAGE}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started
    ports:
      - "127.0.0.1:${NEXTCLOUD_PORT}:80"
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_TRUSTED_DOMAINS: localhost 127.0.0.1
    volumes:
      - html:/var/www/html

volumes:
  db:
  redis:
  html:
EOF

  compose_config_and_up "$service_dir"
}

install_frigate() {
  local service_dir="$SERVICE_ROOT/frigate"
  run install -d -m 0750 "$service_dir/config" "$service_dir/media"
  if [[ ! -f "$service_dir/.env" ]]; then
    if ((DRY_RUN || PLAN_ONLY)); then
      log "Would create Frigate .env."
    else
      printf 'FRIGATE_IMAGE=ghcr.io/blakeblackshear/frigate:stable\nTZ=%s\n' \
        "$(timedatectl show --property=Timezone --value 2>/dev/null || printf 'UTC')" >"$service_dir/.env"
      chmod 600 "$service_dir/.env"
    fi
  else
    log 'Preserving existing Frigate .env file.'
  fi

  write_file_if_missing "$service_dir/compose.yml" 0644 <<'EOF'
services:
  frigate:
    container_name: frigate
    image: ${FRIGATE_IMAGE}
    restart: unless-stopped
    stop_grace_period: 30s
    shm_size: "512mb"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./config:/config
      - ./media:/media/frigate
    tmpfs:
      - /tmp/cache:size=1000000000
    ports:
      - "127.0.0.1:8971:8971"
      - "127.0.0.1:8554:8554"
      - "127.0.0.1:8555:8555/tcp"
      - "127.0.0.1:8555:8555/udp"
EOF

  write_file_if_missing "$service_dir/config/config.yml" 0644 <<'EOF'
# Starter configuration. Add a real RTSP camera after its model and stream
# path are verified. The disabled placeholder keeps this installation empty.
mqtt:
  enabled: false

cameras:
  placeholder:
    enabled: false
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1/placeholder
          roles:
            - detect
EOF

  compose_config_and_up "$service_dir"
}

install_shinobi() {
  local service_dir="$SERVICE_ROOT/shinobi"
  run install -d -m 0750 "$service_dir/data/config" "$service_dir/data/database" "$service_dir/data/streams"
  if [[ ! -f "$service_dir/.env" ]]; then
    if ((DRY_RUN || PLAN_ONLY)); then
      log "Would create Shinobi .env."
    else
      printf 'SHINOBI_IMAGE=registry.gitlab.com/shinobi-systems/shinobi:dev\n' >"$service_dir/.env"
      chmod 600 "$service_dir/.env"
    fi
  else
    log 'Preserving existing Shinobi .env file.'
  fi

  write_file_if_missing "$service_dir/compose.yml" 0644 <<'EOF'
services:
  shinobi:
    container_name: shinobi
    image: ${SHINOBI_IMAGE}
    restart: unless-stopped
    mem_limit: 2g
    volumes:
      - ./data/config:/home/Shinobi
      - ./data/database:/var/lib/mysql
      - ./data/streams:/dev/shm/streams
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "127.0.0.1:8080:8080"
EOF

  compose_config_and_up "$service_dir"
}

install_gui_boot() {
  log 'Configuring local graphical boot with LightDM.'
  apt_install lightdm lightdm-gtk-greeter
  run systemctl set-default graphical.target
  run systemctl enable lightdm
  log 'Local graphical boot is configured; the next reboot will show the graphical login screen.'
  if prompt_yes_no 'Reboot now to activate local graphical boot?' n; then
    run systemctl reboot
  else
    log 'Reboot skipped. Run sudo reboot when ready to start the graphical login screen.'
  fi
}

write_selection_state() {
  if ((DRY_RUN || PLAN_ONLY)); then
    log 'Would write the non-secret selection state.'
    return 0
  fi
  install -d -m 0750 "$STATE_ROOT"
  cat >"$STATE_ROOT/last-selection.env" <<EOF
INSTALLER_VERSION=$SCRIPT_VERSION
RUN_UTC=$RUN_STAMP
XFCE=$INSTALL_XFCE
XRDP=$INSTALL_XRDP
DOCKER=$INSTALL_DOCKER
SSH_UFW=$INSTALL_SSH_UFW
ROCKETCHAT=$INSTALL_ROCKETCHAT
NEXTCLOUD=$INSTALL_NEXTCLOUD
FRIGATE=$INSTALL_FRIGATE
SHINOBI=$INSTALL_SHINOBI
GUI_BOOT=$INSTALL_GUI_BOOT
EOF
  chmod 600 "$STATE_ROOT/last-selection.env"
}

print_summary() {
  printf '\nSelected installation plan:\n'
  printf '  XFCE desktop:       %s\n' "$INSTALL_XFCE"
  printf '  XRDP:                %s\n' "$INSTALL_XRDP"
  printf '  Docker + Compose:    %s\n' "$INSTALL_DOCKER"
  printf '  SSH + UFW basics:    %s\n' "$INSTALL_SSH_UFW"
  printf '  Rocket.Chat:         %s\n' "$INSTALL_ROCKETCHAT"
  printf '  Nextcloud:           %s\n' "$INSTALL_NEXTCLOUD"
  printf '  Frigate:             %s\n' "$INSTALL_FRIGATE"
  printf '  Shinobi:             %s\n' "$INSTALL_SHINOBI"
  printf '  Local graphical boot: %s\n' "$INSTALL_GUI_BOOT"
  printf '  Logging/safe reruns: enabled\n'
  printf '\n'
}

any_application_selected() {
  ((INSTALL_ROCKETCHAT || INSTALL_NEXTCLOUD || INSTALL_FRIGATE || INSTALL_SHINOBI))
}

main() {
  require_root
  detect_ubuntu
  choose_target_user

  printf '\nUbuntu Server Bootstrap %s\n' "$SCRIPT_VERSION"
  printf 'The installer will ask for each component. Existing data/configuration is preserved.\n\n'

  INSTALL_XFCE=0
  INSTALL_XRDP=0
  INSTALL_DOCKER=0
  INSTALL_SSH_UFW=0
  INSTALL_ROCKETCHAT=0
  INSTALL_NEXTCLOUD=0
  INSTALL_FRIGATE=0
  INSTALL_SHINOBI=0
  INSTALL_GUI_BOOT=0
  RDP_SOURCE_CIDR=''

  prompt_yes_no 'Install lightweight XFCE desktop?' n && INSTALL_XFCE=1 || true
  prompt_yes_no 'Install XRDP remote desktop access?' n && INSTALL_XRDP=1 || true
  prompt_yes_no 'Install Docker Engine and Docker Compose v2?' n && INSTALL_DOCKER=1 || true
  prompt_yes_no 'Install OpenSSH server and UFW firewall basics?' n && INSTALL_SSH_UFW=1 || true
  prompt_yes_no 'Install Rocket.Chat?' n && INSTALL_ROCKETCHAT=1 || true
  prompt_yes_no 'Install Nextcloud?' n && INSTALL_NEXTCLOUD=1 || true
  prompt_yes_no 'Install Frigate?' n && INSTALL_FRIGATE=1 || true
  prompt_yes_no 'Install Shinobi?' n && INSTALL_SHINOBI=1 || true
  prompt_yes_no 'Configure local graphical boot with LightDM?' n && INSTALL_GUI_BOOT=1 || true

  if ((INSTALL_XRDP && !INSTALL_XFCE)); then
    if prompt_yes_no 'XRDP requires a desktop session. Install XFCE as a required dependency?' y; then
      INSTALL_XFCE=1
    else
      die 'XRDP was selected without its required XFCE dependency.'
    fi
  fi

  if ((INSTALL_GUI_BOOT && !INSTALL_XFCE)); then
    if prompt_yes_no 'Local graphical boot requires XFCE. Install XFCE as a required dependency?' y; then
      INSTALL_XFCE=1
    else
      die 'Local graphical boot was selected without its required XFCE dependency.'
    fi
  fi

  if any_application_selected && ((INSTALL_DOCKER == 0)); then
    if prompt_yes_no 'Selected applications require Docker. Install Docker as a required dependency?' y; then
      INSTALL_DOCKER=1
    else
      die 'An application was selected without its required Docker dependency.'
    fi
  fi

  if ((INSTALL_XRDP && INSTALL_SSH_UFW)); then
    printf '\nXRDP firewall safety: enter the trusted source network in CIDR form, such as 192.168.1.0/24.\n'
    printf 'Leave this blank to install XRDP but keep port 3389 closed in UFW.\n'
    read -r -p 'Trusted XRDP source CIDR (blank = closed): ' RDP_SOURCE_CIDR || die 'Input ended while reading the RDP source CIDR.'
  fi

  if ((INSTALL_ROCKETCHAT)) && [[ "$VERSION_ID" == 26.04* ]]; then
    printf '\nWARNING: current Rocket.Chat documentation warns that bundled MongoDB 8.x may fail on Ubuntu 26.04.\n'
    if ! prompt_yes_no 'Continue with Rocket.Chat selection on this Ubuntu release?' n; then
      die 'Rocket.Chat selection cancelled due to the Ubuntu 26.04/MongoDB compatibility warning.'
    fi
  fi

  print_summary
  prompt_yes_no 'Proceed with this plan?' n || { log 'Installation cancelled before host changes.'; exit 0; }

  if ! ((INSTALL_XFCE || INSTALL_XRDP || INSTALL_DOCKER || INSTALL_SSH_UFW || INSTALL_ROCKETCHAT || INSTALL_NEXTCLOUD || INSTALL_FRIGATE || INSTALL_SHINOBI || INSTALL_GUI_BOOT)); then
    log 'No components were selected; no host changes will be made.'
    exit 0
  fi

  prepare_service_root
  write_selection_state

  if ((INSTALL_XFCE)); then install_xfce; fi
  if ((INSTALL_XRDP)); then install_xrdp; fi
  if ((INSTALL_SSH_UFW)); then install_ssh_firewall; fi
  if ((INSTALL_DOCKER)); then install_docker; fi
  if ((INSTALL_ROCKETCHAT)); then install_rocketchat; fi
  if ((INSTALL_NEXTCLOUD)); then install_nextcloud; fi
  if ((INSTALL_FRIGATE)); then install_frigate; fi
  if ((INSTALL_SHINOBI)); then install_shinobi; fi
  if ((INSTALL_GUI_BOOT)); then install_gui_boot; fi

  log "Bootstrap completed for selected components."
  log "Installer log: $LOG_FILE"
  if ((INSTALL_ROCKETCHAT)); then log 'Rocket.Chat: http://127.0.0.1:3000'; fi
  if ((INSTALL_NEXTCLOUD)); then log 'Nextcloud:   http://127.0.0.1:8081'; fi
  if ((INSTALL_SHINOBI)); then log 'Shinobi:     http://127.0.0.1:8080'; fi
  if ((INSTALL_FRIGATE)); then log 'Frigate:     http://127.0.0.1:8971'; fi
  log 'No camera was configured; RTSP/ONVIF details are required for that later step.'
}

main "$@"
